import '../config.dart';

/// A named temperature reading off one hwmon chip.
class TempReading {
  const TempReading({
    required this.instance,
    required this.chip,
    required this.sensor,
    required this.label,
    required this.celsius,
    this.named = true,
  });

  final String instance;
  final String chip;
  final String sensor;

  /// `Tctl`, `Tccd1`, … or the raw sensor id when the chip exposes no label.
  final String label;
  final double celsius;

  /// Whether node_exporter gave this channel a name of its own. An unnamed
  /// `temp0` is a raw hwmon index that means nothing without its datasheet:
  /// worth listing in full on NODES, not worth a line on DASH.
  final bool named;

  /// Short chip name for display: the hwmon path tail rather than the full id.
  String get chipShort {
    final parts = chip.split('_');
    return parts.length > 2 ? parts.take(2).join('_') : chip;
  }
}

/// Everything known about one node_exporter target.
class NodeStat {
  const NodeStat({
    required this.instance,
    required this.role,
    required this.up,
    this.cpuPct,
    this.ioWaitPct,
    this.cores,
    this.memTotal,
    this.memAvailable,
    this.swapTotal,
    this.swapFree,
    this.load1,
    this.load5,
    this.load15,
    this.bootTime,
    this.fsSize,
    this.fsAvail,
    this.netRx,
    this.netTx,
  });

  final String instance;
  final String role;
  final bool up;

  final double? cpuPct;
  final double? ioWaitPct;
  final double? cores;
  final double? memTotal;
  final double? memAvailable;
  final double? swapTotal;
  final double? swapFree;
  final double? load1;
  final double? load5;
  final double? load15;
  final double? bootTime;
  final double? fsSize;
  final double? fsAvail;
  final double? netRx;
  final double? netTx;

  bool get isHypervisor => instance == AppConfig.hypervisor;

  double? get memUsed => (memTotal != null && memAvailable != null)
      ? memTotal! - memAvailable!
      : null;

  double? get memPct => (memTotal != null && memTotal! > 0 && memUsed != null)
      ? memUsed! / memTotal! * 100
      : null;

  double? get swapUsed =>
      (swapTotal != null && swapFree != null) ? swapTotal! - swapFree! : null;

  double? get swapPct => (swapTotal != null && swapTotal! > 0 && swapUsed != null)
      ? swapUsed! / swapTotal! * 100
      : null;

  double? get fsUsed =>
      (fsSize != null && fsAvail != null) ? fsSize! - fsAvail! : null;

  double? get fsPct => (fsSize != null && fsSize! > 0 && fsUsed != null)
      ? fsUsed! / fsSize! * 100
      : null;

  /// Load average normalised by core count — comparable across a 1-core VM and
  /// the 12-core host.
  double? get loadPerCore =>
      (load1 != null && cores != null && cores! > 0) ? load1! / cores! : null;

  Duration? get uptime => bootTime == null
      ? null
      : DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch((bootTime! * 1000).round()),
        );
}

/// Everything known about one GPU, plus how stale the readings are.
class GpuStat {
  const GpuStat({
    required this.gpu,
    required this.instance,
    required this.model,
    this.uuid,
    required this.exporterUp,
    this.ageSeconds,
    this.temp,
    this.memTemp,
    this.util,
    this.fbUsedMiB,
    this.fbFreeMiB,
    this.powerWatts,
    this.smClockMhz,
    this.memClockMhz,
  });

  final String gpu;
  final String instance;
  final String model;
  final String? uuid;

  String get key => '$instance/${uuid ?? gpu}';

  /// `up` for the dcgm scrape target right now.
  final bool exporterUp;

  /// Age of the newest GPU sample in the TSDB, in seconds.
  final double? ageSeconds;

  final double? temp;
  final double? memTemp;
  final double? util;
  final double? fbUsedMiB;
  final double? fbFreeMiB;
  final double? powerWatts;
  final double? smClockMhz;
  final double? memClockMhz;

  Duration? get age =>
      ageSeconds == null ? null : Duration(seconds: ageSeconds!.round());

  /// True when the numbers on screen are historical rather than live.
  bool get stale =>
      !exporterUp ||
      (ageSeconds != null &&
          ageSeconds! > AppConfig.gpuStaleAfter.inSeconds);

