//! Fake processes retain real pipes and JPEG decoding, so lifecycle races cross
//! the same worker boundaries as ffmpeg without requiring capture hardware.
use rackglass::{
    Config,
    capture::{
        CaptureController, CaptureDevice, CaptureMode, CaptureProcess, CaptureState, MjpegSplitter,
        ProcessSpawner, SignalDetector, decode_jpeg, ffmpeg_args,
    },
    config::{CAPTURE_BLACK_STREAK, CAPTURE_BUFFER_LIMIT, CAPTURE_SIGNAL_CHECK},
};
use std::{
    collections::VecDeque,
    io::{self, Cursor, Read},
    sync::{Arc, Condvar, Mutex},
    thread,
    time::{Duration, Instant},
};

const LIT: &[u8] = include_bytes!("fixtures/lit.jpg");
const DARK: &[u8] = include_bytes!("fixtures/dark.jpg");
const CONSOLE: &[u8] = include_bytes!("fixtures/console.jpg");

#[derive(Default)]
struct PipeState {
    bytes: VecDeque<u8>,
    closed: bool,
}
#[derive(Clone, Default)]
struct Pipe(Arc<(Mutex<PipeState>, Condvar)>);
impl Pipe {
    fn emit(&self, bytes: &[u8]) {
        self.0.0.lock().unwrap().bytes.extend(bytes);
        self.0.1.notify_all();
    }
    fn close(&self) {
        self.0.0.lock().unwrap().closed = true;
        self.0.1.notify_all();
    }
}
impl Read for Pipe {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let mut state = self.0.0.lock().unwrap();
        while state.bytes.is_empty() && !state.closed {
            state = self.0.1.wait(state).unwrap();
        }
        // Deliberately split JPEG markers across read boundaries.
        let length = buffer.len().min(state.bytes.len()).min(64);
        for byte in &mut buffer[..length] {
            *byte = state.bytes.pop_front().unwrap();
        }
        Ok(length)
    }
}
#[derive(Default)]
struct ProcessState {
    exit: Option<i32>,
    killed: bool,
}
#[derive(Clone, Default)]
struct FakeProcess {
    pipe: Pipe,
    state: Arc<Mutex<ProcessState>>,
    stderr: String,
}
impl FakeProcess {
    fn exit(&self, code: i32) {
        self.state.lock().unwrap().exit = Some(code);
        self.pipe.close();
    }
    fn frames(&self, jpeg: &[u8], count: usize) {
        self.pipe.emit(&jpeg.repeat(count));
    }
}
impl CaptureProcess for FakeProcess {
    fn stdout(&mut self) -> Box<dyn Read + Send> {
        Box::new(self.pipe.clone())
    }
    fn stderr(&mut self) -> Box<dyn Read + Send> {
        Box::new(Cursor::new(self.stderr.clone().into_bytes()))
    }
    fn try_wait(&mut self) -> io::Result<Option<i32>> {
        Ok(self.state.lock().unwrap().exit)
    }
    fn kill(&mut self) {
        self.state.lock().unwrap().killed = true;
        self.exit(0);
    }
}
#[derive(Default)]
struct FakeSpawner {
    processes: Mutex<Vec<FakeProcess>>,
    calls: Mutex<Vec<Vec<String>>>,
    failures: Mutex<usize>,
    stderr: Mutex<String>,
}
impl ProcessSpawner for FakeSpawner {
    fn spawn(&self, _: &str, args: &[String]) -> io::Result<Box<dyn CaptureProcess>> {
        self.calls.lock().unwrap().push(args.to_vec());
        let mut failures = self.failures.lock().unwrap();
        if *failures > 0 {
            *failures -= 1;
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "fake ffmpeg missing",
            ));
        }
        let process = FakeProcess {
            stderr: self.stderr.lock().unwrap().clone(),
            ..Default::default()
        };
        self.processes.lock().unwrap().push(process.clone());
        Ok(Box::new(process))
    }
}
fn until(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !predicate() {
        assert!(Instant::now() < deadline, "capture condition timed out");
        thread::sleep(Duration::from_millis(2));
    }
}
fn setup(pin: &str, retry: Duration) -> (CaptureController, Arc<FakeSpawner>) {
    let spawner = Arc::new(FakeSpawner::default());
    let config = Config {
        capture_device: pin.into(),
        ..Config::default()
    };
    let devices = (0..2)
        .map(|i| CaptureDevice {
            path: format!("/dev/video{i}"),
            name: "Fake UVC".into(),
        })
        .collect();
    (
        CaptureController::with_spawner(config, spawner.clone(), Some(devices), retry),
        spawner,
    )
}
fn process(spawner: &FakeSpawner, index: usize) -> FakeProcess {
    until(|| spawner.processes.lock().unwrap().len() > index);
    spawner.processes.lock().unwrap()[index].clone()
}

