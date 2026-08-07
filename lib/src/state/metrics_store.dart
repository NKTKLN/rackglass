import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../model/snapshot.dart';
import '../prom/prom_client.dart';
import '../prom/queries.dart';

/// Fixed-length ring of recent values, used for the inline sparklines.
class _Ring {
  final List<double> _values = [];

  void add(double? v) {
    if (v == null || v.isNaN) return;
    _values.add(v);
    if (_values.length > AppConfig.historyDepth) _values.removeAt(0);
  }

  List<double> get values => List.unmodifiable(_values);
}

/// Polls Prometheus on a timer and exposes the latest [Snapshot] plus a short
/// client-side history for sparklines. Also serves the range queries the GRAPHS
/// screen needs.
class MetricsStore extends ChangeNotifier {
  MetricsStore({PromClient? client}) : _client = client ?? PromClient();

  final PromClient _client;
  Timer? _timer;
  bool _inFlight = false;
  bool _disposed = false;

  Snapshot? _snapshot;
  String? _error;
  int _consecutiveErrors = 0;
  DateTime? _lastSuccess;

  final Map<String, _Ring> _cpuHistory = {};
  final Map<String, _Ring> _memHistory = {};
  final _Ring _hostTempHistory = _Ring();
  final _Ring _gpuTempHistory = _Ring();
  final _Ring _gpuUtilHistory = _Ring();

  Snapshot? get snapshot => _snapshot;
  String? get error => _error;
  bool get healthy => _error == null && _snapshot != null;
  int get consecutiveErrors => _consecutiveErrors;
  DateTime? get lastSuccess => _lastSuccess;
  String get endpoint => _client.baseUrl;

  List<double> cpuHistory(String instance) =>
      _cpuHistory[instance]?.values ?? const [];
  List<double> memHistory(String instance) =>
      _memHistory[instance]?.values ?? const [];
  List<double> get hostTempHistory => _hostTempHistory.values;
  List<double> get gpuTempHistory => _gpuTempHistory.values;
  List<double> get gpuUtilHistory => _gpuUtilHistory.values;

