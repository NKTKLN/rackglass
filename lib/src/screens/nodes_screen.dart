import 'package:flutter/widgets.dart';

import '../model/snapshot.dart';
import '../prom/queries.dart';
import '../state/metrics_store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/gauges.dart';
import '../widgets/term_chart.dart';
import '../widgets/term_panel.dart';

/// Master/detail view: pick a target on the left, read everything about it on
/// the right. This is where the numbers that do not fit on DASH live.
class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key, required this.store});

  final MetricsStore store;

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  static const _historyWindow = Duration(hours: 1);

  String? _selected;

  /// Range-loaded history for whichever target is showing.
  String? _historyFor;
  List<ChartSeries> _history = const [];
  bool _historyLoading = false;

  Future<void> _loadHistory(String instance) async {
    if (_historyFor == instance) return;
    _historyFor = instance;
    setState(() {
      _historyLoading = true;
      _history = const [];
    });
    try {
      final r = await Future.wait([
        widget.store.loadRange(Q.cpuFor(instance), _historyWindow),
        widget.store.loadRange(Q.memPctFor(instance), _historyWindow),
      ]);
      if (!mounted || _historyFor != instance) return;
      setState(() {
        _history = [
          // The chart appends its own unit, so the labels carry none.
          for (final s in r[0]) ChartSeries('cpu', s.points, TC.fg),
          for (final s in r[1]) ChartSeries('memory', s.points, TC.cyan),
        ];
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted || _historyFor != instance) return;
      setState(() {
        _history = const [];
        _historyLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.store.snapshot;
    if (snap == null) {
      return Center(child: Text('NO DATA', style: ts(size: TZ.large, color: TC.dim)));
    }
    final nodes = snap.nodes;
    // Fall back to the first target whenever the selection disappears.
    final selected = nodes.firstWhere(
      (n) => n.instance == _selected,
      orElse: () => nodes.first,
    );
    // The default selection is only known once the first snapshot has landed,
    // so the fetch is kicked off after this frame rather than in initState.
    if (_historyFor != selected.instance) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadHistory(selected.instance),
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 262,
          child: TermPanel(
            title: 'targets',
            padding: const EdgeInsets.fromLTRB(6, TermPanel.titleGutter, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final n in nodes)
                  _TargetTile(
                    node: n,
                    selected: n.instance == selected.instance,
                    onTap: () => setState(() => _selected = n.instance),
                  ),
                const Spacer(),
                for (final g in snap.gpus)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        StateDot(!g.stale, size: TZ.small),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'gpu${g.gpu} ${g.modelShort}',
                            style: ts(size: TZ.caption, color: TC.mid),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _Detail(
            node: selected,
            snap: snap,
            store: widget.store,
            history: _history,
            historyLoading: _historyLoading,
            historyWindow: _historyWindow,
          ),
        ),
      ],
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.node,
    required this.selected,
    required this.onTap,
  });

  final NodeStat node;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? TC.bright : null,
          border: Border.all(
            color: selected ? TC.bright : const Color(0x00000000),
          ),
        ),
        child: Row(
          children: [
            Text(
              selected ? '▸' : ' ',
              style: ts(color: selected ? TC.bg : TC.dim),
            ),
            const SizedBox(width: 4),
            StateDot(node.up, size: TZ.small),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.instance,
                    style: ts(
                      color: node.up
                          ? (selected ? TC.bg : TC.fg)
                          : TC.red,
                      weight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    node.isHypervisor ? 'hypervisor' : node.role,
                    style: ts(
                      size: TZ.caption,
                      color: selected ? TC.gridLine : TC.dim,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              fmtPct(node.cpuPct, digits: 0),
              style: ts(
                size: TZ.small,
                color: selected ? TC.bg : TC.forPct(node.cpuPct),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.node,
    required this.snap,
    required this.store,
    required this.history,
    required this.historyLoading,
    required this.historyWindow,
  });

  final NodeStat node;
  final Snapshot snap;
  final MetricsStore store;
  final List<ChartSeries> history;
  final bool historyLoading;
  final Duration historyWindow;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final sensors = snap.temps.where((t) => t.instance == n.instance).toList();

    return TermPanel(
      title: '${n.instance} · ${n.role}',
      trailing: TermTag(n.up ? 'UP' : 'DOWN', color: n.up ? TC.green : TC.red),
      padding: const EdgeInsets.fromLTRB(10, TermPanel.titleGutter, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MetricBlock(
                  caption: 'CPU',
                  big: fmtPct(n.cpuPct, digits: 1),
                  color: TC.forPct(n.cpuPct),
                  pct: n.cpuPct,
                  spark: store.cpuHistory(n.instance),
                  lines: [
                    ('cores', n.cores?.toStringAsFixed(0) ?? '--'),
                    ('iowait', fmtPct(n.ioWaitPct)),
                    (
                      'load 1/5/15',
                      '${fmtNum(n.load1)} ${fmtNum(n.load5)} ${fmtNum(n.load15)}',
                    ),
                    ('load/core', fmtNum(n.loadPerCore)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricBlock(
                  caption: 'MEMORY',
                  big: fmtPct(n.memPct, digits: 1),
                  color: TC.forPct(n.memPct),
                  pct: n.memPct,
                  spark: store.memHistory(n.instance),
                  lines: [
                    ('used', fmtBytes(n.memUsed)),
                    ('available', fmtBytes(n.memAvailable)),
                    ('total', fmtBytes(n.memTotal)),
                    (
                      'swap',
                      '${fmtBytes(n.swapUsed)} / ${fmtBytes(n.swapTotal)}',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricBlock(
                  caption: 'ROOT FS',
                  big: fmtPct(n.fsPct, digits: 1),
                  color: TC.forPct(n.fsPct),
                  pct: n.fsPct,
                  spark: const [],
                  lines: [
                    ('used', fmtBytes(n.fsUsed)),
                    ('avail', fmtBytes(n.fsAvail)),
                    ('size', fmtBytes(n.fsSize)),
                    ('uptime', fmtDuration(n.uptime)),
                  ],
                ),
              ),
            ],
          ),
          const TermRule(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NETWORK',
                      style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 4),
                    StatLine(
                      label: 'receive',
                      value: fmtRate(n.netRx),
                      valueColor: TC.cyan,
                      size: TZ.body,
                    ),
                    StatLine(
                      label: 'transmit',
                      value: fmtRate(n.netTx),
                      valueColor: TC.cyan,
                      size: TZ.body,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'BOOT',
                      style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 4),
                    StatLine(
                      label: 'booted',
                      value: n.bootTime == null
                          ? '--'
                          : fmtDate(
                              DateTime.fromMillisecondsSinceEpoch(
                                (n.bootTime! * 1000).round(),
                              ),
                            ),
                      size: TZ.body,
                    ),
                    StatLine(
                      label: 'uptime',
                      value: fmtDuration(n.uptime),
                      size: TZ.body,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HWMON SENSORS',
                      style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 4),
                    if (sensors.isEmpty)
                      Text(
                        'none exported by this target',
                        style: ts(size: TZ.small, color: TC.dim),
                      )
                    else
                      for (final t in sensors)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 82,
                                child: Text(
                                  t.label,
                                  style: ts(size: TZ.body, color: TC.mid),
                                ),
                              ),
                              SizedBox(
                                width: 74,
                                child: Text(
                                  fmtTemp(t.celsius),
                                  textAlign: TextAlign.right,
                                  style: ts(
                                    color: TC.forTemp(t.celsius),
                                    weight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // 0-100 °C maps onto the bar, so a glance
                              // compares sensors without reading the numbers.
                              BarGauge(
                                pct: t.celsius,
                                width: 14,
                                color: TC.forTemp(t.celsius),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t.chipShort,
                                  style: ts(size: TZ.caption, color: TC.dim),
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
          const TermRule(height: 12),
          Row(
            children: [
              Text(
                'LAST ${_windowLabel(historyWindow)}',
                style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
              ),
              const Spacer(),
              if (historyLoading)
                Text('LOADING…', style: ts(size: TZ.caption, color: TC.amber)),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: TermChart(
              series: history,
              window: historyWindow,
              unit: '%',
              yMin: 0,
              emptyMessage: node.up
                  ? 'NO HISTORY FOR ${node.instance.toUpperCase()}'
                  : 'TARGET DOWN · NO HISTORY',
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact window label: `1H`, `30M` — `fmtDuration` would say `1h 0m`.
String _windowLabel(Duration d) =>
    d.inMinutes % 60 == 0 ? '${d.inHours}H' : '${d.inMinutes}M';

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.caption,
    required this.big,
    required this.color,
    required this.pct,
    required this.spark,
    required this.lines,
  });

  final String caption;
  final String big;
  final Color color;
  final double? pct;
  final List<double> spark;
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2)),
        const SizedBox(height: 2),
        Text(
          big,
          style: ts(
            size: 30,
            color: color,
            weight: FontWeight.w700,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        BarGauge(pct: pct, width: 20, color: color),
        if (spark.isNotEmpty) ...[
          const SizedBox(height: 2),
          SparkText.percent(values: spark, color: TC.dim),
        ],
        const SizedBox(height: 6),
        for (final (k, v) in lines)
          StatLine(label: k, value: v, size: TZ.small),
      ],
    );
  }
}