  double? get fbTotalBytes => (fbUsedMiB != null && fbFreeMiB != null)
      ? (fbUsedMiB! + fbFreeMiB!) * 1024 * 1024
      : null;

  double? get fbUsedBytes =>
      fbUsedMiB == null ? null : fbUsedMiB! * 1024 * 1024;

  double? get fbPct {
    final total = fbTotalBytes;
    if (total == null || total <= 0) return null;
    return fbUsedBytes! / total * 100;
  }

  /// Trims `Tesla V100-SXM2-16GB` down for a panel title.
  String get modelShort =>
      model.replaceFirst(RegExp(r'^(NVIDIA|Tesla)\s+'), '');
}

/// How hard a target is being pushed, worst-of across everything measured for
/// it. Reachability is a separate axis: a target that is down reports no load
/// at all, which is not the same as being idle.
enum NodeHealth { unknown, ok, warn, critical }

/// One complete poll of the cluster.
class Snapshot {
  const Snapshot({
    required this.at,
    required this.nodes,
    required this.gpus,
    required this.temps,
    required this.fetchMillis,
  });

  final DateTime at;
  final List<NodeStat> nodes;
  final List<GpuStat> gpus;
  final List<TempReading> temps;

  /// Wall time the poll took, shown in the status bar.
  final int fetchMillis;

  NodeStat? get host {
    for (final n in nodes) {
      if (n.isHypervisor) return n;
    }
    return null;
  }

  List<GpuStat> gpusFor(String instance) => [
    for (final g in gpus)
      if (g.instance == instance) g,
  ];

  List<TempReading> tempsFor(String instance) => [
    for (final t in temps)
      if (t.instance == instance) t,
  ];

  /// Worst reading across CPU, memory, root fs and any live GPU on the target.
  /// Stale GPU numbers are left out: an exporter that has been down for a day
  /// must not keep a target amber on yesterday's utilisation.
  NodeHealth healthOf(NodeStat n) {
    if (!n.up) return NodeHealth.unknown;
    final readings = <double>[
      if (n.cpuPct != null) n.cpuPct!,
      if (n.memPct != null) n.memPct!,
      if (n.fsPct != null) n.fsPct!,
      for (final g in gpusFor(n.instance))
        if (!g.stale) ...[
          if (g.util != null) g.util!,
          if (g.fbPct != null) g.fbPct!,
        ],
    ];
    if (readings.isEmpty) return NodeHealth.unknown;
    final worst = readings.reduce((a, b) => a > b ? a : b);
    if (worst >= AppConfig.loadCritical) return NodeHealth.critical;
    if (worst >= AppConfig.loadWarn) return NodeHealth.warn;
    return NodeHealth.ok;
  }

  List<NodeStat> get vms => [for (final n in nodes) if (!n.isHypervisor) n];

  int get targetsDown => nodes.where((n) => !n.up).length;

  /// The named CPU package temperature, preferring canonical AMD/Intel package
  /// labels. If node_exporter does not identify a package sensor, return null
  /// rather than guessing that the hottest unrelated hwmon device is the CPU.
  TempReading? get cpuPackageTemp {
    final hostTemps = temps
        .where((t) => t.instance == AppConfig.hypervisor)
        .toList();
    if (hostTemps.isEmpty) return null;
    for (final want in ['Tctl', 'Package id 0', 'Tdie']) {
      for (final t in hostTemps) {
        if (t.label == want) return t;
      }
    }
    return null;
  }

  /// Labelled host temperatures other than the package one.
  List<TempReading> get otherHostTemps {
    final pkg = cpuPackageTemp;
    return [
      for (final t in temps)
        if (t.instance == AppConfig.hypervisor && t != pkg && t.named) t,
    ];
  }

  /// Sum of guest OS-reported physical memory. This is not a Proxmox
  /// allocation/commitment metric and is deliberately named as such.
  double get vmMemReportedTotal =>
      vms.fold(0.0, (sum, n) => sum + (n.memTotal ?? 0));

  double get vmMemUsed => vms.fold(0.0, (sum, n) => sum + (n.memUsed ?? 0));
}
