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
  static const cores = 'count by (instance) (node_cpu_seconds_total{mode="idle"})';

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

  static const netRx =
      'sum by (instance) (rate(node_network_receive_bytes_total{device!="lo"}[2m]))';
  static const netTx =
      'sum by (instance) (rate(node_network_transmit_bytes_total{device!="lo"}[2m]))';

  static const up = 'up';

  /// hwmon temperatures joined with their chip labels, so `Tctl`/`Tccd1` come
  /// back named instead of as opaque `temp1`/`temp3` sensor ids.
  static const cpuTemp =
      'node_hwmon_temp_celsius * on(instance,chip,sensor) group_left(label) node_hwmon_sensor_label';

  /// Every hwmon sensor, labelled or not — used by the sensor list on NODES.
  static const allTemps = 'node_hwmon_temp_celsius';

  // ---- GPU (dcgm-exporter) -------------------------------------------------
  //
  // The exporter can be down for long stretches while the VM is parked. Reading
  // through last_over_time keeps the panel populated with the last known values
  // instead of blanking, and `gpuAge` says how old they are.

  static const _gpuWindow = '7d';

  static String _last(String metric) => 'last_over_time($metric[$_gpuWindow])';

  static final gpuTemp = _last('DCGM_FI_DEV_GPU_TEMP');
  static final gpuMemTemp = _last('DCGM_FI_DEV_MEMORY_TEMP');
  static final gpuUtil = _last('DCGM_FI_DEV_GPU_UTIL');
  static final gpuMemCopyUtil = _last('DCGM_FI_DEV_MEM_COPY_UTIL');
  static final gpuFbUsed = _last('DCGM_FI_DEV_FB_USED');
  static final gpuFbFree = _last('DCGM_FI_DEV_FB_FREE');
  static final gpuPower = _last('DCGM_FI_DEV_POWER_USAGE');
  static final gpuSmClock = _last('DCGM_FI_DEV_SM_CLOCK');
  static final gpuMemClock = _last('DCGM_FI_DEV_MEM_CLOCK');

  /// Seconds since the GPU exporter last produced a sample. `timestamp()` loses
  /// the original sample time through `last_over_time`, so this goes through a
  /// subquery instead.
  static const gpuAge =
      'time() - max_over_time(timestamp(DCGM_FI_DEV_GPU_TEMP)[$_gpuWindow:5m])';

  // ---- range queries for the GRAPHS screen ---------------------------------

  static const rangeCpu = cpuBusy;
  static const rangeMemPct =
      '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100';
  static const rangeTempCpu = cpuTemp;
  static const rangeTempGpu = 'DCGM_FI_DEV_GPU_TEMP';
  static const rangeGpuUtil = 'DCGM_FI_DEV_GPU_UTIL';
  static const rangeNetRx = netRx;
  static const rangeNetTx = netTx;
  static const rangeLoad = 'node_load1';
}
