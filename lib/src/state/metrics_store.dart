import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../model/snapshot.dart';
import '../prom/prom_client.dart';
import '../prom/queries.dart';

/// Fixed-length ring of recent values, used for the inline sparklines.
///
/// Null is a real sample: it means the target/value was unavailable for that
/// poll. Keeping the gap prevents two readings separated by an outage from
/// being drawn next to each other as if monitoring had been continuous.
class _Ring {
  final List<double?> _values = [];

  void add(double? v) {
    _values.add(v == null || v.isNaN ? null : v);
    if (_values.length > AppConfig.historyDepth) _values.removeAt(0);
  }

  List<double?> get values => List.unmodifiable(_values);
}

/// Polls Prometheus on a timer and exposes the latest [Snapshot] plus a short
/// client-side history for sparklines. Also serves the range queries used by
/// GRAPHS/NODES.
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
  String? _primaryGpuKey;

  Map<InstantQuery, List<PromSample>> _gpuFallbackCache = const {};
  DateTime? _gpuFallbackAt;
  Set<String> _gpuFallbackDown = const {};
  bool _gpuFallbackInFlight = false;

  Snapshot? get snapshot => _snapshot;
  String? get error => _error;
  bool get healthy => _error == null && _snapshot != null;
  int get consecutiveErrors => _consecutiveErrors;
  DateTime? get lastSuccess => _lastSuccess;
  String get endpoint => _client.baseUrl;

  Duration? get snapshotAge =>
      _lastSuccess == null ? null : DateTime.now().difference(_lastSuccess!);

  bool get stale {
    final age = snapshotAge;
    return _snapshot != null &&
        age != null &&
        age > AppConfig.snapshotStaleAfter;
  }

  List<double?> cpuHistory(String instance) =>
      _cpuHistory[instance]?.values ?? const [];
  List<double?> memHistory(String instance) =>
      _memHistory[instance]?.values ?? const [];
  List<double?> get hostTempHistory => _hostTempHistory.values;
  List<double?> get gpuTempHistory => _gpuTempHistory.values;
  List<double?> get gpuUtilHistory => _gpuUtilHistory.values;

  void start() {
    if (_timer != null) return;
    refresh();
    _timer = Timer.periodic(AppConfig.pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    if (_disposed) return;
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
      _recordFailedPoll();
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
      _consecutiveErrors++;
      _recordFailedPoll();
    } finally {
      _inFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<Map<InstantQuery, List<PromSample>>> _instantBatch() async {
    final pairs = await Future.wait([
      for (final entry in Q.instantPollQueries.entries)
        _client.instant(entry.value).then((samples) => (entry.key, samples)),
    ]);
    return {for (final pair in pairs) pair.$1: pair.$2};
  }

  /// Historical GPU values for exporters that are currently down.
  ///
  /// The seven-day scans are awaited exactly once, on the first poll that sees
  /// a given exporter down — there is nothing to show until they land, so
  /// waiting costs nothing. From then on the cache is refreshed in the
  /// background and a poll returns whatever it already holds: node metrics are
  /// already in hand and must not sit behind a TSDB scan. A refresh that lands
  /// between polls is picked up by the next one.
  Future<Map<InstantQuery, List<PromSample>>> _gpuFallbackFor(
    Set<String> downInstances,
  ) async {
    if (downInstances.isEmpty) {
      _gpuFallbackDown = const {};
      _gpuFallbackCache = const {};
      _gpuFallbackAt = null;
      return const {};
    }

    final sameTargets = setEquals(_gpuFallbackDown, downInstances);
    final cached = sameTargets
        ? _gpuFallbackCache
        : const <InstantQuery, List<PromSample>>{};
    final expired =
        _gpuFallbackAt == null ||
        DateTime.now().difference(_gpuFallbackAt!) >=
            AppConfig.gpuFallbackRefresh;
    if (!expired && sameTargets) return cached;

    if (cached.isEmpty) return _refreshGpuFallback(downInstances);
    if (!_gpuFallbackInFlight) unawaited(_refreshGpuFallback(downInstances));
    return cached;
  }

  Future<Map<InstantQuery, List<PromSample>>> _refreshGpuFallback(
    Set<String> downInstances,
  ) async {
    if (_gpuFallbackInFlight) return _gpuFallbackCache;
    _gpuFallbackInFlight = true;
    try {
      final pairs = await Future.wait([
        for (final entry in Q.gpuFallbackQueries.entries)
          _client.instant(entry.value).then((samples) => (entry.key, samples)),
      ]);
      final fetched = {for (final pair in pairs) pair.$1: pair.$2};
      if (_disposed) return fetched;
      _gpuFallbackCache = fetched;
      _gpuFallbackAt = DateTime.now();
      _gpuFallbackDown = Set.unmodifiable(downInstances);
      return fetched;
    } catch (_) {
      // Historical GPU data is optional diagnostics. A seven-day fallback query
      // failing must not take otherwise-current node metrics offline. Reuse a
      // cache only when it belongs to the same down-target set.
      return setEquals(_gpuFallbackDown, downInstances)
          ? _gpuFallbackCache
          : const {};
    } finally {
      _gpuFallbackInFlight = false;
    }
  }

  Future<Snapshot> _fetch(DateTime started) async {
    final results = await _instantBatch();

    List<PromSample> r(InstantQuery query) {
      final value = results[query];
      if (value == null) {
        throw StateError('instant query missing from batch: ${query.name}');
      }
      return value;
    }

    final up = r(InstantQuery.up);
    final cpu = _byInstance(r(InstantQuery.cpuBusy));
    final cores = _byInstance(r(InstantQuery.cores));
    final memTotal = _byInstance(r(InstantQuery.memTotal));
    final memAvail = _byInstance(r(InstantQuery.memAvailable));
    final swapTotal = _byInstance(r(InstantQuery.swapTotal));
    final swapFree = _byInstance(r(InstantQuery.swapFree));
    final load1 = _byInstance(r(InstantQuery.load1));
    final load5 = _byInstance(r(InstantQuery.load5));
    final load15 = _byInstance(r(InstantQuery.load15));
    final boot = _byInstance(r(InstantQuery.bootTime));
    final fsSize = _byInstance(r(InstantQuery.fsSize));
    final fsAvail = _byInstance(r(InstantQuery.fsAvail));
    final rx = _byInstance(r(InstantQuery.netRx));
    final tx = _byInstance(r(InstantQuery.netTx));
    final ioWait = _byInstance(r(InstantQuery.cpuIoWait));

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
    nodes.sort((a, b) {
      if (a.isHypervisor != b.isHypervisor) return a.isHypervisor ? -1 : 1;
      return a.instance.compareTo(b.instance);
    });

    // Q.allTemps is a PromQL left join: labelled channels carry `label`, and
    // unlabelled hwmon channels still arrive with their raw sensor id.
    final temps = <TempReading>[
      for (final s in r(InstantQuery.allTemps))
        TempReading(
          instance: s.instance ?? '?',
          chip: s.labels['chip'] ?? '?',
          sensor: s.labels['sensor'] ?? '?',
          label: s.labels['label'] ?? s.labels['sensor'] ?? '?',
          celsius: s.value,
          named: s.labels['label'] != null,
        ),
    ]..sort((a, b) {
      final instance = a.instance.compareTo(b.instance);
      if (instance != 0) return instance;
      final chip = a.chip.compareTo(b.chip);
      if (chip != 0) return chip;
      return a.sensor.compareTo(b.sensor);
    });

    final dcgmUp = <String, bool>{
      for (final s in up)
        if (s.labels['job'] == 'dcgm' && s.instance != null)
          s.instance!: s.value != 0,
    };
    final downDcgm = {
      for (final entry in dcgmUp.entries)
        if (!entry.value) entry.key,
    };
    final fallback = await _gpuFallbackFor(downDcgm);

    bool fromDownExporter(PromSample sample) =>
        sample.instance != null && dcgmUp[sample.instance] == false;

    List<PromSample> gpuMetric(InstantQuery metric) => [
      for (final sample in r(metric))
        if (!fromDownExporter(sample)) sample,
      for (final sample in fallback[metric] ?? const <PromSample>[])
        if (fromDownExporter(sample)) sample,
    ];

    final gpus = _buildGpus(
      temp: gpuMetric(InstantQuery.gpuTemp),
      util: gpuMetric(InstantQuery.gpuUtil),
      fbUsed: gpuMetric(InstantQuery.gpuFbUsed),
      fbFree: gpuMetric(InstantQuery.gpuFbFree),
      power: gpuMetric(InstantQuery.gpuPower),
      smClock: gpuMetric(InstantQuery.gpuSmClock),
      memClock: gpuMetric(InstantQuery.gpuMemClock),
      memTemp: gpuMetric(InstantQuery.gpuMemTemp),
      ageDeep: [
        for (final sample in
            fallback[InstantQuery.gpuAgeDeep] ?? const <PromSample>[])
          if (fromDownExporter(sample)) sample,
      ],
      ageFresh: r(InstantQuery.gpuAgeFresh),
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
    required List<PromSample> ageDeep,
    required List<PromSample> ageFresh,
    required Map<String, bool> exporterUp,
  }) {
    String idOf(PromSample s) =>
        s.labels['UUID'] ?? s.labels['gpu'] ?? s.labels['device'] ?? '0';
    String keyOf(PromSample s) => '${s.instance ?? "?"}/${idOf(s)}';
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
    final deepBy = keyed(ageDeep);
    final freshBy = keyed(ageFresh);

    // Seed from every metric, not just temperature. If one live DCGM field
    // disappears the GPU still exists and that individual reading becomes `--`.
    final seeds = <String, PromSample>{};
    for (final xs in [
      temp,
      util,
      fbUsed,
      fbFree,
      power,
      smClock,
      memClock,
      memTemp,
      ageFresh,
      ageDeep,
    ]) {
      for (final s in xs) {
        seeds.putIfAbsent(keyOf(s), () => s);
      }
    }
    // Prefer temperature metadata when available because it consistently
    // carries modelName/UUID in dcgm-exporter.
    for (final s in temp) {
      seeds[keyOf(s)] = s;
    }

    final out = <GpuStat>[];
    for (final entry in seeds.entries) {
      final k = entry.key;
      final s = entry.value;
      final inst = s.instance ?? '?';
      out.add(
        GpuStat(
          gpu: s.labels['gpu'] ?? '0',
          instance: inst,
          model: s.labels['modelName'] ?? 'GPU',
          uuid: s.labels['UUID'],
          exporterUp: exporterUp[inst] ?? false,
          ageSeconds: freshBy[k] ?? deepBy[k],
          temp: tempBy[k],
          memTemp: memTempBy[k],
          util: utilBy[k],
          fbUsedMiB: fbUsedBy[k],
          fbFreeMiB: fbFreeBy[k],
          powerWatts: powerBy[k],
          smClockMhz: smBy[k],
          memClockMhz: memClockBy[k],
        ),
      );
    }
    out.sort((a, b) {
      final inst = a.instance.compareTo(b.instance);
      if (inst != 0) return inst;
      final ai = int.tryParse(a.gpu);
      final bi = int.tryParse(b.gpu);
      if (ai != null && bi != null) return ai.compareTo(bi);
      return a.gpu.compareTo(b.gpu);
    });
    return out;
  }

  void _recordHistory(Snapshot snap) {
    final nodesBy = {for (final n in snap.nodes) n.instance: n};
    final knownNodes = <String>{
      ..._cpuHistory.keys,
      ..._memHistory.keys,
      ...nodesBy.keys,
    };
    for (final instance in knownNodes) {
      final n = nodesBy[instance];
      (_cpuHistory[instance] ??= _Ring()).add(n?.up == true ? n?.cpuPct : null);
      (_memHistory[instance] ??= _Ring()).add(n?.up == true ? n?.memPct : null);
    }

    _hostTempHistory.add(snap.cpuPackageTemp?.celsius);

    // Latched so the strip keeps following one card while several are present,
    // but re-latched the moment that card is gone: a replaced GPU or a changed
    // UUID must not leave the sparkline blank for the rest of the session.
    if (snap.gpus.isEmpty) {
      _primaryGpuKey = null;
    } else if (!snap.gpus.any((g) => g.key == _primaryGpuKey)) {
      _primaryGpuKey = snap.gpus.first.key;
    }
    GpuStat? gpu;
    for (final candidate in snap.gpus) {
      if (candidate.key == _primaryGpuKey) {
        gpu = candidate;
        break;
      }
    }
    _gpuTempHistory.add(gpu != null && !gpu.stale ? gpu.temp : null);
    _gpuUtilHistory.add(gpu != null && !gpu.stale ? gpu.util : null);
  }

  void _recordFailedPoll() {
    for (final ring in _cpuHistory.values) {
      ring.add(null);
    }
    for (final ring in _memHistory.values) {
      ring.add(null);
    }
    _hostTempHistory.add(null);
    _gpuTempHistory.add(null);
    _gpuUtilHistory.add(null);
  }

  /// Range query passthrough. Supplying [end] lets a screen issue several
  /// aligned queries against one exact time boundary.
  Future<List<PromSeries>> loadRange(
    String query,
    Duration window, {
    DateTime? end,
  }) {
    final queryEnd = end ?? DateTime.now();
    return _client.range(
      query,
      start: queryEnd.subtract(window),
      end: queryEnd,
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
