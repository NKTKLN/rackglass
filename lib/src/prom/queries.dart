import '../config.dart';

enum InstantQuery {
  up,
  cpuBusy,
  cores,
  memTotal,
  memAvailable,
  swapTotal,
  swapFree,
  load1,
  load5,
  load15,
  bootTime,
  fsSize,
  fsAvail,
  netRx,
  netTx,
  allTemps,
  cpuIoWait,
  gpuTemp,
  gpuUtil,
  gpuFbUsed,
  gpuFbFree,
  gpuPower,
  gpuSmClock,
  gpuMemClock,
  gpuMemTemp,
  gpuAgeDeep,
  gpuAgeFresh,
}

/// Every PromQL expression the app issues, in one place.
///
/// The target Prometheus scrapes `job="node"` (node_exporter on the Proxmox
/// host plus each guest) and `job="dcgm"` (dcgm-exporter next to the GPU).
abstract final class Q {
  // ---- per-instance node metrics -------------------------------------------

  static const cpuBusy =
      '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)';
  static const cpuIoWait =
      'avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[2m])) * 100';
  static const cores =
      'count by (instance) (node_cpu_seconds_total{mode="idle"})';

  static const memTotal = 'node_memory_MemTotal_bytes';
  static const memAvailable = 'node_memory_MemAvailable_bytes';
  static const swapTotal = 'node_memory_SwapTotal_bytes';
  static const swapFree = 'node_memory_SwapFree_bytes';

  static const load1 = 'node_load1';
  static const load5 = 'node_load5';
  static const load15 = 'node_load15';
  static const bootTime = 'node_boot_time_seconds';

  static const fsSize = 'node_filesystem_size_bytes{mountpoint="/"}';
  static const fsAvail = 'node_filesystem_avail_bytes{mountpoint="/"}';

  static final netRx =
      'sum by (instance) (rate(node_network_receive_bytes_total{device!~"${AppConfig.netDeviceExclude}"}[2m]))';
  static final netTx =
      'sum by (instance) (rate(node_network_transmit_bytes_total{device!~"${AppConfig.netDeviceExclude}"}[2m]))';

  static const up = 'up';

  /// Labelled hwmon temperatures for readable names such as `Tctl`/`Tccd1`.
  static const cpuTemp =
      'node_hwmon_temp_celsius * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label';

  /// All hwmon temperatures, with readable labels where node_exporter has one
  /// and the raw sensor id retained otherwise. `or on(...)` acts as a left join:
  /// the labelled series wins, while unmatched raw channels remain visible.
  static const allTemps =
      '($cpuTemp) or on(instance,chip,sensor) node_hwmon_temp_celsius';

  // ---- GPU (dcgm-exporter) -------------------------------------------------
  //
  // Live queries explicitly reject samples older than gpuStaleAfter. Prometheus
  // instant selectors otherwise keep returning the last sample from their
  // lookback window, which can make a field look live after it disappeared.
  // Seven-day fallback queries are separate: MetricsStore only executes them
  // for down exporters and caches the result for gpuFallbackRefresh.

  static const _gpuWindow = '7d';

  static String _freshGpu(String metric) {
    final fresh = AppConfig.gpuStaleAfter.inSeconds;
    return '$metric and on(instance,gpu,UUID) '
        '(time() - timestamp($metric) < $fresh)';
  }

  static String _lastGpu(String metric) =>
      'last_over_time($metric[$_gpuWindow])';

  static final gpuTemp = _freshGpu('DCGM_FI_DEV_GPU_TEMP');
  static final gpuMemTemp = _freshGpu('DCGM_FI_DEV_MEMORY_TEMP');
  static final gpuUtil = _freshGpu('DCGM_FI_DEV_GPU_UTIL');
  static final gpuFbUsed = _freshGpu('DCGM_FI_DEV_FB_USED');
  static final gpuFbFree = _freshGpu('DCGM_FI_DEV_FB_FREE');
  static final gpuPower = _freshGpu('DCGM_FI_DEV_POWER_USAGE');
  static final gpuSmClock = _freshGpu('DCGM_FI_DEV_SM_CLOCK');
  static final gpuMemClock = _freshGpu('DCGM_FI_DEV_MEM_CLOCK');

  static final gpuTempLast = _lastGpu('DCGM_FI_DEV_GPU_TEMP');
  static final gpuMemTempLast = _lastGpu('DCGM_FI_DEV_MEMORY_TEMP');
  static final gpuUtilLast = _lastGpu('DCGM_FI_DEV_GPU_UTIL');
  static final gpuFbUsedLast = _lastGpu('DCGM_FI_DEV_FB_USED');
  static final gpuFbFreeLast = _lastGpu('DCGM_FI_DEV_FB_FREE');
  static final gpuPowerLast = _lastGpu('DCGM_FI_DEV_POWER_USAGE');
  static final gpuSmClockLast = _lastGpu('DCGM_FI_DEV_SM_CLOCK');
  static final gpuMemClockLast = _lastGpu('DCGM_FI_DEV_MEM_CLOCK');

  /// Seconds since the GPU exporter last produced a temperature sample while
  /// that series remains within Prometheus' normal lookback window.
  static const gpuAgeFresh = 'time() - timestamp(DCGM_FI_DEV_GPU_TEMP)';

  /// Long-term age fallback for an exporter that has been down for hours/days.
  static const gpuAgeDeep =
      'time() - max_over_time(timestamp(DCGM_FI_DEV_GPU_TEMP)[$_gpuWindow:5m])';

