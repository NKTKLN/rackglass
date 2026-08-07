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
      // The hypervisor no longer has a row in the table below, so this is the
      // only place its target going down can show up.
      trailing: host != null && !host.up
          ? const TermTag('DOWN', color: TC.red)
          : null,
      accent: host != null && !host.up ? TC.red : TC.border,
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
          // Both strips are Expanded so they split the leftover evenly. One
          // Expanded and one loose child would hand the whole row to the first
          // and leave the second with whatever the fit logic makes of an
          // unbounded width.
          Row(
            children: [
              Text('TEMP', style: ts(size: TZ.caption, color: TC.dim)),
              const SizedBox(width: 5),
              Expanded(
                child: SparkText(
                  values: store.hostTempHistory,
                  size: TZ.body,
                  color: tempColor,
                  // A fixed band: without it a 0.4 °C wobble draws a mountain
                  // range and the panel looks alarming for no reason.
                  min: TZ.tempFloor,
                  max: TZ.tempCeiling,
                ),
              ),
              const SizedBox(width: 8),
              Text('CPU', style: ts(size: TZ.caption, color: TC.dim)),
              const SizedBox(width: 5),
              Expanded(
                child: SparkText.percent(
                  values: store.cpuHistory(host?.instance ?? ''),
                  size: TZ.body,
                  color: TC.mid,
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
      // Only the bad state gets a badge. A healthy GPU is the default, and
      // labelling it says nothing you could act on.
      trailing: stale ? const TermTag('DOWN', color: TC.red) : null,
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
/// has to hold at [TZ.large] (0.6em advance).
///
/// One line per node: the live reading only. Role and core count are static
/// facts that belong on NODES, history has its own screen, and the second line
/// of detail was costing more attention than it returned.
abstract final class _Col {
  static const dot = 24.0;
  static const name = 186.0; // 'vm-amnezia-proxy'
  static const cpuPct = 62.0; // '10.6%'
  static const cpuBar = 104.0;
  static const memText = 128.0; // '14.7G/31.3G'
  static const memPct = 50.0; // '47%'
  static const memBar = 104.0;
  static const root = 128.0; // '13.3G/61.0G'
  static const uptime = 72.0; // '2d 2h'

  /// Gap between column groups. Whitespace does the separating; rules through
  /// every row turned the table into a grid of boxes.
  static const gap = 20.0;

  /// Breathing room between a reading and the bar that repeats it.
  static const pad = 8.0;
}

class _NodeTable extends StatelessWidget {
  const _NodeTable({required this.snap, required this.store});

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    // Guests only. The hypervisor is the whole top row of this screen, so a
    // row repeating it would be the same numbers twice.
    final guests = snap.vms;
    final down = guests.where((n) => !n.up).length;

    return TermPanel(
      title: 'guests · ${guests.length}',
      trailing: down > 0 ? TermTag('$down DOWN', color: TC.red) : null,
      padding: const EdgeInsets.fromLTRB(8, TermPanel.titleGutter, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 22, child: _TableHeader()),
          Container(height: 1, color: TC.gridLine),
          Expanded(
            child: Column(
              children: [
                for (final n in guests)
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        h('', _Col.dot),
        h('INSTANCE', _Col.name),
        const SizedBox(width: _Col.gap),
        h('CPU', _Col.cpuPct, a: TextAlign.right),
        const SizedBox(width: _Col.pad),
        h('', _Col.cpuBar),
        const SizedBox(width: _Col.gap),
        h('MEMORY', _Col.memText),
        h('', _Col.memPct),
        const SizedBox(width: _Col.pad),
        h('', _Col.memBar),
        const SizedBox(width: _Col.gap),
        h('ROOT', _Col.root),
        const SizedBox(width: _Col.gap),
        h('UPTIME', _Col.uptime, a: TextAlign.right),
        const Spacer(),
      ],
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

    // Cells are stretched so the column rules run the full height of the row;
    // each one aligns its own content vertically.
    Widget cell(double width, Widget child, {Alignment align = Alignment.centerLeft}) =>
        SizedBox(width: width, child: Align(alignment: align, child: child));

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.gridLine)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cell(_Col.dot, StateDot(n.up, size: TZ.body)),
          cell(
            _Col.name,
            Text(
              n.instance,
              style: ts(
                size: TZ.large,
                color: nameColor,
                weight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: _Col.gap),
          cell(
            _Col.cpuPct,
            MaybeText(
              fmtPct(n.cpuPct),
              present: n.cpuPct != null,
              align: TextAlign.right,
              size: TZ.large,
              color: TC.forPct(n.cpuPct),
              weight: FontWeight.w500,
            ),
            align: Alignment.centerRight,
          ),
          const SizedBox(width: _Col.pad),
          cell(
            _Col.cpuBar,
            BarGauge(pct: n.cpuPct, size: TZ.large),
            align: Alignment.centerRight,
          ),
          const SizedBox(width: _Col.gap),
          cell(
            _Col.memText,
            MaybeText(
              '${fmtBytes(n.memUsed)}/${fmtBytes(n.memTotal)}',
              present: n.memTotal != null,
              size: TZ.large,
            ),
          ),
          cell(
            _Col.memPct,
            MaybeText(
              fmtPct(n.memPct, digits: 0),
              present: n.memPct != null,
              align: TextAlign.right,
              size: TZ.large,
              color: TC.forPct(n.memPct),
              weight: FontWeight.w500,
            ),
            align: Alignment.centerRight,
          ),
          const SizedBox(width: _Col.pad),
          cell(
            _Col.memBar,
            BarGauge(pct: n.memPct, size: TZ.large),
            align: Alignment.centerRight,
          ),
          const SizedBox(width: _Col.gap),
          cell(
            _Col.root,
            MaybeText(
              '${fmtBytes(n.fsUsed)}/${fmtBytes(n.fsSize)}',
              present: n.fsSize != null,
              size: TZ.large,
              color: TC.mid,
            ),
          ),
          const SizedBox(width: _Col.gap),
          cell(
            _Col.uptime,
            MaybeText(
              fmtDuration(n.uptime),
              present: n.bootTime != null,
              align: TextAlign.right,
              size: TZ.body,
              color: TC.mid,
            ),
            align: Alignment.centerRight,
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
