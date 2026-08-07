import 'package:flutter/widgets.dart';

import '../model/snapshot.dart';
import '../state/metrics_store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/gauges.dart';
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
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final snap = widget.store.snapshot;
    if (snap == null) {
      return Center(child: Text('NO DATA', style: ts(size: 13, color: TC.dim)));
    }
    final nodes = snap.nodes;
    // Fall back to the first target whenever the selection disappears.
    final selected = nodes.firstWhere(
      (n) => n.instance == _selected,
      orElse: () => nodes.first,
    );

    return Row(
      children: [
        SizedBox(
          width: 246,
          child: TermPanel(
            title: 'targets',
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
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
                        StateDot(!g.stale, size: 11),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            'gpu${g.gpu} ${g.modelShort}',
                            style: ts(size: 10, color: TC.mid),
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
        Expanded(child: _Detail(node: selected, snap: snap, store: widget.store)),
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
          color: selected ? TC.fg.withValues(alpha: 0.10) : null,
          border: Border.all(
            color: selected ? TC.borderLit : const Color(0x00000000),
          ),
        ),
        child: Row(
          children: [
            Text(
              selected ? '▸' : ' ',
              style: ts(size: 12, color: TC.fg, glow: 5),
            ),
            const SizedBox(width: 4),
            StateDot(node.up, size: 11),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.instance,
                    style: ts(
                      size: 12,
                      color: node.up
                          ? (selected ? TC.bright : TC.fg)
                          : TC.red,
                      weight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    softWrap: false,
                  ),
                  Text(
                    node.isHypervisor ? 'hypervisor' : node.role,
                    style: ts(size: 9, color: TC.dim),
                  ),
                ],
              ),
            ),
            Text(
              fmtPct(node.cpuPct, digits: 0),
              style: ts(size: 11, color: TC.forPct(node.cpuPct)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.node, required this.snap, required this.store});

  final NodeStat node;
  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final sensors = snap.temps.where((t) => t.instance == n.instance).toList();

    return TermPanel(
      title: '${n.instance} · ${n.role}',
      trailing: TermTag(n.up ? 'UP' : 'DOWN', color: n.up ? TC.fg : TC.red),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
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
                      style: ts(size: 10, color: TC.dim, letterSpacing: 1.4),
                    ),
                    const SizedBox(height: 4),
                    StatLine(
                      label: 'receive',
                      value: fmtRate(n.netRx),
                      valueColor: TC.cyan,
                      size: 12,
                    ),
                    StatLine(
                      label: 'transmit',
                      value: fmtRate(n.netTx),
                      valueColor: TC.cyan,
                      size: 12,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'BOOT',
                      style: ts(size: 10, color: TC.dim, letterSpacing: 1.4),
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
                      size: 12,
                    ),
                    StatLine(
                      label: 'uptime',
                      value: fmtDuration(n.uptime),
                      size: 12,
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
                      style: ts(size: 10, color: TC.dim, letterSpacing: 1.4),
                    ),
                    const SizedBox(height: 4),
                    if (sensors.isEmpty)
                      Text(
                        'none exported by this target',
                        style: ts(size: 11, color: TC.dim),
                      )
                    else
                      for (final t in sensors)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 70,
                                child: Text(
                                  t.label,
                                  style: ts(size: 11, color: TC.mid),
                                ),
                              ),
                              SizedBox(
                                width: 62,
                                child: Text(
                                  fmtTemp(t.celsius),
                                  textAlign: TextAlign.right,
                                  style: ts(
                                    size: 12,
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
                                width: 18,
                                size: 11,
                                color: TC.forTemp(t.celsius),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t.chipShort,
                                  style: ts(size: 9, color: TC.gridLine),
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
        ],
      ),
    );
  }
}

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
        Text(caption, style: ts(size: 10, color: TC.dim, letterSpacing: 1.4)),
        const SizedBox(height: 2),
        Text(
          big,
          style: ts(
            size: 26,
            color: color,
            weight: FontWeight.w700,
            glow: 10,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        BarGauge(pct: pct, width: 22, size: 11, color: color),
        if (spark.isNotEmpty) ...[
          const SizedBox(height: 2),
          SparkText(values: spark, width: 22, size: 11, color: TC.dim, min: 0),
        ],
        const SizedBox(height: 6),
        for (final (k, v) in lines)
          StatLine(label: k, value: v, size: 11),
      ],
    );
  }
}
