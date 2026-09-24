//! MJPEG capture with bounded queues and generation-guarded publication.
//! A hidden capture screen owns no decoder or ffmpeg process.
use crate::config::*;
use std::{
    collections::{BTreeSet, VecDeque},
    fs,
    io::{self, Read},
    process::{Child, Command, Stdio},
    sync::{Arc, Condvar, Mutex},
    thread,
    time::{Duration, Instant},
};
use zune_core::{bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions};
use zune_jpeg::JpegDecoder;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CaptureState {
    #[default]
    Idle,
    Starting,
    Streaming,
    NoSignal,
    Failed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CaptureMode {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
}
impl CaptureMode {
    pub fn label(self) -> String {
        format!("{}x{}@{}", self.width, self.height, self.fps)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaptureDevice {
    pub path: String,
    pub name: String,
}
impl CaptureDevice {
    pub fn short(&self) -> &str {
        self.path.strip_prefix("/dev/").unwrap_or(&self.path)
    }
}
#[derive(Clone, Debug)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgb: Vec<u8>,
}
#[derive(Clone, Debug)]
pub struct CaptureSnapshot {
    pub state: CaptureState,
    pub error: Option<String>,
    pub frame: Option<Arc<Frame>>,
    pub mode: CaptureMode,
    pub device: Option<CaptureDevice>,
    pub devices: Vec<CaptureDevice>,
    pub running: bool,
    pub frames_total: u64,
    pub frames_dropped: u64,
    pub decode_errors: u64,
    pub bytes_total: u64,
    pub fps: f64,
    pub uptime: Option<Duration>,
    pub stderr_tail: Vec<String>,
    pub generation: u64,
}
impl CaptureSnapshot {
    pub fn source_label(&self) -> String {
        self.device
            .as_ref()
            .map(|d| format!("{} · {}", d.short(), d.name))
            .unwrap_or_else(|| "no device".into())
    }
}
/// Process handles are injectable; fake pipes exercise the real framing and JPEG decoder.
pub trait CaptureProcess: Send {
    fn stdout(&mut self) -> Box<dyn Read + Send>;
    fn stderr(&mut self) -> Box<dyn Read + Send>;
    fn try_wait(&mut self) -> io::Result<Option<i32>>;
    fn kill(&mut self);
}
pub trait ProcessSpawner: Send + Sync {
    fn spawn(&self, executable: &str, args: &[String]) -> io::Result<Box<dyn CaptureProcess>>;
}
pub struct FfmpegSpawner;
struct FfmpegProcess(Child);
impl CaptureProcess for FfmpegProcess {
    fn stdout(&mut self) -> Box<dyn Read + Send> {
        Box::new(self.0.stdout.take().unwrap())
    }
    fn stderr(&mut self) -> Box<dyn Read + Send> {
        Box::new(self.0.stderr.take().unwrap())
    }
    fn try_wait(&mut self) -> io::Result<Option<i32>> {
        self.0
            .try_wait()
            .map(|status| status.map(|status| status.code().unwrap_or(-1)))
    }
    fn kill(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
impl ProcessSpawner for FfmpegSpawner {
    fn spawn(&self, executable: &str, args: &[String]) -> io::Result<Box<dyn CaptureProcess>> {
        Ok(Box::new(FfmpegProcess(
            Command::new(executable)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()?,
        )))
    }
}
pub fn ffmpeg_args(mode: CaptureMode, device: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        "-fflags",
        "nobuffer",
        "-flags",
        "low_delay",
        "-f",
        "v4l2",
        "-input_format",
        "mjpeg",
        "-video_size",
        &format!("{}x{}", mode.width, mode.height),
        "-framerate",
        &mode.fps.to_string(),
        "-i",
        device,
        "-f",
        "mjpeg",
        "-c:v",
        "copy",
        "-",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}
pub fn discover_devices() -> Vec<CaptureDevice> {
    let mut found = Vec::new();
    if let Ok(entries) = fs::read_dir("/dev") {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name
                .strip_prefix("video")
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            {
                found.push(CaptureDevice {
                    path: format!("/dev/{name}"),
                    name: fs::read_to_string(format!("/sys/class/video4linux/{name}/name"))
                        .unwrap_or_else(|_| "v4l2 device".into())
                        .trim()
                        .into(),
                });
            }
        }
    }
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}
/// A frame ends at the next SOI marker, even when a marker spans pipe reads.
/// Retain the unfinished tail; cap junk so a desynchronised device cannot
/// consume unbounded memory on the panel.
#[derive(Default)]
pub struct MjpegSplitter {
    buffer: Vec<u8>,
}
impl MjpegSplitter {
    pub fn push(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(chunk);
        let mut frames = Vec::new();
        let starts: Vec<_> = self
            .buffer
            .windows(3)
            .enumerate()
            .filter_map(|(i, w)| (w == [255, 216, 255]).then_some(i))
            .collect();
        for pair in starts.windows(2) {
            if pair[1] >= pair[0] + 3 {
                frames.push(self.buffer[pair[0]..pair[1]].to_vec());
            }
        }
        if let Some(last) = starts.last() {
            self.buffer.drain(..*last);
        }
        if self.buffer.len() > CAPTURE_BUFFER_LIMIT {
            self.buffer.clear();
        }
        frames
    }
    pub fn buffered(&self) -> usize {
        self.buffer.len()
    }
}
/// Box filtering covers every source pixel, including sparse console glyphs.
/// Sampling individual taps between glyphs incorrectly reports a black input.
pub fn signal_levels(frame: &Frame) -> (f64, f64) {
    if frame.width == 0 || frame.height == 0 {
        return (0., 0.);
    }
    let (mut sum, mut peak) = (0., 0.0_f64);
    for ty in 0..36u32 {
        for tx in 0..64u32 {
            let x0 = tx * frame.width / 64;
            let x1 = ((tx + 1) * frame.width / 64).max(x0 + 1).min(frame.width);
            let y0 = ty * frame.height / 36;
            let y1 = ((ty + 1) * frame.height / 36).max(y0 + 1).min(frame.height);
            let mut total = 0u64;
            let mut count = 0u64;
            for y in y0..y1 {
                for x in x0..x1 {
                    let i = ((y * frame.width + x) * 3) as usize;
                    if let Some(p) = frame.rgb.get(i..i + 3) {
                        total += p.iter().map(|b| *b as u64).sum::<u64>();
                        count += 3;
                    }
                }
            }
            let brightness = if count == 0 {
                0.
            } else {
                total as f64 / count as f64
            };
            sum += brightness;
            peak = peak.max(brightness);
        }
    }
    (sum / (64. * 36.), peak)
}
/// Count sampled black frames rather than wall time: a stalled stream provides
/// no new evidence. A bright console glyph clears the streak immediately.
#[derive(Default, Debug)]
pub struct SignalDetector {
    pub black_streak: usize,
    last: Option<Duration>,
    pub no_signal: bool,
}
impl SignalDetector {
    pub fn sample(&mut self, now: Duration, frame: &Frame) -> bool {
        if self
            .last
            .is_some_and(|t| now.saturating_sub(t) < CAPTURE_SIGNAL_CHECK)
        {
            return self.no_signal;
        }
        self.last = Some(now);
        let (mean, peak) = signal_levels(frame);
        if mean >= CAPTURE_BLACK_LEVEL || peak >= CAPTURE_PEAK_LEVEL {
            self.black_streak = 0;
            self.no_signal = false;
        } else {
            self.black_streak += 1;
            if self.black_streak >= CAPTURE_BLACK_STREAK {
                self.no_signal = true;
            }
        }
        self.no_signal
    }
}
pub fn decode_jpeg(bytes: &[u8]) -> Result<Frame, String> {
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut decoder = JpegDecoder::new_with_options(ZCursor::new(bytes), options);
    let rgb = decoder.decode().map_err(|e| e.to_string())?;
    let (width, height) = decoder.dimensions().ok_or("JPEG has no dimensions")?;
    Ok(Frame {
        width: width as u32,
        height: height as u32,
        rgb,
    })
}
/// Fit the whole source; fullscreen never crops it or restarts the process.
pub fn letterbox(source: (u32, u32), viewport: (f32, f32)) -> (f32, f32, f32, f32) {
    if source.0 == 0 || source.1 == 0 {
        return (0., 0., 0., 0.);
    }
    let scale = (viewport.0 / source.0 as f32)
        .min(viewport.1 / source.1 as f32)
        .max(0.);
    let w = source.0 as f32 * scale;
    let h = source.1 as f32 * scale;
    ((viewport.0 - w) / 2., (viewport.1 - h) / 2., w, h)
}
struct Session {
    snapshot: CaptureSnapshot,
    pinned: bool,
    started: Option<Instant>,
    times: VecDeque<Instant>,
    process: Option<Arc<Mutex<Box<dyn CaptureProcess>>>>,
}
type Changed = Arc<dyn Fn() + Send + Sync>;
struct Core {
    cfg: Config,
    spawner: Arc<dyn ProcessSpawner>,
    fixed_devices: Option<Vec<CaptureDevice>>,
    retry: Duration,
    state: Mutex<Session>,
    wake: Condvar,
    changed: Mutex<Option<Changed>>,
}
impl Core {
    fn active(&self, generation: u64) -> bool {
        let session = self.state.lock().unwrap();
        session.snapshot.running && session.snapshot.generation == generation
    }
    fn notify(&self) {
        let f = self.changed.lock().unwrap().clone();
        if let Some(f) = f {
            f();
        }
    }
    fn update(&self, generation: u64, f: impl FnOnce(&mut Session)) -> bool {
        {
            let mut session = self.state.lock().unwrap();
            if !session.snapshot.running || session.snapshot.generation != generation {
                return false;
            }
            f(&mut session);
        }
        self.notify();
        true
    }
    fn pause(&self, generation: u64, delay: Duration) -> bool {
        let session = self.state.lock().unwrap();
        let (session, _) = self
            .wake
            .wait_timeout_while(session, delay, |session| {
                session.snapshot.running && session.snapshot.generation == generation
            })
            .unwrap();
        session.snapshot.running && session.snapshot.generation == generation
    }
}
/// Owns capture only while requested. Every asynchronous result belongs to a
/// generation, invalidated before killing the child so an immediate exit or a
/// late decode cannot mutate a replacement session.
pub struct CaptureController {
    core: Arc<Core>,
}
impl CaptureController {
    pub fn new(cfg: Config) -> Self {
        Self::with_spawner(cfg, Arc::new(FfmpegSpawner), None, CAPTURE_RETRY)
    }
    pub fn with_spawner(
        cfg: Config,
        spawner: Arc<dyn ProcessSpawner>,
        devices: Option<Vec<CaptureDevice>>,
        retry: Duration,
    ) -> Self {
        let mode = CaptureMode {
            width: cfg.capture_w,
            height: cfg.capture_h,
            fps: cfg.capture_fps,
        };
        let controller = Self {
            core: Arc::new(Core {
                cfg,
                spawner,
                fixed_devices: devices,
                retry,
                state: Mutex::new(Session {
                    snapshot: CaptureSnapshot {
                        state: CaptureState::Idle,
                        error: None,
                        frame: None,
                        mode,
                        device: None,
                        devices: vec![],
                        running: false,
                        frames_total: 0,
                        frames_dropped: 0,
                        decode_errors: 0,
                        bytes_total: 0,
                        fps: 0.,
                        uptime: None,
                        stderr_tail: vec![],
                        generation: 0,
                    },
                    pinned: false,
                    started: None,
                    times: VecDeque::new(),
                    process: None,
                }),
                wake: Condvar::new(),
                changed: Mutex::new(None),
            }),
        };
        controller.discover();
        controller
    }
    pub fn on_change(&self, callback: impl Fn() + Send + Sync + 'static) {
        *self.core.changed.lock().unwrap() = Some(Arc::new(callback));
    }
    pub fn state(&self) -> CaptureSnapshot {
        let mut session = self.core.state.lock().unwrap();
        let now = Instant::now();
        while session
            .times
            .front()
            .is_some_and(|t| now.duration_since(*t) > Duration::from_secs(2))
        {
            session.times.pop_front();
        }
        let span = session
            .times
            .back()
            .zip(session.times.front())
            .map(|(a, b)| a.duration_since(*b).as_secs_f64())
            .unwrap_or(0.);
        session.snapshot.fps = if span > 0. {
            session.times.len().saturating_sub(1) as f64 / span
        } else {
            0.
        };
        session.snapshot.uptime = session.started.map(|t| now.duration_since(t));
        session.snapshot.clone()
    }
    /// A configured device is pinned: falling through to another node would
    /// silently show an input the deployment never requested.
    pub fn discover(&self) {
        let devices = self
            .core
            .fixed_devices
            .clone()
            .unwrap_or_else(discover_devices);
        {
            let mut session = self.core.state.lock().unwrap();
            session.snapshot.devices = devices.clone();
            if !self.core.cfg.capture_device.is_empty() {
                session.snapshot.device = Some(
                    devices
                        .iter()
                        .find(|d| d.path == self.core.cfg.capture_device)
                        .cloned()
                        .unwrap_or_else(|| CaptureDevice {
                            path: self.core.cfg.capture_device.clone(),
                            name: "v4l2 device".into(),
                        }),
                );
                session.pinned = true;
            } else if !session.pinned
                && session
                    .snapshot
                    .device
                    .as_ref()
                    .is_none_or(|d| !devices.contains(d))
            {
                session.snapshot.device = devices.first().cloned();
            }
        }
        self.core.notify();
    }
    pub fn start(&self) {
        if self.state().running {
            return;
        }
        self.restart(true);
    }
    pub fn stop(&self) {
        self.restart(false);
    }
    pub fn set_mode(&self, mode: CaptureMode) {
        {
            let mut session = self.core.state.lock().unwrap();
            if session.snapshot.mode == mode {
                return;
            }
            session.snapshot.mode = mode;
        }
        if self.state().running {
            self.restart(true);
        } else {
            self.core.notify();
        }
    }
    fn restart(&self, running: bool) {
        let (generation, old) = {
            let mut session = self.core.state.lock().unwrap();
            // Invalidate before kill: a fake or real exit can be immediate.
            session.snapshot.generation += 1;
            session.snapshot.running = running;
            session.snapshot.state = if running {
                CaptureState::Starting
            } else {
                CaptureState::Idle
            };
            session.snapshot.frame = None;
            session.snapshot.error = None;
            session.started = None;
            session.times.clear();
            (session.snapshot.generation, session.process.take())
        };
        self.core.wake.notify_all();
        if let Some(old) = old {
            old.lock().unwrap().kill();
        }
        self.core.notify();
        if running {
            let core = self.core.clone();
            thread::spawn(move || run_sessions(core, generation));
        }
    }
}
impl Drop for CaptureController {
    fn drop(&mut self) {
        self.stop();
    }
}
fn wrong_node(message: &str) -> bool {
    let message = message.to_lowercase();
    [
        "not a video capture",
        "not a capture device",
        "inappropriate ioctl",
        "not a video4linux2 device",
    ]
    .iter()
    .any(|p| message.contains(p))
}
/// Keep one waiting JPEG. Decoding an old backlog wastes CPU and adds latency;
/// replacing the pending frame keeps the picture current under load.
struct Latest {
    pending: Option<Vec<u8>>,
    closed: bool,
}
fn run_sessions(core: Arc<Core>, mut generation: u64) {
    let mut tried = BTreeSet::new();
    loop {
        if !core.active(generation) {
            return;
        }
        let devices = core.fixed_devices.clone().unwrap_or_else(discover_devices);
        core.update(generation, |session| {
            session.snapshot.devices = devices.clone();
            if !session.pinned
                && session
                    .snapshot
                    .device
                    .as_ref()
                    .is_none_or(|d| !devices.contains(d))
            {
                session.snapshot.device = devices.first().cloned();
            }
        });
        let (mode, device) = {
            let session = core.state.lock().unwrap();
            (session.snapshot.mode, session.snapshot.device.clone())
        };
        let error = if let Some(device) = device {
            capture_session(&core, generation, mode, &device.path)
        } else {
            Some("no /dev/video* node found".into())
        };
        let Some(error) = error else {
            return;
        };
        if !core.active(generation) {
            return;
        }
        let mut next = false;
        core.update(generation, |session| {
            if !session.pinned && wrong_node(&error) {
                if let Some(d) = &session.snapshot.device {
                    tried.insert(d.path.clone());
                }
                if let Some(d) = session
                    .snapshot
                    .devices
                    .iter()
                    .find(|d| !tried.contains(&d.path))
                    .cloned()
                {
                    session.snapshot.device = Some(d);
                    next = true;
                }
            }
            session.snapshot.state = CaptureState::Failed;
            session.snapshot.error = Some(error.clone());
        });
        if !next {
            if !core.pause(generation, core.retry) {
                return;
            }
            tried.clear();
            core.update(generation, |session| {
                if !session.pinned {
                    session.snapshot.device = session.snapshot.devices.first().cloned();
                }
            });
        }
        // Each retry is a new generation too: old pipe/decoder callbacks may
        // still be returning after the process has been reaped.
        {
            let mut session = core.state.lock().unwrap();
            if !session.snapshot.running || session.snapshot.generation != generation {
                return;
            }
            session.snapshot.generation += 1;
            generation = session.snapshot.generation;
            session.snapshot.frame = None;
        }
    }
}
fn capture_session(
    core: &Arc<Core>,
    generation: u64,
    mode: CaptureMode,
    path: &str,
) -> Option<String> {
    if !core.update(generation, |session| {
        session.snapshot.state = CaptureState::Starting;
        session.snapshot.error = None;
        session.snapshot.frame = None;
        session.snapshot.frames_total = 0;
        session.snapshot.frames_dropped = 0;
        session.snapshot.decode_errors = 0;
        session.snapshot.bytes_total = 0;
        session.snapshot.stderr_tail.clear();
        session.times.clear();
        session.started = Some(Instant::now());
    }) {
        return None;
    }
    let mut process = match core
        .spawner
        .spawn(&core.cfg.ffmpeg, &ffmpeg_args(mode, path))
    {
        Ok(p) => p,
        Err(e) => return Some(format!("cannot run {}: {e}", core.cfg.ffmpeg)),
    };
    if !core.active(generation) {
        process.kill();
        return None;
    }
    let mut stdout = process.stdout();
    let mut stderr = process.stderr();
    let process = Arc::new(Mutex::new(process));
    if !core.update(generation, |session| {
        session.process = Some(process.clone())
    }) {
        process.lock().unwrap().kill();
        return None;
    }
    let latest = Arc::new((
        Mutex::new(Latest {
            pending: None,
            closed: false,
        }),
        Condvar::new(),
    ));
    let read_core = core.clone();
    let queue = latest.clone();
    let reader = thread::spawn(move || {
        let mut splitter = MjpegSplitter::default();
        let mut chunk = [0u8; 65536];
        while read_core.active(generation) {
            match stdout.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    {
                        let mut session = read_core.state.lock().unwrap();
                        if session.snapshot.generation != generation || !session.snapshot.running {
                            break;
                        }
                        session.snapshot.bytes_total += n as u64;
                    }
                    for jpeg in splitter.push(&chunk[..n]) {
                        let replaced = {
                            let mut pending = queue.0.lock().unwrap();
                            pending.pending.replace(jpeg).is_some()
                        };
                        if replaced {
                            read_core
                                .update(generation, |session| session.snapshot.frames_dropped += 1);
                        }
                        queue.1.notify_one();
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    read_core.update(generation, |session| {
                        session.snapshot.state = CaptureState::Failed;
                        session.snapshot.error = Some(format!("stdout: {e}"));
                    });
                    break;
                }
            }
        }
        queue.0.lock().unwrap().closed = true;
        queue.1.notify_all();
    });
    let decode_core = core.clone();
    let queue = latest.clone();
    let decoder = thread::spawn(move || {
        let mut signal = SignalDetector::default();
        let started = Instant::now();
        loop {
            let jpeg = {
                let mut pending = queue.0.lock().unwrap();
                while pending.pending.is_none() && !pending.closed {
                    pending = queue.1.wait(pending).unwrap();
                }
                pending.pending.take()
            };
            let Some(jpeg) = jpeg else {
                break;
            };
            if !decode_core.active(generation) {
                break;
            }
            match decode_jpeg(&jpeg) {
                Ok(frame) => {
                    let no_signal = signal.sample(started.elapsed(), &frame);
                    decode_core.update(generation, |session| {
                        session.snapshot.frame = Some(Arc::new(frame));
                        session.snapshot.frames_total += 1;
                        session.times.push_back(Instant::now());
                        session.snapshot.state = if no_signal {
                            CaptureState::NoSignal
                        } else {
                            CaptureState::Streaming
                        };
                        session.snapshot.error = None;
                    });
                }
                Err(_) => {
                    decode_core.update(generation, |session| session.snapshot.decode_errors += 1);
                }
            }
        }
    });
    let stderr_core = core.clone();
    let errors = thread::spawn(move || {
        let mut bytes = [0; 4096];
        let mut pending = String::new();
        loop {
            match stderr.read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => {
                    pending.push_str(&String::from_utf8_lossy(&bytes[..n]));
                    if !stderr_core.active(generation) {
                        return;
                    }
                    while let Some(i) = pending.find('\n') {
                        let line = pending.drain(..=i).collect::<String>();
                        append_stderr(&stderr_core, generation, line.trim());
                    }
                    if pending.len() > 8192 {
                        append_stderr(&stderr_core, generation, pending.trim());
                        pending.clear();
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        append_stderr(&stderr_core, generation, pending.trim());
    });
    let mut tick = Instant::now();
    let exit = loop {
        if !core.active(generation) {
            break None;
        }
        match process.lock().unwrap().try_wait() {
            Ok(Some(code)) => break Some(format!("ffmpeg exited with code {code}")),
            Err(e) => break Some(format!("ffmpeg wait: {e}")),
            Ok(None) => {}
        }
        if tick.elapsed() >= Duration::from_secs(1) {
            core.notify();
            tick = Instant::now();
        }
        // Wait wakes immediately on stop/restart; it never requests a repaint.
        if !core.pause(generation, Duration::from_millis(50)) {
            break None;
        }
    };
    process.lock().unwrap().kill();
    latest.0.lock().unwrap().closed = true;
    latest.1.notify_all();
    let _ = reader.join();
    let _ = decoder.join();
    let _ = errors.join();
    if !core.active(generation) {
        return None;
    }
    let mut session = core.state.lock().unwrap();
    if !session.snapshot.running || session.snapshot.generation != generation {
        return None;
    }
    session.process = None;
    exit.map(|fallback| {
        if session.snapshot.stderr_tail.is_empty() {
            session.snapshot.error.clone().unwrap_or(fallback)
        } else {
            session.snapshot.stderr_tail.join("\n")
        }
    })
}
fn append_stderr(core: &Core, generation: u64, line: &str) {
    if line.is_empty() {
        return;
    }
    let mut session = core.state.lock().unwrap();
    if !session.snapshot.running || session.snapshot.generation != generation {
        return;
    }
    session.snapshot.stderr_tail.push(line.to_owned());
    if session.snapshot.stderr_tail.len() > 4 {
        session.snapshot.stderr_tail.remove(0);
    }
}
