//! Every PromQL expression the app issues, in one place.
use crate::config::{Config, GPU_STALE_AFTER};
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum InstantQuery {
    Up,
    CpuBusy,
    Cores,
    MemTotal,
    MemAvailable,
    SwapTotal,
    SwapFree,
    Load1,
    Load5,
    Load15,
    BootTime,
    FsSize,
    FsAvail,
    NetRx,
    NetTx,
    AllTemps,
    CpuIoWait,
    GpuTemp,
    GpuUtil,
    GpuFbUsed,
    GpuFbFree,
    GpuPower,
    GpuSmClock,
    GpuMemClock,
    GpuMemTemp,
    GpuAgeDeep,
    GpuAgeFresh,
}
pub const CPU_BUSY: &str =
    "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[2m])) * 100)";
pub const CPU_IO_WAIT: &str =
    "avg by (instance) (rate(node_cpu_seconds_total{mode=\"iowait\"}[2m])) * 100";
pub const CORES: &str = "count by (instance) (node_cpu_seconds_total{mode=\"idle\"})";
pub const MEM_TOTAL: &str = "node_memory_MemTotal_bytes";
pub const MEM_AVAILABLE: &str = "node_memory_MemAvailable_bytes";
pub const SWAP_TOTAL: &str = "node_memory_SwapTotal_bytes";
pub const SWAP_FREE: &str = "node_memory_SwapFree_bytes";
pub const LOAD1: &str = "node_load1";
pub const LOAD5: &str = "node_load5";
pub const LOAD15: &str = "node_load15";
pub const BOOT_TIME: &str = "node_boot_time_seconds";
pub const FS_SIZE: &str = "node_filesystem_size_bytes{mountpoint=\"/\"}";
pub const FS_AVAIL: &str = "node_filesystem_avail_bytes{mountpoint=\"/\"}";
pub const UP: &str = "up";
/// Labelled hwmon temperatures give readable names such as Tctl and Tccd1.
pub const CPU_TEMP: &str =
    "node_hwmon_temp_celsius * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label";
/// A left join: labelled series win while unmatched raw channels stay visible.
pub const ALL_TEMPS: &str = "(node_hwmon_temp_celsius * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label) or on(instance,chip,sensor) node_hwmon_temp_celsius";
/// Age while temperature remains in the normal Prometheus lookback window.
pub const GPU_AGE_FRESH: &str = "time() - timestamp(DCGM_FI_DEV_GPU_TEMP)";
/// An exporter can have been down for hours or days; search seven days back.
pub const GPU_AGE_DEEP: &str = "time() - max_over_time(timestamp(DCGM_FI_DEV_GPU_TEMP)[7d:5m])";
pub const RANGE_CPU: &str =
    "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[2m])) * 100)";
pub const RANGE_MEM_PCT: &str =
    "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100";
pub const RANGE_TEMP_CPU: &str =
    "node_hwmon_temp_celsius * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label";
pub const RANGE_TEMP_GPU: &str = "DCGM_FI_DEV_GPU_TEMP";
pub const RANGE_GPU_UTIL: &str = "DCGM_FI_DEV_GPU_UTIL";
/// End-to-end throughput per path, not NIC traffic. The exporter runs tens of
/// minutes apart, so hold each measurement until the next one arrives.
pub const RANGE_SPEEDTEST_DOWN: &str = "last_over_time(speedtest_download_bits_per_second[1h])";
/// Both directions are measured in one run and honestly share one axis.
pub const RANGE_SPEEDTEST_UP: &str = "last_over_time(speedtest_upload_bits_per_second[1h])";
pub const RANGE_SPEEDTEST_LATENCY: &str = "last_over_time(speedtest_latency_seconds[1h])";