#[test]
fn stream_copy_arguments_and_chunked_mjpeg() {
    let args = ffmpeg_args(
        CaptureMode {
            width: 1280,
            height: 720,
            fps: 30,
        },
        "/dev/video1",
    );
    for pair in [
        ["-c:v", "copy"],
        ["-video_size", "1280x720"],
        ["-i", "/dev/video1"],
        ["-input_format", "mjpeg"],
    ] {
        assert!(args.windows(2).any(|p| p == pair));
    }
    let mut splitter = MjpegSplitter::default();
    let mut frames = Vec::new();
    for chunk in LIT.repeat(4).chunks(7) {
        frames.extend(splitter.push(chunk));
    }
    assert_eq!(frames.len(), 3);
    assert!(
        frames
            .iter()
            .all(|jpeg| decode_jpeg(jpeg).unwrap().width == 16)
    );
    splitter.push(&vec![0; CAPTURE_BUFFER_LIMIT + 1]);
    assert_eq!(splitter.buffered(), 0);
}

#[test]
fn real_decode_newest_frame_wins_and_stop_drops_picture() {
    let (controller, spawner) = setup("", Duration::from_secs(10));
    controller.start();
    let child = process(&spawner, 0);
    child.frames(LIT, 200);
    until(|| {
        let s = controller.state();
        s.frames_total + s.frames_dropped == 199
    });
    let state = controller.state();
    assert_eq!(state.state, CaptureState::Streaming);
    assert_eq!(state.frame.unwrap().width, 16);
    assert_eq!(state.bytes_total, (LIT.len() * 200) as u64);
    assert_eq!(state.decode_errors, 0);
    controller.stop();
    assert!(child.state.lock().unwrap().killed);
    assert_eq!(controller.state().state, CaptureState::Idle);
    assert!(controller.state().frame.is_none());
    assert!(!controller.state().running);
}

#[test]
fn signal_requires_sampled_evidence_and_recovers_on_picture() {
    let dark = decode_jpeg(DARK).unwrap();
    let console = decode_jpeg(CONSOLE).unwrap();
    let mut signal = SignalDetector::default();
    for i in 0..CAPTURE_BLACK_STREAK - 1 {
        assert!(!signal.sample(CAPTURE_SIGNAL_CHECK * i as u32, &dark));
    }
    // A rate-limited sample must not count as another black frame.
    assert!(!signal.sample(
        CAPTURE_SIGNAL_CHECK * (CAPTURE_BLACK_STREAK - 2) as u32,
        &dark
    ));
    assert!(signal.sample(Duration::from_secs(60), &dark));
    assert!(!signal.sample(Duration::from_secs(61), &console));
    assert_eq!(signal.black_streak, 0);
    let mut stalled = SignalDetector::default();
    for seconds in [0, 1, 30, 60] {
        assert!(!stalled.sample(Duration::from_secs(seconds), &dark));
    }
    for i in 0..60 {
        assert!(!stalled.sample(Duration::from_secs(61) + CAPTURE_SIGNAL_CHECK * i, &console));
    }
}

#[test]
fn garbage_is_counted_without_killing_the_stream() {
    let (controller, spawner) = setup("", Duration::from_secs(10));
    controller.start();
    let child = process(&spawner, 0);
    child.pipe.emit(&[255, 216, 255, 0, 1, 2, 255, 216, 255]);
    until(|| controller.state().decode_errors > 0);
    child.frames(LIT, 3);
    until(|| controller.state().state == CaptureState::Streaming);
    assert!(controller.state().running);
}

