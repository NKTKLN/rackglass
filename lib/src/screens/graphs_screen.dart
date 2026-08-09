import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config.dart';
import '../prom/prom_client.dart';
import '../prom/queries.dart';
import '../state/metrics_store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/term_chart.dart';
import '../widgets/term_panel.dart';

/// Selectable history windows.
const _windows = <(String, Duration)>[
  ('15m', Duration(minutes: 15)),
  ('1h', Duration(hours: 1)),
  ('6h', Duration(hours: 6)),
  ('24h', Duration(hours: 24)),
  ('7d', Duration(days: 7)),
];

/// Four range-query charts on a 2x2 grid: CPU, temperature, memory, network.
class GraphsScreen extends StatefulWidget {
  const GraphsScreen({
    super.key,
    required this.store,
    required this.active,
  });

  final MetricsStore store;
  final bool active;

  @override
  State<GraphsScreen> createState() => _GraphsScreenState();
}

class _GraphsScreenState extends State<GraphsScreen> {
  int _windowIndex = 1;
  bool _loading = false;
  String? _error;
  int _loadId = 0;
  Timer? _refreshTimer;
  DateTime? _queryEnd;

  List<PromSeries> _cpu = const [];
  List<PromSeries> _cpuTemp = const [];
  List<PromSeries> _gpuTemp = const [];
  List<PromSeries> _gpuUtil = const [];
  List<PromSeries> _mem = const [];
  List<PromSeries> _speedtest = const [];

  Duration get _window => _windows[_windowIndex].$2;

