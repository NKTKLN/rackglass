//! One complete poll of the cluster, with missing readings kept missing.
use crate::config::{GPU_STALE_AFTER, LOAD_CRITICAL, LOAD_WARN};
use chrono::{DateTime, TimeDelta, Utc};

/// A named temperature reading off one hwmon chip.
#[derive(Clone, Debug, PartialEq)]
pub struct TempReading {
    pub instance: String,
    pub chip: String,
    pub sensor: String,
    /// Tctl, Tccd1, or the raw sensor id when the chip exposes no label.
    pub label: String,
    pub celsius: f64,
    /// A raw temp0 needs its datasheet: worth listing, not guessing about.
    pub named: bool,
}
impl TempReading {
    pub fn chip_short(&self) -> String {
        self.chip.split('_').take(2).collect::<Vec<_>>().join("_")
    }
}
/// Everything known about one node_exporter target.
#[derive(Clone, Debug, Default)]
pub struct NodeStat {
    pub instance: String,
    pub role: String,
    pub up: bool,
    pub is_hypervisor: bool,
    pub cpu_pct: Option<f64>,
    pub io_wait_pct: Option<f64>,
    pub cores: Option<f64>,
    pub mem_total: Option<f64>,
    pub mem_available: Option<f64>,
    pub swap_total: Option<f64>,
    pub swap_free: Option<f64>,
    pub load1: Option<f64>,
    pub load5: Option<f64>,
    pub load15: Option<f64>,
    pub boot_time: Option<f64>,
    pub fs_size: Option<f64>,
    pub fs_avail: Option<f64>,
    pub net_rx: Option<f64>,
    pub net_tx: Option<f64>,
}
fn percent(used: Option<f64>, total: Option<f64>) -> Option<f64> {
    let t = total?;
    if t > 0.0 {
        Some(used? / t * 100.0)
    } else {
        None
    }
}
impl NodeStat {
    pub fn mem_used(&self) -> Option<f64> {
        Some(self.mem_total? - self.mem_available?)
    }
    pub fn mem_pct(&self) -> Option<f64> {
        percent(self.mem_used(), self.mem_total)
    }
    pub fn swap_used(&self) -> Option<f64> {
        Some(self.swap_total? - self.swap_free?)
    }
    pub fn swap_pct(&self) -> Option<f64> {
        percent(self.swap_used(), self.swap_total)
    }
    pub fn fs_used(&self) -> Option<f64> {
        Some(self.fs_size? - self.fs_avail?)
    }
    pub fn fs_pct(&self) -> Option<f64> {
        percent(self.fs_used(), self.fs_size)
    }
    /// Normalised load compares a one-core VM honestly with the twelve-core host.
    pub fn load_per_core(&self) -> Option<f64> {
        let c = self.cores?;
        if c > 0.0 { Some(self.load1? / c) } else { None }
    }
    pub fn uptime(&self) -> Option<TimeDelta> {
        self.uptime_at(Utc::now())
    }
    pub fn uptime_at(&self, now: DateTime<Utc>) -> Option<TimeDelta> {
        Some(now - DateTime::from_timestamp_millis((self.boot_time? * 1000.0).round() as i64)?)
    }
}
/// Everything known about one GPU, plus how stale the readings are.
#[derive(Clone, Debug, Default)]
pub struct GpuStat {
    pub gpu: String,
    pub instance: String,
    pub model: String,
    pub uuid: Option<String>,
    pub exporter_up: bool,
    pub age_seconds: Option<f64>,
    pub temp: Option<f64>,
    pub mem_temp: Option<f64>,
    pub util: Option<f64>,
    pub fb_used_mib: Option<f64>,
    pub fb_free_mib: Option<f64>,
    pub power_watts: Option<f64>,
    pub sm_clock_mhz: Option<f64>,
    pub mem_clock_mhz: Option<f64>,
}
impl GpuStat {
    pub fn key(&self) -> String {
        format!(
            "{}/{}",
            self.instance,
            self.uuid.as_ref().unwrap_or(&self.gpu)
        )
    }
    pub fn age(&self) -> Option<TimeDelta> {
        TimeDelta::try_seconds(self.age_seconds?.round() as i64)
    }
    /// Historical numbers stay visible, but never pretend to be live.
    pub fn stale(&self) -> bool {
        !self.exporter_up
            || self
                .age_seconds
                .is_some_and(|s| s > GPU_STALE_AFTER.as_secs_f64())
    }
    pub fn fb_total_bytes(&self) -> Option<f64> {
        Some((self.fb_used_mib? + self.fb_free_mib?) * 1024.0 * 1024.0)
    }
    pub fn fb_used_bytes(&self) -> Option<f64> {
        Some(self.fb_used_mib? * 1024.0 * 1024.0)
    }
    pub fn fb_pct(&self) -> Option<f64> {
        percent(self.fb_used_bytes(), self.fb_total_bytes())
    }
    /// Trim Tesla V100-SXM2-16GB down for a panel title.
    pub fn model_short(&self) -> &str {
        for prefix in ["NVIDIA", "Tesla"] {
            if let Some(rest) = self.model.strip_prefix(prefix)
                && rest.starts_with(char::is_whitespace)
            {
                return rest.trim_start();
            }
        }
        &self.model
    }
}
/// Reachability is separate: a down target has unknown load, not idle load.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodeHealth {
    Unknown,
    Ok,
    Warn,
    Critical,
}
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub at: DateTime<Utc>,
    pub nodes: Vec<NodeStat>,
    pub gpus: Vec<GpuStat>,
    pub temps: Vec<TempReading>,
    pub fetch_millis: u128,
    pub hypervisor: String,
}
impl Snapshot {
    pub fn host(&self) -> Option<&NodeStat> {
        self.nodes.iter().find(|n| n.is_hypervisor)
    }
    pub fn vms(&self) -> Vec<&NodeStat> {
        self.nodes.iter().filter(|n| !n.is_hypervisor).collect()
    }
    pub fn gpus_for(&self, instance: &str) -> Vec<&GpuStat> {
        self.gpus
            .iter()
            .filter(|g| g.instance == instance)
            .collect()
    }
    pub fn temps_for(&self, instance: &str) -> Vec<&TempReading> {
        self.temps
            .iter()
            .filter(|t| t.instance == instance)
            .collect()
    }
    pub fn targets_down(&self) -> usize {
        self.nodes.iter().filter(|n| !n.up).count()
    }
    /// Yesterday's GPU utilisation must not keep a target amber today.
    pub fn health_of(&self, n: &NodeStat) -> NodeHealth {
        if !n.up {
            return NodeHealth::Unknown;
        }
        let mut readings: Vec<f64> = [n.cpu_pct, n.mem_pct(), n.fs_pct()]
            .into_iter()
            .flatten()
            .collect();
        for g in self.gpus_for(&n.instance) {
            if !g.stale() {
                readings.extend([g.util, g.fb_pct()].into_iter().flatten());
            }
        }
        match readings.into_iter().reduce(f64::max) {
            None => NodeHealth::Unknown,
            Some(v) if v >= LOAD_CRITICAL => NodeHealth::Critical,
            Some(v) if v >= LOAD_WARN => NodeHealth::Warn,
            _ => NodeHealth::Ok,
        }
    }
    /// Prefer canonical package labels. The hottest unrelated device is no CPU.
    pub fn cpu_package_temp(&self) -> Option<&TempReading> {
        ["Tctl", "Package id 0", "Tdie"].iter().find_map(|label| {
            self.temps
                .iter()
                .find(|t| t.instance == self.hypervisor && t.label == *label)
        })
    }
    pub fn other_host_temps(&self) -> Vec<&TempReading> {
        let pkg = self.cpu_package_temp();
        self.temps
            .iter()
            .filter(|t| {
                t.instance == self.hypervisor
                    && t.named
                    && !pkg.is_some_and(|p| std::ptr::eq(*t, p))
            })
            .collect()
    }
    /// Guest OS-reported memory, deliberately not Proxmox allocation/commitment.
    pub fn vm_mem_reported_total(&self) -> f64 {
        self.vms().iter().map(|n| n.mem_total.unwrap_or(0.0)).sum()
    }
    pub fn vm_mem_used(&self) -> f64 {
        self.vms().iter().map(|n| n.mem_used().unwrap_or(0.0)).sum()
    }
}
