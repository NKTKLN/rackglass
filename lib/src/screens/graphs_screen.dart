import 'package:flutter/widgets.dart';

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
  const GraphsScreen({super.key, required this.store});

  final MetricsStore store;

  @override
  State<GraphsScreen> createState() => _GraphsScreenState();
}

class _GraphsScreenState extends State<GraphsScreen> {
  int _windowIndex = 1;
  bool _loading = true;
  String? _error;

  List<PromSeries> _cpu = const [];
  List<PromSeries> _cpuTemp = const [];
  List<PromSeries> _gpuTemp = const [];
  List<PromSeries> _gpuUtil = const [];
  List<PromSeries> _mem = const [];
  List<PromSeries> _netRx = const [];

  Duration get _window => _windows[_windowIndex].$2;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait([
        widget.store.loadRange(Q.rangeCpu, _window),
        widget.store.loadRange(Q.rangeTempCpu, _window),
        widget.store.loadRange(Q.rangeTempGpu, _window),
        widget.store.loadRange(Q.rangeGpuUtil, _window),
        widget.store.loadRange(Q.rangeMemPct, _window),
        widget.store.loadRange(Q.rangeNetRx, _window),
      ]);
      if (!mounted) return;
      setState(() {
        _cpu = r[0];
        _cpuTemp = r[1];
        _gpuTemp = r[2];
        _gpuUtil = r[3];
        _mem = r[4];
        _netRx = r[5];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Assigns a stable color per instance so a given VM keeps its color across
  /// every chart on the screen.
  Color _colorFor(String key) {
    final order = _instanceOrder;
    final i = order.indexOf(key);
    return TC.seriesAt(i < 0 ? order.length : i);
  }

  List<String> get _instanceOrder {
    final names = <String>{for (final s in _cpu) s.instance ?? '?'}.toList()
      ..sort();
    return names;
  }

  List<ChartSeries> _byInstance(List<PromSeries> series) => [
    for (final s in series)
      ChartSeries(s.instance ?? '?', s.points, _colorFor(s.instance ?? '?')),
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
                        title: 'cpu usage %',
                        padding: const EdgeInsets.fromLTRB(6, 12, 8, 4),
                        child: TermChart(
                          series: _byInstance(_cpu),
                          window: _window,
                          unit: '%',
                          yMin: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TermPanel(
                        title: 'memory used %',
                        padding: const EdgeInsets.fromLTRB(6, 12, 8, 4),
                        child: TermChart(
                          series: _byInstance(_mem),
                          window: _window,
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
                        padding: const EdgeInsets.fromLTRB(6, 12, 8, 4),
                        child: TermChart(
                          series: [
                            for (final s in _cpuTemp)
                              ChartSeries(
                                'cpu ${s.labels["label"] ?? s.labels["sensor"]}',
                                s.points,
                                s.labels['label'] == 'Tctl' ? TC.fg : TC.cyan,
                              ),
                            for (final s in _gpuTemp)
                              ChartSeries(
                                'gpu${s.labels["gpu"] ?? "0"}',
                                s.points,
                                TC.amber,
                              ),
                          ],
                          window: _window,
                          unit: '°',
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: TermPanel(
                        title: 'gpu util % · net rx',
                        padding: const EdgeInsets.fromLTRB(6, 12, 8, 4),
                        child: TermChart(
                          series: [
                            for (final s in _gpuUtil)
                              ChartSeries(
                                'gpu${s.labels["gpu"] ?? "0"} util',
                                s.points,
                                TC.amber,
                              ),
                            // Network is scaled to KB/s so it shares the axis
                            // with a 0-100 utilisation line legibly.
                            for (final s in _netRx)
                              ChartSeries(
                                '${s.instance} rx KB/s',
                                [
                                  for (final p in s.points)
                                    PromPoint(p.t, p.v / 1024),
                                ],
                                _colorFor(s.instance ?? '?'),
                              ),
                          ],
                          window: _window,
                          yMin: 0,
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
      height: 26,
      child: Row(
        children: [
          Text('RANGE', style: ts(size: 10, color: TC.dim, letterSpacing: 1.4)),
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
            style: ts(size: 10, color: TC.dim),
          ),
          const Spacer(),
          if (error != null)
            Text(
              'RANGE QUERY FAILED: $error',
              style: ts(size: 10, color: TC.red),
              maxLines: 1,
            )
          else
            Text(
              loading ? 'LOADING…' : 'OK',
              style: ts(size: 10, color: loading ? TC.amber : TC.dim),
            ),
          const SizedBox(width: 8),
          _PickButton(label: 'RELOAD ⟳', selected: false, onTap: onReload),
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
        // Generous padding: this is driven by a finger on a 7" panel.
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? TC.borderLit : TC.border),
          color: selected ? TC.fg.withValues(alpha: 0.12) : null,
        ),
        child: Text(
          label,
          style: ts(
            size: 11,
            color: selected ? TC.bright : TC.mid,
            weight: selected ? FontWeight.w700 : FontWeight.w400,
            glow: selected ? 5 : 0,
          ),
        ),
      ),
    );
  }
}
