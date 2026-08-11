import 'dart:math' as math;

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
    // Subscribes here rather than at the app root, so a poll rebuilds the one
    // screen that shows the numbers instead of all four.
    return AnimatedBuilder(animation: store, builder: (context, _) => _body());
  }

  Widget _body() {
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

    final content = Column(
      children: [
        SizedBox(
          height: _panelRow,
          child: Row(
            children: [
              SizedBox(width: 322, child: _CpuPanel(snap: snap, store: store)),
              const SizedBox(width: 6),
              SizedBox(width: 344, child: _GpuPanel(snap: snap, store: store)),
              const SizedBox(width: 6),
              Expanded(child: _MemoryPanel(snap: snap, store: store)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _NodeTable(snap: snap, store: store)),
      ],
    );

    if (!store.stale) return content;
    return Stack(
      children: [
        Positioned.fill(child: Opacity(opacity: 0.42, child: content)),
        Positioned(
          top: 6,
          right: 8,
          child: Container(
            color: TC.bg,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              'STALE · LAST GOOD ${fmtDuration(store.snapshotAge)} AGO',
              style: ts(
                size: TZ.caption,
                color: TC.amber,
                weight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
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
            )
          else
            // Same pair as the CPU panel. Stale readings are never recorded,
            // so there is nothing to draw here while the exporter is down.
            Row(
              children: [
                Text('TEMP', style: ts(size: TZ.caption, color: TC.dim)),
                const SizedBox(width: 5),
                Expanded(
                  child: SparkText(
                    values: store.gpuTempHistory,
                    size: TZ.body,
                    color: tempColor,
                    min: TZ.tempFloor,
                    max: TZ.tempCeiling,
                  ),
                ),
                const SizedBox(width: 8),
                Text('UTIL', style: ts(size: TZ.caption, color: TC.dim)),
                const SizedBox(width: 5),
                Expanded(
                  child: SparkText.percent(
                    values: store.gpuUtilHistory,
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
  const _MemoryPanel({required this.snap, required this.store});

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final host = snap.host;
    final total = host?.memTotal;
    final guestsReportingRam = snap.vms.where((n) => n.memTotal != null).length;
    final guestTotalPct =
        (guestsReportingRam > 0 && total != null && total > 0)
        ? snap.vmMemReportedTotal / total * 100
        : null;
    final guestsReportingUsed = snap.vms.where((n) => n.memUsed != null).length;

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
            // This is the sum reported by guest operating systems. It is not
            // a Proxmox allocation/commitment metric.
            label: 'GUEST RAM SUM ($guestsReportingRam)',
            value: guestsReportingRam == 0
                ? '--'
                : '${fmtBytes(snap.vmMemReportedTotal)} · ${fmtPct(guestTotalPct, digits: 0)}',
            size: TZ.body,
            emphasis: false,
          ),
          StatLine(
            label: 'VM IN USE ($guestsReportingUsed)',
            value: guestsReportingUsed == 0 ? '--' : fmtBytes(snap.vmMemUsed),
            size: TZ.body,
            emphasis: false,
          ),
          const Spacer(),
          Row(
            children: [
              Text('RAM', style: ts(size: TZ.caption, color: TC.dim)),
              const SizedBox(width: 5),
              Expanded(
                child: SparkText.percent(
                  values: store.memHistory(host?.instance ?? ''),
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
// Per-node table
// ---------------------------------------------------------------------------

/// One column of the node table: how wide it is, what it is called, and which
/// side its content sits on. The header row and the data rows both read these,
/// so a label cannot drift away from the values beneath it.
/// One table cell, laid out from its column description.
Widget _cell(
  _Column column, {
  required Key key,
  required Widget? child,
}) {
  return SizedBox(
    key: key,
    width: column.width,
    child: Align(alignment: column.align, child: child),
  );
}

class _Column {
  const _Column({
    required this.id,
    required this.width,
    this.header = '',
    this.span = 1,
    this.right = false,
  });

  final String id;
  final double width;
  final String header;

  /// How many columns the heading names, counting this one. `CPU` is one
  /// number and the bar repeating it; `MEMORY` is a percentage, its bar and the
  /// used/total pair. The heading centres over the whole run, so it reads as
  /// the name of that block rather than of the one narrow column it is
  /// declared on.
  final int span;

  /// Numbers are flushed right so their digits line up; names and compound
  /// figures read left. Headings ignore this and centre instead: a label names
  /// its column, not the edge the values happen to sit on.
  final bool right;

  Alignment get align => right ? Alignment.centerRight : Alignment.centerLeft;
  TextAlign get textAlign => right ? TextAlign.right : TextAlign.left;
}

/// The table, declared once.
///
/// Two sizes and no more: every value at [TZ.body], every heading at
/// [TZ.caption]. A third size in a table of numbers reads as emphasis nobody
/// asked for.
///
/// Each column is as wide as the wider of its longest real value and its
/// heading — 0.6em per character at [TZ.body], 0.6em plus tracking at
/// [TZ.caption]. Bars carry no heading; they only restate the number in front
/// of them.
abstract final class _Table {
  static const dot = _Column(id: 'dot', width: 24);
  static const name = _Column(id: 'name', width: 160, header: 'INSTANCE');
  static const cpu = _Column(
    id: 'cpu',
    width: 52,
    header: 'CPU',
    span: 2,
    right: true,
  );
  static const cpuBar = _Column(id: 'cpuBar', width: 120, right: true);
  static const mem = _Column(
    id: 'mem',
    width: 56,
    header: 'MEMORY',
    span: 3,
    right: true,
  );
  static const memBar = _Column(id: 'memBar', width: 120, right: true);
  /// Both this and [root] hold a `used/total` pair, and `fmtBytes` caps each
  /// side at five characters, so eleven is the widest either can get.
  static const memText = _Column(id: 'memText', width: 112);
  static const root = _Column(id: 'root', width: 108, header: 'ROOT');
  static const uptime = _Column(
    id: 'uptime',
    width: 72,
    header: 'UPTIME',
    right: true,
  );

  /// Keeps the last column off the panel frame. The first column needs no such
  /// margin: its content is a small dot inside a wide cell, so it already
  /// looks inset. A right-flushed number has no such slack of its own.
  static const tail = 14.0;

  /// The running order. Every gap between two columns is the same elastic
  /// spacer, so the row's leftover width is shared equally and the spacing
  /// adapts to whatever width the panel gives it.
  ///
  /// This replaced three hand-tuned constants. They encoded a real idea — a
  /// number and the bar repeating it sit closer than two unrelated columns —
  /// but every change to a column width meant re-balancing them by hand, and
  /// the uptime column was clipped on the panel because one of those numbers
  /// was half a character too small.
  static const columns = <_Column>[
    dot,
    name,
    cpu,
    cpuBar,
    mem,
    memBar,
    memText,
    root,
    uptime,
  ];
}

class _NodeTable extends StatelessWidget {
  const _NodeTable({required this.snap, required this.store});

  /// Shortest a row may get before the table starts scrolling instead: below
  /// this the sparkline and the two-line memory cell stop fitting.
  static const _minRow = 44.0;

  final Snapshot snap;
  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    // Guests only. The hypervisor is the whole top row of this screen, so a
    // row repeating it would be the same numbers twice.
    final guests = snap.vms;
    final down = guests.where((n) => !n.up).length;

    return TermPanel(
      title: 'nodes · ${guests.length}',
      trailing: down > 0 ? TermTag('$down DOWN', color: TC.red) : null,
      padding: const EdgeInsets.fromLTRB(8, TermPanel.titleGutter, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 22, child: _TableHeader()),
          Container(height: 1, color: TC.gridLine),
          Expanded(
            child: guests.isEmpty
                ? Center(
                    child: Text(
                      'NO GUEST TARGETS',
                      style: ts(size: TZ.small, color: TC.dim),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      // Rows share the height, as they did when this was a
                      // Column of Expanded children, until sharing would put
                      // them under _minRow. Past that the list scrolls instead
                      // of overflowing the panel.
                      final extent = math.max(
                        _minRow,
                        box.maxHeight / guests.length,
                      );
                      return ListView.builder(
                        padding: EdgeInsets.zero,
                        itemExtent: extent,
                        itemCount: guests.length,
                        itemBuilder: (context, i) => _NodeRow(
                          node: guests[i],
                          store: store,
                          lastRow: i == guests.length - 1,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// The heading row.
///
/// A heading may cover several columns, so it cannot be a child of the same
/// [Row] the cells are: a `Row` can only put a widget between two spacers, not
/// across them. Instead the row's arithmetic is repeated once here — the gap
/// between two columns is whatever is left over, shared equally — and each
/// heading is placed at the span it names. The test pins these boxes to the
/// cells beneath them, so the two layouts cannot drift apart unnoticed.
class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const columns = _Table.columns;
        final fixed =
            columns.fold<double>(0, (sum, c) => sum + c.width) + _Table.tail;
        final gap = math.max(0.0, (box.maxWidth - fixed) / (columns.length - 1));

        // Left edge of every column, in the order the row lays them out.
        final left = <double>[];
        var x = 0.0;
        for (final c in columns) {
          left.add(x);
          x += c.width + gap;
        }

        return Stack(
          children: [
            for (var i = 0; i < columns.length; i++)
              if (columns[i].header.isNotEmpty)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: left[i],
                  width:
                      left[i + columns[i].span - 1] +
                      columns[i + columns[i].span - 1].width -
                      left[i],
                  child: Align(
                    key: ValueKey('head-${columns[i].id}'),
                    child: Text(
                      columns[i].header,
                      style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.store,
    this.lastRow = false,
  });

  final NodeStat node;
  final MetricsStore store;
  final bool lastRow;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final nameColor = n.up ? (n.isHypervisor ? TC.cyan : TC.bright) : TC.red;

    // Keyed by the same column ids the header uses, so the two are laid out
    // from one description rather than two that have to be kept in step.
    final content = <String, Widget>{
      'dot': StateDot(n.up, size: TZ.body),
      'name': Text(
        n.instance,
        style: ts(color: nameColor, weight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      'cpu': MaybeText(
        fmtPct(n.cpuPct),
        present: n.cpuPct != null,
        align: TextAlign.right,
        color: TC.forPct(n.cpuPct),
        weight: FontWeight.w500,
      ),
      'cpuBar': BarGauge(pct: n.cpuPct),
      'mem': MaybeText(
        fmtPct(n.memPct, digits: 0),
        present: n.memPct != null,
        align: TextAlign.right,
        color: TC.forPct(n.memPct),
        weight: FontWeight.w500,
      ),
      'memBar': BarGauge(pct: n.memPct),
      'memText': MaybeText(
        '${fmtBytes(n.memUsed)}/${fmtBytes(n.memTotal)}',
        present: n.memTotal != null,
      ),
      'root': MaybeText(
        '${fmtBytes(n.fsUsed)}/${fmtBytes(n.fsSize)}',
        present: n.fsSize != null,
        color: TC.mid,
      ),
      'uptime': MaybeText(
        fmtDuration(n.uptime),
        present: n.bootTime != null,
        align: TextAlign.right,
        color: TC.mid,
      ),
    };

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: lastRow ? const Color(0x00000000) : TC.gridLine,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _Table.columns.length; i++) ...[
            if (i > 0) const Spacer(),
            _cell(
              _Table.columns[i],
              key: ValueKey('cell-${_Table.columns[i].id}-${n.instance}'),
              child: content[_Table.columns[i].id],
            ),
          ],
          const SizedBox(width: _Table.tail),
        ],
      ),
    );
  }
}