  @override
  void initState() {
    super.initState();
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(GraphsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _activate();
    } else if (!widget.active && oldWidget.active) {
      _loadId++;
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _activate() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(AppConfig.rangeRefresh, (_) {
      if (widget.active && !_loading) _load();
    });
    _load();
  }

  Future<void> _load() async {
    if (!widget.active) return;
    final requestId = ++_loadId;
    final window = _window;
    final queryEnd = DateTime.now();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait([
        widget.store.loadRange(Q.rangeCpu, window, end: queryEnd),
        widget.store.loadRange(Q.rangeTempCpu, window, end: queryEnd),
        widget.store.loadRange(Q.rangeTempGpu, window, end: queryEnd),
        widget.store.loadRange(Q.rangeGpuUtil, window, end: queryEnd),
        widget.store.loadRange(Q.rangeMemPct, window, end: queryEnd),
        widget.store.loadRange(Q.rangeSpeedtestDown, window, end: queryEnd),
      ]);
      if (!mounted ||
          !widget.active ||
          requestId != _loadId ||
          window != _window) {
        return;
      }
      setState(() {
        _cpu = r[0];
        _cpuTemp = r[1];
        _gpuTemp = r[2];
        _gpuUtil = r[3];
        _mem = r[4];
        _speedtest = r[5];
        _queryEnd = queryEnd;
        _loading = false;
      });
      _assignColors();
    } catch (e) {
      if (!mounted || !widget.active || requestId != _loadId) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Colors are handed out once per key and then remembered, so an instance
  /// keeps its color when another one appears or drops out mid-session. A hash
  /// would be stable too, but two instances could land on the same bucket with
  /// nothing to resolve it; a register cannot collide until the palette runs
  /// out, and it is walked in sorted order so a restart reproduces it.
  final Map<String, Color> _nodeColors = {};
  final Map<String, Color> _gpuColors = {};
  final Map<String, Color> _pathColors = {};

  void _assignColors() {
    final nodes = <String>{
      for (final s in _cpu) s.instance ?? '?',
      for (final s in _mem) s.instance ?? '?',
    }.toList()..sort();
    for (final key in nodes) {
      _nodeColors.putIfAbsent(
        key,
        () => TC.nodeSeriesAt(_nodeColors.length),
      );
    }

    final gpus = <String>{
      for (final s in [..._gpuUtil, ..._gpuTemp]) _gpuKey(s),
    }.toList()..sort();
    for (final key in gpus) {
      _gpuColors.putIfAbsent(key, () => TC.gpuSeriesAt(_gpuColors.length));
    }

    final paths = <String>{for (final s in _speedtest) _pathOf(s)}.toList()
      ..sort();
    for (final key in paths) {
      _pathColors.putIfAbsent(key, () => TC.nodeSeriesAt(_pathColors.length));
    }
  }

  /// Which route the measurement went over — the exporter runs the same test
  /// direct and through the proxy, and the gap between them is the point.
  String _pathOf(PromSeries s) => s.labels['path'] ?? 'direct';

  /// One card, whichever metric it arrived on. dcgm-exporter carries a UUID
  /// per GPU; the index is only a fallback for exporters that omit it.
  String _gpuKey(PromSeries s) =>
      '${s.instance ?? "?"}/${s.labels["UUID"] ?? s.labels["gpu"] ?? "0"}';

  Color _nodeColor(String instance) => _nodeColors[instance] ?? TC.dim;

  Color _gpuColor(PromSeries s) => _gpuColors[_gpuKey(s)] ?? TC.amber;

  List<ChartSeries> _byInstance(List<PromSeries> series) => [
    for (final s in series)
      ChartSeries(s.instance ?? '?', s.points, _nodeColor(s.instance ?? '?')),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WindowBar(
          index: _windowIndex,
          loading: _loading,
          error: _error,
          step: MetricsStore.stepFor(_window),
          onPick: (i) {
            if (i == _windowIndex) return;
            setState(() => _windowIndex = i);
            _load();
          },
          onReload: _load,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: TermPanel(
                        title: 'utilisation %',
                        padding: const EdgeInsets.fromLTRB(
                          6,
                          TermPanel.titleGutter,
                          8,
                          4,
                        ),
                        child: TermChart(
                          series: [
                            ..._byInstance(_cpu),
                            for (final s in _gpuUtil)
                              ChartSeries(
                                'gpu${s.labels["gpu"] ?? "0"}',
                                s.points,
                                _gpuColor(s),
                              ),
                          ],
                          window: _window,
                          endTime: _queryEnd,
                          unit: '%',
                          yMin: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TermPanel(
                        title: 'memory used %',
                        padding: const EdgeInsets.fromLTRB(
                          6,
                          TermPanel.titleGutter,
                          8,
                          4,
                        ),
                        child: TermChart(
                          series: _byInstance(_mem),
                          window: _window,
                          endTime: _queryEnd,
                          unit: '%',
                          yMin: 0,
                          yMax: 100,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: TermPanel(
                        title: 'temperature °c',
                        padding: const EdgeInsets.fromLTRB(
                          6,
                          TermPanel.titleGutter,
                          8,
                          4,
                        ),
                        child: TermChart(
                          series: [
                            for (final s in _cpuTemp)
                              ChartSeries(
                                'cpu ${s.labels["label"] ?? s.labels["sensor"] ?? "?"}',
                                s.points,
                                s.labels['label'] == 'Tctl' ? TC.fg : TC.cyan,
                              ),
                            for (final s in _gpuTemp)
                              ChartSeries(
                                'gpu${s.labels["gpu"] ?? "0"}',
                                s.points,
                                _gpuColor(s),
                              ),
                          ],
                          window: _window,
                          endTime: _queryEnd,
                          unit: '°',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TermPanel(
                        title: 'speedtest down · Mbit/s',
                        padding: const EdgeInsets.fromLTRB(
                          6,
                          TermPanel.titleGutter,
                          8,
                          4,
                        ),
                        child: TermChart(
                          series: [
                            for (final s in _speedtest)
                              ChartSeries(
                                _pathOf(s),
                                [
                                  // The exporter reports bits; the number
                                  // people quote for a link is Mbit/s decimal.
                                  for (final p in s.points)
                                    PromPoint(p.t, p.v / 1e6),
                                ],
                                _pathColors[_pathOf(s)] ?? TC.fg,
                              ),
                          ],
                          window: _window,
                          endTime: _queryEnd,
                          unit: 'M',
                          yMin: 0,
                          emptyMessage: 'NO SPEEDTEST RESULTS IN RANGE',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WindowBar extends StatelessWidget {
  const _WindowBar({
    required this.index,
    required this.loading,
    required this.error,
    required this.step,
    required this.onPick,
    required this.onReload,
  });

  final int index;
  final bool loading;
  final String? error;
  final Duration step;
  final ValueChanged<int> onPick;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Text(
            'RANGE',
            style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
          ),
          const SizedBox(width: 8),
          for (var i = 0; i < _windows.length; i++) ...[
            _PickButton(
              label: _windows[i].$1,
              selected: i == index,
              onTap: () => onPick(i),
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 8),
          Text(
            'step ${fmtDuration(step)}',
            style: ts(size: TZ.caption, color: TC.dim),
          ),
          const Spacer(),
          if (error != null)
            Flexible(
              child: Text(
                'RANGE QUERY FAILED: $error',
                style: ts(size: TZ.caption, color: TC.red),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Text(
              loading ? 'LOADING…' : 'OK',
              style: ts(size: TZ.caption, color: loading ? TC.amber : TC.dim),
            ),
          const SizedBox(width: 8),
          _PickButton(label: 'RELOAD', selected: false, onTap: onReload),
        ],
      ),
    );
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? TC.bright : TC.border),
          color: selected ? TC.bright : null,
        ),
        child: Text(
          label,
          style: ts(
            size: TZ.small,
            color: selected ? TC.bg : TC.mid,
            weight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
