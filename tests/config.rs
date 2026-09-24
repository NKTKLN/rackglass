use rackglass::Config;
use std::{
    collections::HashMap,
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static ID: AtomicUsize = AtomicUsize::new(0);
struct Dir(PathBuf);
impl Dir {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "rackglass-config-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn defaults_match_dart() {
    let c = Config::default();
    assert_eq!(c.prom_url, "http://localhost:9090");
    assert_eq!(c.poll_seconds, 5);
    assert_eq!(c.snapshot_stale_after().as_secs(), 15);
    assert_eq!(c.capture_device, "/dev/video0");
    assert_eq!((c.capture_w, c.capture_h, c.capture_fps), (1024, 600, 30));
    assert_eq!(c.ffmpeg, "ffmpeg");
    assert_eq!(c.hypervisor, "pve-host");
    assert_eq!(
        c.net_device_exclude,
        "^(lo|veth.*|tap.*|fwbr.*|fwln.*|fwpr.*|vmbr.*|docker.*|br-.*|virbr.*)$"
    );
}
#[test]
fn file_then_environment_with_empty_strings_and_invalid_numbers() {
    let file = "# comment\n PROM_URL = http://file:9090 \nPOLL_SECONDS=30\nCAPTURE_W=800\nCAPTURE_H=480\nCAPTURE_FPS=24\nCAPTURE_DEVICE=/dev/video7\nFFMPEG=/bin/custom\nNET_DEVICE_EXCLUDE=^(lo|x=y)$\nHYPERVISOR=host\nignored\n";
    let vars = HashMap::from([
        ("PROM_URL".into(), "http://env:9090".into()),
        ("POLL_SECONDS".into(), "10".into()),
        ("CAPTURE_DEVICE".into(), "".into()),
    ]);
    let c = Config::from_sources(file, &vars);
    assert_eq!(c.prom_url, "http://env:9090");
    assert_eq!(c.poll_seconds, 10);
    assert_eq!(c.snapshot_stale_after().as_secs(), 30);
    assert_eq!((c.capture_w, c.capture_h, c.capture_fps), (800, 480, 24));
    assert_eq!(c.capture_device, "");
    assert_eq!(c.ffmpeg, "/bin/custom");
    assert_eq!(c.net_device_exclude, "^(lo|x=y)$");
    assert_eq!(c.hypervisor, "host");
    let c = Config::from_sources(
        "POLL_SECONDS=no\nCAPTURE_W=-1\nCAPTURE_FPS=oops",
        &HashMap::new(),
    );
    assert_eq!(c.poll_seconds, 5);
    assert_eq!(c.capture_w, 1024);
    assert_eq!(c.capture_fps, 30);
}
#[test]
fn config_file_selection_and_missing_explicit_file() {
    let d = Dir::new();
    let local = d.0.join("local");
    let system = d.0.join("system");
    let explicit = d.0.join("explicit");
    let mut vars = HashMap::new();
    assert_eq!(
        Config::load_with(&vars, &local, &system)
            .unwrap()
            .poll_seconds,
        5
    );
    fs::write(&system, "POLL_SECONDS=10").unwrap();
    assert_eq!(
        Config::load_with(&vars, &local, &system)
            .unwrap()
            .poll_seconds,
        10
    );
    fs::write(&local, "POLL_SECONDS=20").unwrap();
    assert_eq!(
        Config::load_with(&vars, &local, &system)
            .unwrap()
            .poll_seconds,
        20
    );
    vars.insert(
        "RACKGLASS_CONFIG".into(),
        explicit.to_string_lossy().into_owned(),
    );
    assert!(Config::load_with(&vars, &local, &system).is_err());
    fs::write(&explicit, "POLL_SECONDS=30").unwrap();
    assert_eq!(
        Config::load_with(&vars, &local, &system)
            .unwrap()
            .poll_seconds,
        30
    );
    vars.insert("POLL_SECONDS".into(), "40".into());
    assert_eq!(
        Config::load_with(&vars, &local, &system)
            .unwrap()
            .poll_seconds,
        40
    );
}
