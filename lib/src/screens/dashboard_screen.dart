import 'package:flutter/widgets.dart';

import '../model/snapshot.dart';
import '../state/metrics_store.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/gauges.dart';
import '../widgets/term_panel.dart';

/// The at-a-glance screen: host CPU/thermals, GPU, memory budget, and one row
/// per VM with CPU and memory side by side.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.store});

  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final snap = store.snapshot;
    if (snap == null) {
      return Center(
        child: Text(
          store.error == null ? 'CONNECTING…' : 'NO DATA · ${store.error}',
          style: ts(size: 13, color: store.error == null ? TC.dim : TC.red),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 166,
          child: Row(
            children: [
              SizedBox(width: 320, child: _CpuPanel(snap: snap, store: store)),
              const SizedBox(width: 6),
              SizedBox(width: 340, child: _GpuPanel(snap: snap, store: store)),
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
      accent: TC.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BigReading(
                value: pkg == null ? '--' : pkg.celsius.toStringAsFixed(1),
                unit: '°C',
                color: tempColor,
                caption: pkg?.label ?? 'no sensor',
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final t in snap.otherHostTemps.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: Text(
                        '${t.label.padRight(6)} ${fmtTemp(t.celsius, digits: 0).padLeft(6)}',
                        style: ts(size: 10, color: TC.forTemp(t.celsius)),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const TermRule(height: 10),
          StatLine(
            label: 'USAGE',
            value: fmtPct(host?.cpuPct),
            valueColor: TC.forPct(host?.cpuPct),
            glow: 6,
          ),
          const SizedBox(height: 2),
          BarGauge(pct: host?.cpuPct, width: 34, size: 11),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                'LOAD ${fmtNum(host?.load1)} ${fmtNum(host?.load5)} ${fmtNum(host?.load15)}',
                style: ts(size: 10, color: TC.mid),
              ),
              const Spacer(),
              Text(
                '${host?.cores?.toStringAsFixed(0) ?? "--"} CORES',
                style: ts(size: 10, color: TC.dim),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Text('TEMP', style: ts(size: 9, color: TC.dim)),
              const SizedBox(width: 4),
              Expanded(
                child: SparkText(
                  values: store.hostTempHistory,
                  width: 22,
                  size: 11,
                  color: tempColor.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(width: 6),
              Text('CPU', style: ts(size: 9, color: TC.dim)),
              const SizedBox(width: 4),
              SparkText(
                values: store.cpuHistory(host?.instance ?? ''),
                width: 14,
                size: 11,
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
  const _GpuPanel({required this.snap, required this.store});

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    if (snap.gpus.isEmpty) {
      return TermPanel(
        title: 'gpu',
        child: Center(
          child: Text(
            'NO GPU SERIES IN TSDB',
            style: ts(size: 11, color: TC.dim, letterSpacing: 1.4),
          ),
        ),
      );
    }
    final g = snap.gpus.first;
    final stale = g.stale;
    // Stale readings are drawn dim and amber so they can never be mistaken for
    // a live idle GPU; the badge says exactly how old they are.
    final tempColor = stale
        ? TC.amber.withValues(alpha: 0.75)
        : TC.forTemp(g.temp, warn: 80, crit: 90);

    return TermPanel(
      title: 'gpu · ${g.modelShort}',
      accent: stale ? TC.amber.withValues(alpha: 0.45) : TC.border,
      titleColor: stale ? TC.amber : TC.mid,
      trailing: TermTag(
        stale ? 'DOWN' : 'LIVE',
        color: stale ? TC.red : TC.fg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BigReading(
                value: g.temp == null ? '--' : g.temp!.toStringAsFixed(0),
                unit: '°C',
                color: tempColor,
                caption: stale
                    ? 'LAST SEEN ${fmtDuration(g.age)} AGO'
                    : 'core · mem ${fmtTemp(g.memTemp, digits: 0)}',
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${fmtNum(g.powerWatts, digits: 0)} W',
                    style: ts(size: 11, color: stale ? TC.dim : TC.bright),
                  ),
                  Text(
                    'SM ${fmtNum(g.smClockMhz, digits: 0)}MHz',
                    style: ts(size: 9, color: TC.dim),
                  ),
                  Text(
                    'MEM ${fmtNum(g.memClockMhz, digits: 0)}MHz',
                    style: ts(size: 9, color: TC.dim),
                  ),
                ],
              ),
            ],
          ),
          const TermRule(height: 10),
          StatLine(
            label: 'UTIL',
            value: fmtPct(g.util, digits: 0),
            valueColor: stale ? TC.dim : TC.forPct(g.util),
          ),
          const SizedBox(height: 2),
          BarGauge(
            pct: g.util,
            width: 36,
            size: 11,
            color: stale ? TC.dim : null,
          ),
          const SizedBox(height: 4),
          StatLine(
            label: 'VRAM',
            value:
                '${fmtBytes(g.fbUsedBytes)} / ${fmtBytes(g.fbTotalBytes)}  ${fmtPct(g.fbPct, digits: 0)}',
            valueColor: stale ? TC.dim : TC.bright,
            size: 11,
          ),
          const SizedBox(height: 2),
          BarGauge(
            pct: g.fbPct,
            width: 36,
            size: 11,
            color: stale ? TC.dim : null,
          ),
          const Spacer(),
          if (stale)
            Text(
              '! dcgm-exporter on ${g.instance} unreachable',
              style: ts(size: 9, color: TC.red),
              maxLines: 1,
            )
          else
            Row(
              children: [
                Text('UTIL', style: ts(size: 9, color: TC.dim)),
                const SizedBox(width: 4),
                Expanded(
                  child: SparkText(
                    values: store.gpuUtilHistory,
                    width: 20,
                    size: 11,
                    color: TC.mid,
                    min: 0,
                    max: 100,
                  ),
                ),
              ],
            ),
        ],
      ),
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
            size: 26,
          ),
          const SizedBox(height: 4),
          BarGauge(pct: host?.memPct, width: 34, size: 11),
          const TermRule(height: 8),
          StatLine(
            label: 'SWAP',
            value:
                '${fmtBytes(host?.swapUsed)} / ${fmtBytes(host?.swapTotal)}',
            valueColor: TC.forPct(host?.swapPct),
            size: 11,
          ),
          const SizedBox(height: 2),
          BarGauge(pct: host?.swapPct, width: 34, size: 11),
          const SizedBox(height: 3),
          StatLine(
            label: 'VM ALLOCATED (${snap.vms.length} vm)',
            value: fmtBytes(snap.vmMemAllocated),
            valueColor: TC.cyan,
            size: 11,
          ),
          StatLine(
            label: 'VM IN USE',
            value: fmtBytes(snap.vmMemUsed),
            valueColor: TC.cyan,
            size: 11,
          ),
          const SizedBox(height: 2),
          BarGauge(pct: allocPct, width: 34, size: 11, color: TC.cyan),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-node table
// ---------------------------------------------------------------------------

/// Column widths, in design pixels. Kept as constants so the header and the
/// rows can never drift apart.
abstract final class _Col {
  static const dot = 16.0;
  static const name = 152.0;
  static const role = 88.0;
  static const cpuPct = 50.0;
  static const cpuBar = 88.0;
  static const cpuSpark = 66.0;
  static const memText = 116.0;
  static const memPct = 42.0;
  static const memBar = 88.0;
  static const memSpark = 66.0;
  static const cores = 52.0;
  static const uptime = 76.0;
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
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
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
        style: ts(size: 9, color: TC.dim, letterSpacing: 1.1),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
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
          h('', _Col.memPct, a: TextAlign.right),
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
    final nameColor = n.up
        ? (n.isHypervisor ? TC.cyan : TC.bright)
        : TC.red;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.gridLine.withValues(alpha: 0.6))),
        color: n.isHypervisor ? TC.cyan.withValues(alpha: 0.035) : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: _Col.dot, child: StateDot(n.up, size: 11)),
              SizedBox(
                width: _Col.name,
                child: Text(
                  n.instance,
                  style: ts(size: 13, color: nameColor, weight: FontWeight.w500),
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
              SizedBox(
                width: _Col.role,
                child: Text(n.role, style: ts(size: 11, color: TC.dim)),
              ),
              SizedBox(
                width: _Col.cpuPct,
                child: MaybeText(
                  fmtPct(n.cpuPct),
                  present: n.cpuPct != null,
                  align: TextAlign.right,
                  size: 12,
                  color: TC.forPct(n.cpuPct),
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _Col.cpuBar,
                child: BarGauge(pct: n.cpuPct, width: 12, size: 11),
              ),
              SizedBox(
                width: _Col.cpuSpark,
                child: SparkText(
                  values: store.cpuHistory(n.instance),
                  width: 9,
                  size: 11,
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
                  size: 12,
                ),
              ),
              SizedBox(
                width: _Col.memPct,
                child: MaybeText(
                  fmtPct(n.memPct, digits: 0),
                  present: n.memPct != null,
                  align: TextAlign.right,
                  size: 12,
                  color: TC.forPct(n.memPct),
                  weight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _Col.memBar,
                child: BarGauge(pct: n.memPct, width: 12, size: 11),
              ),
              SizedBox(
                width: _Col.memSpark,
                child: SparkText(
                  values: store.memHistory(n.instance),
                  width: 9,
                  size: 11,
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
                  size: 12,
                  color: TC.mid,
                ),
              ),
              SizedBox(
                width: _Col.uptime,
                child: MaybeText(
                  fmtDuration(n.uptime),
                  present: n.bootTime != null,
                  align: TextAlign.right,
                  size: 11,
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
              '   ·   iowait ${fmtPct(n.ioWaitPct, digits: 1)}',
              style: ts(size: 10, color: TC.dim),
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}