  void start() {
    if (_timer != null) return;
    refresh();
    _timer = Timer.periodic(AppConfig.pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _client.close();
    super.dispose();
  }

  /// Runs one full poll. Overlapping calls are dropped rather than queued so a
  /// slow or unreachable server cannot pile up requests.
  Future<void> refresh() async {
    if (_inFlight || _disposed) return;
    _inFlight = true;
    final started = DateTime.now();
    try {
      final snap = await _fetch(started);
      if (_disposed) return;
      _snapshot = snap;
      _error = null;
      _consecutiveErrors = 0;
      _lastSuccess = DateTime.now();
      _recordHistory(snap);
    } on PromException catch (e) {
      if (_disposed) return;
      _error = e.message;
      _consecutiveErrors++;
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _consecutiveErrors++;
    } finally {
      _inFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<Snapshot> _fetch(DateTime started) async {
    // One round trip per expression, all in flight at once. Prometheus handles
    // these in single-digit milliseconds each on this dataset.
    final results = await Future.wait([
      _client.instant(Q.up), // 0
      _client.instant(Q.cpuBusy), // 1
      _client.instant(Q.cores), // 2
      _client.instant(Q.memTotal), // 3
      _client.instant(Q.memAvailable), // 4
      _client.instant(Q.swapTotal), // 5
      _client.instant(Q.swapFree), // 6
      _client.instant(Q.load1), // 7
      _client.instant(Q.load5), // 8
      _client.instant(Q.load15), // 9
      _client.instant(Q.bootTime), // 10
      _client.instant(Q.fsSize), // 11
      _client.instant(Q.fsAvail), // 12
      _client.instant(Q.netRx), // 13
      _client.instant(Q.netTx), // 14
      _client.instant(Q.cpuTemp), // 15
      _client.instant(Q.cpuIoWait), // 16
      _client.instant(Q.gpuTemp), // 17
      _client.instant(Q.gpuUtil), // 18
      _client.instant(Q.gpuFbUsed), // 19
      _client.instant(Q.gpuFbFree), // 20
      _client.instant(Q.gpuPower), // 21
      _client.instant(Q.gpuSmClock), // 22
      _client.instant(Q.gpuMemClock), // 23
      _client.instant(Q.gpuMemTemp), // 24
      _client.instant(Q.gpuMemCopyUtil), // 25
      _client.instant(Q.gpuAgeDeep), // 26
      _client.instant(Q.gpuAgeFresh), // 27
    ]);

    final up = results[0];
    final cpu = _byInstance(results[1]);
    final cores = _byInstance(results[2]);
    final memTotal = _byInstance(results[3]);
    final memAvail = _byInstance(results[4]);
    final swapTotal = _byInstance(results[5]);
    final swapFree = _byInstance(results[6]);
    final load1 = _byInstance(results[7]);
    final load5 = _byInstance(results[8]);
    final load15 = _byInstance(results[9]);
    final boot = _byInstance(results[10]);
    final fsSize = _byInstance(results[11]);
    final fsAvail = _byInstance(results[12]);
    final rx = _byInstance(results[13]);
    final tx = _byInstance(results[14]);
    final ioWait = _byInstance(results[16]);

    final nodes = <NodeStat>[];
    for (final s in up) {
      if (s.labels['job'] != 'node') continue;
      final inst = s.instance;
      if (inst == null) continue;
      nodes.add(
        NodeStat(
          instance: inst,
          role: s.labels['role'] ?? '-',
          up: s.value != 0,
          cpuPct: cpu[inst],
          ioWaitPct: ioWait[inst],
          cores: cores[inst],
          memTotal: memTotal[inst],
          memAvailable: memAvail[inst],
          swapTotal: swapTotal[inst],
          swapFree: swapFree[inst],
          load1: load1[inst],
          load5: load5[inst],
          load15: load15[inst],
          bootTime: boot[inst],
          fsSize: fsSize[inst],
          fsAvail: fsAvail[inst],
          netRx: rx[inst],
          netTx: tx[inst],
        ),
      );
    }
    // Hypervisor first, then guests alphabetically — stable row order between
    // polls matters more than any clever ranking.
    nodes.sort((a, b) {
      if (a.isHypervisor != b.isHypervisor) return a.isHypervisor ? -1 : 1;
      return a.instance.compareTo(b.instance);
    });

    final temps = [
      for (final s in results[15])
        TempReading(
          instance: s.instance ?? '?',
          chip: s.labels['chip'] ?? '?',
          sensor: s.labels['sensor'] ?? '?',
          label: s.labels['label'] ?? s.labels['sensor'] ?? '?',
          celsius: s.value,
        ),
    ];

    final dcgmUp = <String, bool>{
      for (final s in up)
        if (s.labels['job'] == 'dcgm' && s.instance != null)
          s.instance!: s.value != 0,
    };

    final gpus = _buildGpus(
      temp: results[17],
      util: results[18],
      fbUsed: results[19],
      fbFree: results[20],
      power: results[21],
      smClock: results[22],
      memClock: results[23],
      memTemp: results[24],
      memCopyUtil: results[25],
      ageDeep: results[26],
      ageFresh: results[27],
      exporterUp: dcgmUp,
    );

    return Snapshot(
      at: DateTime.now(),
      nodes: nodes,
      gpus: gpus,
      temps: temps,
      fetchMillis: DateTime.now().difference(started).inMilliseconds,
    );
  }

  List<GpuStat> _buildGpus({
    required List<PromSample> temp,
    required List<PromSample> util,
    required List<PromSample> fbUsed,
    required List<PromSample> fbFree,
    required List<PromSample> power,
    required List<PromSample> smClock,
    required List<PromSample> memClock,
    required List<PromSample> memTemp,
    required List<PromSample> memCopyUtil,
    required List<PromSample> ageDeep,
    required List<PromSample> ageFresh,
    required Map<String, bool> exporterUp,
  }) {
    // A GPU is identified by (instance, gpu index); every metric carries both.
    String keyOf(PromSample s) => '${s.instance ?? "?"}/${s.labels["gpu"] ?? "0"}';
    Map<String, double> keyed(List<PromSample> xs) => {
      for (final s in xs) keyOf(s): s.value,
    };

    final tempBy = keyed(temp);
    final utilBy = keyed(util);
    final fbUsedBy = keyed(fbUsed);
    final fbFreeBy = keyed(fbFree);
    final powerBy = keyed(power);
    final smBy = keyed(smClock);
    final memClockBy = keyed(memClock);
    final memTempBy = keyed(memTemp);
    final copyBy = keyed(memCopyUtil);
    final deepBy = keyed(ageDeep);
    // A live series answers exactly; only a long-dead one needs the subquery,
    // where being a few minutes out makes no difference to anything.
    final freshBy = keyed(ageFresh);

    final out = <GpuStat>[];
    for (final s in temp) {
      final k = keyOf(s);
      final inst = s.instance ?? '?';
      out.add(
        GpuStat(
          gpu: s.labels['gpu'] ?? '0',
          instance: inst,
          model: s.labels['modelName'] ?? 'GPU',
          exporterUp: exporterUp[inst] ?? false,
          ageSeconds: freshBy[k] ?? deepBy[k],
          temp: tempBy[k],
          memTemp: memTempBy[k],
          util: utilBy[k],
          memCopyUtil: copyBy[k],
          fbUsedMiB: fbUsedBy[k],
          fbFreeMiB: fbFreeBy[k],
          powerWatts: powerBy[k],
          smClockMhz: smBy[k],
          memClockMhz: memClockBy[k],
        ),
      );
    }
    out.sort((a, b) => a.gpu.compareTo(b.gpu));
    return out;
  }

  void _recordHistory(Snapshot snap) {
    for (final n in snap.nodes) {
      if (!n.up) continue;
      (_cpuHistory[n.instance] ??= _Ring()).add(n.cpuPct);
      (_memHistory[n.instance] ??= _Ring()).add(n.memPct);
    }
    _hostTempHistory.add(snap.cpuPackageTemp?.celsius);
    final gpu = snap.gpus.isEmpty ? null : snap.gpus.first;
    // Only record live GPU readings; replaying a stale value would draw a flat
    // line that looks like a healthy idle GPU.
    if (gpu != null && !gpu.stale) {
      _gpuTempHistory.add(gpu.temp);
      _gpuUtilHistory.add(gpu.util);
    }
  }

  /// Range query passthrough for the GRAPHS screen.
  Future<List<PromSeries>> loadRange(String query, Duration window) {
    final end = DateTime.now();
    return _client.range(
      query,
      start: end.subtract(window),
      end: end,
      step: stepFor(window),
    );
  }

  /// Aim for roughly 240 points across the window, never finer than the 15s
  /// scrape interval.
  static Duration stepFor(Duration window) {
    final s = (window.inSeconds / 240).round();
    return Duration(seconds: s < 15 ? 15 : s);
  }

  static Map<String, double> _byInstance(List<PromSample> samples) => {
    for (final s in samples)
      if (s.instance != null) s.instance!: s.value,
  };
}