  // ---- range queries for the GRAPHS screen ---------------------------------

  static const rangeCpu = cpuBusy;
  static const rangeMemPct =
      '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100';
  static const rangeTempCpu = cpuTemp;
  static const rangeTempGpu = 'DCGM_FI_DEV_GPU_TEMP';
  static const rangeGpuUtil = 'DCGM_FI_DEV_GPU_UTIL';
  static final rangeNetRx = netRx;

  /// Throughput measured end to end, one series per `path` (direct vs socks),
  /// rather than the interface counters — those say how busy the NIC was, not
  /// what the link is actually worth right now.
  ///
  /// The exporter runs on its own schedule, tens of minutes apart, so the raw
  /// metric is a scatter of isolated points over any window short enough to be
  /// interesting. `last_over_time` holds each result until the next run, which
  /// is what the number means anyway: the last measurement still stands.
  static const rangeSpeedtestDown =
      'last_over_time(speedtest_download_bits_per_second[1h])';

  /// Same treatment for the other direction. The exporter measures both in one
  /// run, so an upload point exists for every download point and the two share
  /// an axis honestly.
  static const rangeSpeedtestUp =
      'last_over_time(speedtest_upload_bits_per_second[1h])';

  static const rangeSpeedtestLatency =
      'last_over_time(speedtest_latency_seconds[1h])';

  /// All instant expressions used by a complete MetricsStore poll. The live
  /// smoke test consumes this same list so it cannot silently drift behind the
  /// production query batch.
  static final Map<InstantQuery, String> instantPollQueries = {
    InstantQuery.up: up,
    InstantQuery.cpuBusy: cpuBusy,
    InstantQuery.cores: cores,
    InstantQuery.memTotal: memTotal,
    InstantQuery.memAvailable: memAvailable,
    InstantQuery.swapTotal: swapTotal,
    InstantQuery.swapFree: swapFree,
    InstantQuery.load1: load1,
    InstantQuery.load5: load5,
    InstantQuery.load15: load15,
    InstantQuery.bootTime: bootTime,
    InstantQuery.fsSize: fsSize,
    InstantQuery.fsAvail: fsAvail,
    InstantQuery.netRx: netRx,
    InstantQuery.netTx: netTx,
    InstantQuery.allTemps: allTemps,
    InstantQuery.cpuIoWait: cpuIoWait,
    InstantQuery.gpuTemp: gpuTemp,
    InstantQuery.gpuUtil: gpuUtil,
    InstantQuery.gpuFbUsed: gpuFbUsed,
    InstantQuery.gpuFbFree: gpuFbFree,
    InstantQuery.gpuPower: gpuPower,
    InstantQuery.gpuSmClock: gpuSmClock,
    InstantQuery.gpuMemClock: gpuMemClock,
    InstantQuery.gpuMemTemp: gpuMemTemp,
    InstantQuery.gpuAgeFresh: gpuAgeFresh,
  };

  /// Expensive historical queries, only used for dcgm instances whose `up` is
  /// currently zero. Kept separate from [instantPollQueries] so the store can
  /// cache them and avoid seven-day scans on every poll.
  static final Map<InstantQuery, String> gpuFallbackQueries = {
    InstantQuery.gpuTemp: gpuTempLast,
    InstantQuery.gpuUtil: gpuUtilLast,
    InstantQuery.gpuFbUsed: gpuFbUsedLast,
    InstantQuery.gpuFbFree: gpuFbFreeLast,
    InstantQuery.gpuPower: gpuPowerLast,
    InstantQuery.gpuSmClock: gpuSmClockLast,
    InstantQuery.gpuMemClock: gpuMemClockLast,
    InstantQuery.gpuMemTemp: gpuMemTempLast,
    InstantQuery.gpuAgeDeep: gpuAgeDeep,
  };

  static String cpuFor(String instance) {
    final i = _safe(instance);
    return '100 - (avg by (instance) '
        '(rate(node_cpu_seconds_total{instance="$i",mode="idle"}[2m])) * 100)';
  }

  /// Memory in use, in bytes. The NODES chart plots this rather than the
  /// percentage: on a guest you want to see how many gigabytes a workload
  /// actually took, and a percentage hides the size of the box it ran on.
  static String memUsedBytesFor(String instance) {
    final i = _safe(instance);
    return 'node_memory_MemTotal_bytes{instance="$i"} - '
        'node_memory_MemAvailable_bytes{instance="$i"}';
  }

  static String memPctFor(String instance) {
    final i = _safe(instance);
    return '(1 - (node_memory_MemAvailable_bytes{instance="$i"} / '
        'node_memory_MemTotal_bytes{instance="$i"})) * 100';
  }

  /// Labelled hwmon history for one target, for the NODES temperature chart.
  static String hwmonTempFor(String instance) {
    final i = _safe(instance);
    return 'node_hwmon_temp_celsius{instance="$i"} '
        '* on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label';
  }

  /// Raw DCGM history for one target. No freshness filter and no
  /// `last_over_time`: a range query already carries its own timestamps, and a
  /// gap in the matrix is exactly what the chart should show.
  static String gpuTempFor(String instance) =>
      'DCGM_FI_DEV_GPU_TEMP{instance="${_safe(instance)}"}';

  static String gpuUtilFor(String instance) =>
      'DCGM_FI_DEV_GPU_UTIL{instance="${_safe(instance)}"}';

  static String _safe(String s) => s.replaceAll(RegExp(r'["\\\n]'), '');
}
