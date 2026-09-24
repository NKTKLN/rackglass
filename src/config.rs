//! Runtime configuration and the shared rules behind the dashboard.
use std::{collections::HashMap, env, fs, io, path::Path, time::Duration};

pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(6);
pub const HISTORY_DEPTH: usize = 120;
/// One definition, so a red bar and a red glyph mean the same thing.
pub const LOAD_WARN: f64 = 75.0;
pub const LOAD_CRITICAL: f64 = 90.0;
pub const RANGE_REFRESH: Duration = Duration::from_secs(60);
/// Seven-day TSDB scans need not run on every five-second node poll.
pub const GPU_FALLBACK_REFRESH: Duration = Duration::from_secs(60);
pub const GPU_STALE_AFTER: Duration = Duration::from_secs(120);
pub const CAPTURE_RETRY: Duration = Duration::from_secs(2);
/// A desynced JPEG stream must not grow without bound.
pub const CAPTURE_BUFFER_LIMIT: usize = 8 << 20;
pub const CAPTURE_SIGNAL_CHECK: Duration = Duration::from_millis(100);
/// Count evidence, not elapsed time: a stalled stream must not advance a streak.
pub const CAPTURE_BLACK_STREAK: usize = 30;
pub const CAPTURE_BLACK_LEVEL: f64 = 12.0;
/// A bright patch distinguishes a sparse console from a uniformly black input.
pub const CAPTURE_PEAK_LEVEL: f64 = 24.0;

#[derive(Clone, Debug)]
pub struct Config {
    /// Localhost deliberately makes an unconfigured deployment fail obviously.
    pub prom_url: String,
    pub poll_seconds: u64,
    /// Exclude virtual interfaces so the same bridged packet is not counted twice.
    pub net_device_exclude: String,
    pub hypervisor: String,
    /// Name the capture node outright: rebooting can swap UVC node indices.
    pub capture_device: String,
    pub capture_w: u32,
    pub capture_h: u32,
    pub capture_fps: u32,
    pub ffmpeg: String,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            prom_url: "http://localhost:9090".into(),
            poll_seconds: 5,
            net_device_exclude:
                "^(lo|veth.*|tap.*|fwbr.*|fwln.*|fwpr.*|vmbr.*|docker.*|br-.*|virbr.*)$".into(),
            hypervisor: "pve-host".into(),
            capture_device: "/dev/video0".into(),
            capture_w: 1024,
            capture_h: 600,
            capture_fps: 30,
            ffmpeg: "ffmpeg".into(),
        }
    }
}
impl Config {
    /// Environment wins over the optional KEY=VALUE file. An explicit missing
    /// file is an error; absent default files simply leave the defaults in place.
    pub fn load() -> io::Result<Self> {
        Self::load_with(
            &env::vars().collect(),
            Path::new("config.env"),
            Path::new("/etc/rackglass/config.env"),
        )
    }
    /// Inject paths and environment without changing process-global state.
    pub fn load_with(
        vars: &HashMap<String, String>,
        local: &Path,
        system: &Path,
    ) -> io::Result<Self> {
        let file = if let Some(path) = vars.get("RACKGLASS_CONFIG") {
            fs::read_to_string(path)?
        } else {
            match fs::read_to_string(local) {
                Ok(s) => s,
                Err(e) if e.kind() == io::ErrorKind::NotFound => match fs::read_to_string(system) {
                    Ok(s) => s,
                    Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
                    Err(e) => return Err(e),
                },
                Err(e) => return Err(e),
            }
        };
        Ok(Self::from_sources(&file, vars))
    }
    pub fn from_sources(file: &str, vars: &HashMap<String, String>) -> Self {
        let mut values: HashMap<String, String> = file
            .lines()
            .filter_map(|line| {
                let line = line.trim();
                if line.starts_with('#') {
                    return None;
                }
                let (k, v) = line.split_once('=')?;
                Some((k.trim().to_owned(), v.trim().to_owned()))
            })
            .collect();
        values.extend(vars.clone());
        let mut c = Self::default();
        macro_rules! string {
            ($key:literal, $field:ident) => {
                if let Some(v) = values.get($key) {
                    c.$field = v.clone();
                }
            };
        }
        macro_rules! number {
            ($key:literal, $field:ident) => {
                if let Some(v) = values.get($key).and_then(|s| s.parse().ok()) {
                    c.$field = v;
                }
            };
        }
        string!("PROM_URL", prom_url);
        string!("NET_DEVICE_EXCLUDE", net_device_exclude);
        string!("HYPERVISOR", hypervisor);
        string!("CAPTURE_DEVICE", capture_device);
        string!("FFMPEG", ffmpeg);
        number!("POLL_SECONDS", poll_seconds);
        number!("CAPTURE_W", capture_w);
        number!("CAPTURE_H", capture_h);
        number!("CAPTURE_FPS", capture_fps);
        c
    }
    /// Never zero: POLL_SECONDS=0 would otherwise poll back to back.
    pub fn poll_interval(&self) -> Duration {
        Duration::from_secs(self.poll_seconds.max(1))
    }
    /// Three missed polls, whatever the interval is. A fixed fifteen seconds
    /// silently becomes one missed poll when somebody slows polling down.
    pub fn snapshot_stale_after(&self) -> Duration {
        self.poll_interval().saturating_mul(3)
    }
}