/// Fresh selectors reject lookback-window ghosts; history is queried separately.
pub fn fresh_gpu(metric: &str) -> String {
    format!(
        "{metric} and on(instance,gpu,UUID) (time() - timestamp({metric}) < {})",
        GPU_STALE_AFTER.as_secs()
    )
}
pub fn last_gpu(metric: &str) -> String {
    format!("last_over_time({metric}[7d])")
}
/// Escape the configurable regex as a PromQL string without changing its meaning.
fn quote_regex(s: &str) -> String {
    serde_json::to_string(s).expect("string serialization")
}
pub fn net_rx(cfg: &Config) -> String {
    format!(
        "sum by (instance) (rate(node_network_receive_bytes_total{{device!~{}}}[2m]))",
        quote_regex(&cfg.net_device_exclude)
    )
}
pub fn net_tx(cfg: &Config) -> String {
    format!(
        "sum by (instance) (rate(node_network_transmit_bytes_total{{device!~{}}}[2m]))",
        quote_regex(&cfg.net_device_exclude)
    )
}
pub fn range_net_rx(cfg: &Config) -> String {
    net_rx(cfg)
}
pub fn gpu_temp() -> String {
    fresh_gpu("DCGM_FI_DEV_GPU_TEMP")
}
pub fn gpu_temp_last() -> String {
    last_gpu("DCGM_FI_DEV_GPU_TEMP")
}
pub fn gpu_mem_temp() -> String {
    fresh_gpu("DCGM_FI_DEV_MEMORY_TEMP")
}
pub fn gpu_mem_temp_last() -> String {
    last_gpu("DCGM_FI_DEV_MEMORY_TEMP")
}
pub fn gpu_util() -> String {
    fresh_gpu("DCGM_FI_DEV_GPU_UTIL")
}
pub fn gpu_util_last() -> String {
    last_gpu("DCGM_FI_DEV_GPU_UTIL")
}
pub fn gpu_fb_used() -> String {
    fresh_gpu("DCGM_FI_DEV_FB_USED")
}
pub fn gpu_fb_used_last() -> String {
    last_gpu("DCGM_FI_DEV_FB_USED")
}
pub fn gpu_fb_free() -> String {
    fresh_gpu("DCGM_FI_DEV_FB_FREE")
}
pub fn gpu_fb_free_last() -> String {
    last_gpu("DCGM_FI_DEV_FB_FREE")
}
pub fn gpu_power() -> String {
    fresh_gpu("DCGM_FI_DEV_POWER_USAGE")
}
pub fn gpu_power_last() -> String {
    last_gpu("DCGM_FI_DEV_POWER_USAGE")
}
pub fn gpu_sm_clock() -> String {
    fresh_gpu("DCGM_FI_DEV_SM_CLOCK")
}
pub fn gpu_sm_clock_last() -> String {
    last_gpu("DCGM_FI_DEV_SM_CLOCK")
}
pub fn gpu_mem_clock() -> String {
    fresh_gpu("DCGM_FI_DEV_MEM_CLOCK")
}
pub fn gpu_mem_clock_last() -> String {
    last_gpu("DCGM_FI_DEV_MEM_CLOCK")
}
/// Production and live smoke tests share this list so neither drifts behind.
pub fn instant_poll_queries(cfg: &Config) -> Vec<(InstantQuery, String)> {
    vec![
        (InstantQuery::Up, UP.into()),
        (InstantQuery::CpuBusy, CPU_BUSY.into()),
        (InstantQuery::Cores, CORES.into()),
        (InstantQuery::MemTotal, MEM_TOTAL.into()),
        (InstantQuery::MemAvailable, MEM_AVAILABLE.into()),
        (InstantQuery::SwapTotal, SWAP_TOTAL.into()),
        (InstantQuery::SwapFree, SWAP_FREE.into()),
        (InstantQuery::Load1, LOAD1.into()),
        (InstantQuery::Load5, LOAD5.into()),
        (InstantQuery::Load15, LOAD15.into()),
        (InstantQuery::BootTime, BOOT_TIME.into()),
        (InstantQuery::FsSize, FS_SIZE.into()),
        (InstantQuery::FsAvail, FS_AVAIL.into()),
        (InstantQuery::NetRx, net_rx(cfg)),
        (InstantQuery::NetTx, net_tx(cfg)),
        (InstantQuery::AllTemps, ALL_TEMPS.into()),
        (InstantQuery::CpuIoWait, CPU_IO_WAIT.into()),
        (InstantQuery::GpuTemp, gpu_temp()),
        (InstantQuery::GpuUtil, gpu_util()),
        (InstantQuery::GpuFbUsed, gpu_fb_used()),
        (InstantQuery::GpuFbFree, gpu_fb_free()),
        (InstantQuery::GpuPower, gpu_power()),
        (InstantQuery::GpuSmClock, gpu_sm_clock()),
        (InstantQuery::GpuMemClock, gpu_mem_clock()),
        (InstantQuery::GpuMemTemp, gpu_mem_temp()),
        (InstantQuery::GpuAgeFresh, GPU_AGE_FRESH.into()),
    ]
}
/// Expensive diagnostics, only for dcgm targets whose up is currently zero.
pub fn gpu_fallback_queries(cfg: &Config) -> Vec<(InstantQuery, String)> {
    let _ = cfg;
    vec![
        (InstantQuery::GpuTemp, gpu_temp_last()),
        (InstantQuery::GpuUtil, gpu_util_last()),
        (InstantQuery::GpuFbUsed, gpu_fb_used_last()),
        (InstantQuery::GpuFbFree, gpu_fb_free_last()),
        (InstantQuery::GpuPower, gpu_power_last()),
        (InstantQuery::GpuSmClock, gpu_sm_clock_last()),
        (InstantQuery::GpuMemClock, gpu_mem_clock_last()),
        (InstantQuery::GpuMemTemp, gpu_mem_temp_last()),
        (InstantQuery::GpuAgeDeep, GPU_AGE_DEEP.into()),
    ]
}

/// Strip quotes, backslashes and newlines from an instance label, as in Dart.
pub fn safe(s: &str) -> String {
    s.chars()
        .filter(|c| !matches!(c, '"' | '\\' | '\n'))
        .collect()
}
pub fn cpu_for(instance: &str) -> String {
    let i = safe(instance);
    format!(
        "100 - (avg by (instance) (rate(node_cpu_seconds_total{{instance=\"{i}\",mode=\"idle\"}}[2m])) * 100)"
    )
}
/// Bytes tell how much memory the workload took; percent hides the box's size.
pub fn mem_used_bytes_for(instance: &str) -> String {
    let i = safe(instance);
    format!(
        "node_memory_MemTotal_bytes{{instance=\"{i}\"}} - node_memory_MemAvailable_bytes{{instance=\"{i}\"}}"
    )
}
pub fn mem_pct_for(instance: &str) -> String {
    let i = safe(instance);
    format!(
        "(1 - (node_memory_MemAvailable_bytes{{instance=\"{i}\"}} / node_memory_MemTotal_bytes{{instance=\"{i}\"}})) * 100"
    )
}
pub fn hwmon_temp_for(instance: &str) -> String {
    let i = safe(instance);
    format!(
        "node_hwmon_temp_celsius{{instance=\"{i}\"}} * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label"
    )
}
/// Raw history keeps its own timestamps; gaps should remain gaps.
pub fn gpu_temp_for(instance: &str) -> String {
    format!("DCGM_FI_DEV_GPU_TEMP{{instance=\"{}\"}}", safe(instance))
}
pub fn gpu_util_for(instance: &str) -> String {
    format!("DCGM_FI_DEV_GPU_UTIL{{instance=\"{}\"}}", safe(instance))
}