#[test]
fn process_error_surfaces_stderr_and_retries() {
    let (controller, spawner) = setup("", Duration::from_millis(150));
    *spawner.stderr.lock().unwrap() = "device busy\n".into();
    controller.start();
    process(&spawner, 0).exit(1);
    until(|| controller.state().state == CaptureState::Failed);
    assert!(controller.state().error.unwrap().contains("device busy"));
    process(&spawner, 1);
}

#[test]
fn configured_device_never_falls_through_to_another_input() {
    let (controller, spawner) = setup("/dev/video1", Duration::from_millis(20));
    *spawner.stderr.lock().unwrap() = "not a video capture device\n".into();
    controller.start();
    process(&spawner, 0).exit(1);
    process(&spawner, 1);
    for args in spawner.calls.lock().unwrap().iter() {
        assert!(args.windows(2).any(|p| p == ["-i", "/dev/video1"]));
    }
}

#[test]
fn discovery_skips_wrong_nodes_and_reconsiders_them_next_cycle() {
    let (controller, spawner) = setup("", Duration::from_millis(20));
    *spawner.stderr.lock().unwrap() = "not a video capture device\n".into();
    controller.start();
    process(&spawner, 0).exit(1);
    process(&spawner, 1).exit(1);
    process(&spawner, 2);
    let paths: Vec<_> = spawner
        .calls
        .lock()
        .unwrap()
        .iter()
        .map(|args| args[args.iter().position(|a| a == "-i").unwrap() + 1].clone())
        .collect();
    assert_eq!(paths, ["/dev/video0", "/dev/video1", "/dev/video0"]);
}

#[test]
fn deliberate_restart_cannot_be_retried_by_old_exit_or_decode() {
    let (controller, spawner) = setup("", Duration::from_millis(20));
    controller.start();
    let old = process(&spawner, 0);
    old.frames(LIT, 100);
    controller.set_mode(CaptureMode {
        width: 640,
        height: 480,
        fps: 15,
    });
    let replacement = process(&spawner, 1);
    assert!(old.state.lock().unwrap().killed);
    replacement.frames(CONSOLE, 3);
    until(|| controller.state().frame.is_some_and(|f| f.width == 32));
    thread::sleep(Duration::from_millis(100));
    assert_eq!(spawner.calls.lock().unwrap().len(), 2);
    let calls = spawner.calls.lock().unwrap();
    assert!(calls[1].windows(2).any(|p| p == ["-video_size", "640x480"]));
    drop(calls);
    replacement.frames(LIT, 100);
    controller.stop();
    thread::sleep(Duration::from_millis(100));
    assert_eq!(controller.state().state, CaptureState::Idle);
    assert!(controller.state().frame.is_none());
    assert_eq!(spawner.calls.lock().unwrap().len(), 2);
}

#[test]
fn spawn_failure_retries_only_while_requested() {
    let (controller, spawner) = setup("", Duration::from_millis(80));
    *spawner.failures.lock().unwrap() = 1;
    controller.start();
    until(|| controller.state().state == CaptureState::Failed);
    assert!(
        controller
            .state()
            .error
            .unwrap()
            .contains("fake ffmpeg missing")
    );
    process(&spawner, 0);
    controller.stop();
    let count = spawner.calls.lock().unwrap().len();
    thread::sleep(Duration::from_millis(150));
    assert_eq!(spawner.calls.lock().unwrap().len(), count);
}

#[test]
fn sustained_black_stream_sets_no_signal_and_console_clears_it() {
    let (controller, spawner) = setup("", Duration::from_secs(10));
    controller.start();
    let child = process(&spawner, 0);
    // Keep frames flowing like a camera. Decoder scheduling may skip a sampling
    // interval under load; wait for observed state instead of counting writes.
    for (jpeg, expected) in [
        (DARK, CaptureState::NoSignal),
        (CONSOLE, CaptureState::Streaming),
    ] {
        let deadline = Instant::now() + Duration::from_secs(8);
        while controller.state().state != expected {
            assert!(
                Instant::now() < deadline,
                "stream did not reach {expected:?}: {:?}",
                controller.state().state
            );
            child.frames(jpeg, 2);
            thread::sleep(CAPTURE_SIGNAL_CHECK + Duration::from_millis(10));
        }
        assert!(
            controller.state().fps > 0.,
            "black video is still a flowing stream"
        );
    }
    assert_eq!(controller.state().frame.unwrap().width, 32);
}
