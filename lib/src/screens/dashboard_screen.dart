import 'package:flutter/widgets.dart';

import '../model/snapshot.dart';
import '../state/metrics_store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/gauges.dart';
import '../widgets/term_panel.dart';

/// The at-a-glance screen: host CPU/thermals, GPU, memory budget, and one row
/// per scrape target with CPU and memory side by side.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.store});

  /// Height budget for the top row of panels. The node table takes the rest.
  static const _panelRow = 196.0;

  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final snap = store.snapshot;
    if (snap == null) {
      return Center(
        child: Text(
          store.error == null ? 'CONNECTING…' : 'NO DATA · ${store.error}',
          style: ts(
            size: TZ.large,
            color: store.error == null ? TC.dim : TC.red,
          ),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: _panelRow,
          child: Row(
            children: [
              SizedBox(width: 322, child: _CpuPanel(snap: snap, store: store)),
              const SizedBox(width: 6),
              SizedBox(width: 344, child: _GpuPanel(snap: snap)),
              const SizedBox(width: 6),
              Expanded(child: _MemoryPanel(snap: snap)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _NodeTable(snap: snap, store: store)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// CPU / thermals
// ---------------------------------------------------------------------------

class _CpuPanel extends StatelessWidget {
  const _CpuPanel({required this.snap, required this.store});

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final host = snap.host;
    final pkg = snap.cpuPackageTemp;
    final tempColor = TC.forTemp(pkg?.celsius);

    return TermPanel(
      title: 'cpu · ${host?.instance ?? "host"}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: BigReading(
                  value: pkg == null ? '--' : pkg.celsius.toStringAsFixed(1),
                  unit: '°C',
                  color: tempColor,
                  caption: pkg?.label ?? 'no sensor',
                ),
              ),
              const SizedBox(width: 8),
              // Fixed width, so a wide reading shrinks itself instead of
              // colliding with the sensor list.
              SizedBox(
                width: 104,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final t in snap.otherHostTemps.take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '${t.label} ${fmtTemp(t.celsius, digits: 0)}',
                          style: ts(
                            size: TZ.small,
                            color: TC.forTemp(t.celsius),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const TermRule(),
          StatLine(
            label: 'USAGE',
            value: fmtPct(host?.cpuPct),
            valueColor: TC.forPct(host?.cpuPct),
            size: TZ.body,
          ),
          const SizedBox(height: 3),
          BarGauge(pct: host?.cpuPct, width: 30, size: TZ.body),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  'LOAD ${fmtNum(host?.load1)} ${fmtNum(host?.load5)} ${fmtNum(host?.load15)}',
                  style: ts(size: TZ.small, color: TC.mid),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${host?.cores?.toStringAsFixed(0) ?? "--"} CORES',
                style: ts(size: TZ.small, color: TC.dim),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Text('TEMP', style: ts(size: TZ.caption, color: TC.dim)),
              const SizedBox(width: 5),
              Expanded(
                child: SparkText(
                  values: store.hostTempHistory,
                  width: 18,
                  size: TZ.body,
                  color: tempColor,
                ),
              ),
              const SizedBox(width: 6),
              Text('CPU', style: ts(size: TZ.caption, color: TC.dim)),
              const SizedBox(width: 5),
              SparkText(
                values: store.cpuHistory(host?.instance ?? ''),
                width: 12,
                size: TZ.body,
                color: TC.mid,
                min: 0,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// GPU
// ---------------------------------------------------------------------------

class _GpuPanel extends StatelessWidget {
  const _GpuPanel({required this.snap});

  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    if (snap.gpus.isEmpty) {
      return TermPanel(
        title: 'gpu',
        child: Center(
          child: Text(
            'NO GPU SERIES IN TSDB',
            style: ts(size: TZ.small, color: TC.dim, letterSpacing: 1.2),
          ),
        ),
      );
    }
    final g = snap.gpus.first;
    final stale = g.stale;
    // Stale readings are drawn dim so they can never be mistaken for a live
    // idle GPU; the badge says exactly how old they are.
    final tempColor = stale ? TC.dim : TC.forTemp(g.temp, warn: 80, crit: 90);

    return TermPanel(
      title: 'gpu · ${g.modelShort}',
      accent: stale ? TC.amber : TC.border,
      titleColor: stale ? TC.amber : TC.mid,
      trailing: TermTag(
        stale ? 'DOWN' : 'LIVE',
        color: stale ? TC.red : TC.green,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: BigReading(
                  value: g.temp == null ? '--' : g.temp!.toStringAsFixed(0),
                  unit: '°C',
                  size: 34,
                  color: tempColor,
                  caption: stale
                      ? 'LAST SEEN ${fmtDuration(g.age)} AGO'
                      : 'core · mem ${fmtTemp(g.memTemp, digits: 0)}',
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 118,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${fmtNum(g.powerWatts, digits: 0)} W',
                      style: ts(
                        size: TZ.body,
                        color: stale ? TC.dim : TC.bright,
                      ),
                    ),
                    Text(
                      'SM ${fmtNum(g.smClockMhz, digits: 0)}MHz',
                      style: ts(size: TZ.caption, color: TC.dim),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'MEM ${fmtNum(g.memClockMhz, digits: 0)}MHz',
                      style: ts(size: TZ.caption, color: TC.dim),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const TermRule(height: 8),
          // Label, bar and value on one line each: this panel carries more
          // readings than its neighbours and has no room for stacked rows.
          _InlineBar(
            label: 'UTIL',
            pct: g.util,
            value: fmtPct(g.util, digits: 0),
            dimmed: stale,
          ),
          const SizedBox(height: 4),
          _InlineBar(
            label: 'VRAM',
            pct: g.fbPct,
            value: fmtPct(g.fbPct, digits: 0),
            dimmed: stale,
          ),
          const SizedBox(height: 2),
          Text(
            '${fmtBytes(g.fbUsedBytes)} of ${fmtBytes(g.fbTotalBytes)} used',
            style: ts(
              size: TZ.small,
              color: stale ? TC.dim : TC.mid,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          if (stale)
            Text(
              '! ${g.instance} exporter unreachable',
              style: ts(size: TZ.caption, color: TC.red),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// `LABEL ██████░░░░  42%` on a single line.
class _InlineBar extends StatelessWidget {
  const _InlineBar({
    required this.label,
    required this.pct,
    required this.value,
    this.dimmed = false,
  });

  final String label;
  final double? pct;
  final String value;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: ts(size: TZ.small, color: TC.dim)),
        ),
        Expanded(
          child: BarGauge(
            pct: pct,
            width: 22,
            size: TZ.body,
            color: dimmed ? TC.dim : null,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: ts(
              color: dimmed ? TC.dim : TC.forPct(pct),
              weight: FontWeight.w500,
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Memory budget
// ---------------------------------------------------------------------------

class _MemoryPanel extends StatelessWidget {
  const _MemoryPanel({required this.snap});

  final Snapshot snap;

  @override
  Widget build(BuildContext context) {
    final host = snap.host;
    final total = host?.memTotal;
    final allocPct = (total != null && total > 0)
        ? snap.vmMemAllocated / total * 100
        : null;

    return TermPanel(
      title: 'memory',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BigReading(
            value: fmtBytes(host?.memUsed),
            unit: '/ ${fmtBytes(total)}',
            color: TC.forPct(host?.memPct),
            caption: 'HOST RAM IN USE · ${fmtPct(host?.memPct, digits: 0)}',
            size: 30,
          ),
          const SizedBox(height: 4),
          BarGauge(pct: host?.memPct, width: 30, size: TZ.body),
          const TermRule(height: 8),
          StatLine(
            label: 'SWAP',
            value: '${fmtBytes(host?.swapUsed)} / ${fmtBytes(host?.swapTotal)}',
            valueColor: TC.forPct(host?.swapPct),
            size: TZ.body,
          ),
          StatLine(
            // The overcommit ratio matters more than a second bar would, and
            // costs one line instead of three.
            label: 'VM ALLOCATED (${snap.vms.length})',
            value:
                '${fmtBytes(snap.vmMemAllocated)} · ${fmtPct(allocPct, digits: 0)}',
            valueColor: TC.cyan,
            size: TZ.body,
          ),
          StatLine(
            label: 'VM IN USE',
            value: fmtBytes(snap.vmMemUsed),
            valueColor: TC.cyan,
            size: TZ.body,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-node table
// ---------------------------------------------------------------------------

/// Column widths, in design pixels. Kept as constants so the header and the
/// rows can never drift apart, and sized off the widest real value each column
/// has to hold at [TZ.body] (0.6em advance).
abstract final class _Col {
  static const dot = 20.0;
  static const name = 162.0; // 'vm-amnezia-proxy'
  static const role = 100.0; // 'gpu-workers'
  static const cpuPct = 56.0; // '10.6%'
  static const cpuBar = 92.0; // 10 cells
  static const cpuSpark = 74.0; // 8 cells
  static const memText = 116.0; // '14.7G/31.3G'
  static const memPct = 46.0; // '47%'
  static const memBar = 92.0;
  static const memSpark = 74.0;
  static const cores = 46.0;
  static const uptime = 62.0; // '2d 2h'
}

class _NodeTable extends StatelessWidget {
  const _NodeTable({required this.snap, required this.store});

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    return TermPanel(
      title: 'nodes · ${snap.nodes.length} targets',
      trailing: snap.targetsDown > 0
          ? TermTag('${snap.targetsDown} DOWN', color: TC.red)
          : null,
      padding: const EdgeInsets.fromLTRB(8, TermPanel.titleGutter, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TableHeader(),
          Container(height: 1, color: TC.gridLine),
          Expanded(
            child: Column(
              children: [
                for (final n in snap.nodes)
                  Expanded(child: _NodeRow(node: n, store: store)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, double w, {TextAlign a = TextAlign.left}) => SizedBox(
      width: w,
      child: Text(
        t,
        textAlign: a,
        style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          h('', _Col.dot),
          h('INSTANCE', _Col.name),
          h('ROLE', _Col.role),
          h('CPU%', _Col.cpuPct, a: TextAlign.right),
          const SizedBox(width: 6),
          h('', _Col.cpuBar),
          h('', _Col.cpuSpark),
          const SizedBox(width: 6),
          h('MEMORY', _Col.memText),
          h('', _Col.memPct),
          const SizedBox(width: 6),
          h('', _Col.memBar),
          h('', _Col.memSpark),
          const Spacer(),
          h('CORES', _Col.cores, a: TextAlign.right),
          h('UPTIME', _Col.uptime, a: TextAlign.right),
        ],
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node, required this.store});

  final NodeStat node;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final nameColor = n.up ? (n.isHypervisor ? TC.cyan : TC.bright) : TC.red;

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.gridLine)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: _Col.dot,
                child: StateDot(n.up, size: TZ.small),
              ),
              SizedBox(
                width: _Col.name,
                child: Text(
                  n.instance,
                  style: ts(
                    color: nameColor,
                    weight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: _Col.role,
                child: Text(
                  n.role,
                  style: ts(size: TZ.small, color: TC.dim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: _Col.cpuPct,
                child: MaybeText(
                  fmtPct(n.cpuPct),
                  present: n.cpuPct != null,
                  align: TextAlign.right,
                  color: TC.forPct(n.cpuPct),
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _Col.cpuBar,
                child: BarGauge(pct: n.cpuPct, width: 10),
              ),
              SizedBox(
                width: _Col.cpuSpark,
                child: SparkText(
                  values: store.cpuHistory(n.instance),
                  width: 8,
                  color: TC.dim,
                  min: 0,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _Col.memText,
                child: MaybeText(
                  '${fmtBytes(n.memUsed)}/${fmtBytes(n.memTotal)}',
                  present: n.memTotal != null,
                ),
              ),
              SizedBox(
                width: _Col.memPct,
                child: MaybeText(
                  fmtPct(n.memPct, digits: 0),
                  present: n.memPct != null,
                  align: TextAlign.right,
                  color: TC.forPct(n.memPct),
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _Col.memBar,
                child: BarGauge(pct: n.memPct, width: 10),
              ),
              SizedBox(
                width: _Col.memSpark,
                child: SparkText(
                  values: store.memHistory(n.instance),
                  width: 8,
                  color: TC.dim,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: _Col.cores,
                child: MaybeText(
                  n.cores?.toStringAsFixed(0) ?? '--',
                  present: n.cores != null,
                  align: TextAlign.right,
                  color: TC.mid,
                ),
              ),
              SizedBox(
                width: _Col.uptime,
                child: MaybeText(
                  fmtDuration(n.uptime),
                  present: n.bootTime != null,
                  align: TextAlign.right,
                  size: TZ.small,
                  color: TC.mid,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: _Col.dot),
            child: Text(
              'load ${fmtNum(n.load1)}/${fmtNum(n.load5)}/${fmtNum(n.load15)}'
              '   ·   / ${fmtBytes(n.fsUsed)} of ${fmtBytes(n.fsSize)} (${fmtPct(n.fsPct, digits: 0)})'
              '   ·   net ↓${fmtRate(n.netRx)} ↑${fmtRate(n.netTx)}'
              '   ·   iowait ${fmtPct(n.ioWaitPct)}',
              style: ts(size: TZ.small, color: TC.dim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
