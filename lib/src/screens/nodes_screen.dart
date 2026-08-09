import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config.dart';
import '../model/snapshot.dart';
import '../prom/prom_client.dart';
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
  const NodesScreen({
    super.key,
    required this.store,
    required this.active,
  });

  final MetricsStore store;
  final bool active;

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  static const _historyWindow = Duration(hours: 1);

  String? _selected;
  String? _historyFor;

  /// One list per chart. CPU and memory used to share an axis, which made a
  /// busy CPU and a full disk look like the same event; they are separate
  /// charts now, and temperature/GPU only exist for targets that report them.
  List<ChartSeries> _historyCpu = const [];
  List<ChartSeries> _historyMem = const [];
  List<ChartSeries> _historyTemp = const [];
  List<ChartSeries> _historyGpuUtil = const [];
  bool _historyLoading = false;
  DateTime? _historyEnd;
  DateTime? _historyLoadedAt;
  int _historyRequestId = 0;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(NodesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _activate();
    } else if (!widget.active && oldWidget.active) {
      _historyRequestId++;
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
    // A request invalidated while the screen was inactive is no longer loading
    // from this screen's perspective; otherwise re-entry can stay stuck behind
    // the old `_historyLoading` flag forever.
    _historyLoading = false;
    _historyLoadedAt = null;
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(AppConfig.rangeRefresh, (_) {
      if (!widget.active || _historyLoading) return;
      final snap = widget.store.snapshot;
      if (snap == null || snap.nodes.isEmpty) return;
      final instance = snap.nodes
          .firstWhere(
            (n) => n.instance == _selected,
            orElse: () => snap.nodes.first,
          )
          .instance;
      _loadHistory(instance, force: true);
    });
  }

  /// History belongs to whichever target it was fetched for. Showing the
  /// previous target's curve under a new name for one frame is worse than
  /// showing nothing.
  List<ChartSeries> _forSelected(String instance, List<ChartSeries> series) =>
      _historyFor == instance ? series : const [];

  bool _historyExpired() =>
      _historyLoadedAt == null ||
      DateTime.now().difference(_historyLoadedAt!) >= AppConfig.rangeRefresh;

  Future<void> _loadHistory(String instance, {bool force = false}) async {
    if (!widget.active) return;
    if (!force && _historyFor == instance) {
      if (_historyLoading || !_historyExpired()) return;
    }

    final requestId = ++_historyRequestId;
    final queryEnd = DateTime.now();
    final changingTarget = _historyFor != instance;
    _historyFor = instance;

    // Only ask for what this target actually reports. A guest with no hwmon
    // chip and no GPU would otherwise pay for two empty range queries on every
    // refresh, and get two empty charts for them.
    final snap = widget.store.snapshot;
    final hasTemps = snap?.tempsFor(instance).isNotEmpty ?? false;
    final hasGpu = snap?.gpusFor(instance).isNotEmpty ?? false;

    setState(() {
      _historyLoading = true;
      if (changingTarget) {
        _historyCpu = const [];
        _historyMem = const [];
        _historyTemp = const [];
        _historyGpuUtil = const [];
        _historyEnd = null;
      }
    });
    try {
      Future<List<PromSeries>> range(String query) =>
          widget.store.loadRange(query, _historyWindow, end: queryEnd);

      final r = await Future.wait([
        range(Q.cpuFor(instance)),
        range(Q.memUsedBytesFor(instance)),
        if (hasTemps)
          range(Q.hwmonTempFor(instance))
        else
          Future.value(const <PromSeries>[]),
        if (hasGpu)
          range(Q.gpuTempFor(instance))
        else
          Future.value(const <PromSeries>[]),
        if (hasGpu)
          range(Q.gpuUtilFor(instance))
        else
          Future.value(const <PromSeries>[]),
      ]);
      final (cpu, mem, hwmon, gpuTemp, gpuUtil) = (r[0], r[1], r[2], r[3], r[4]);

      if (!mounted ||
          !widget.active ||
          requestId != _historyRequestId ||
          _historyFor != instance) {
        return;
      }
      setState(() {
        _historyCpu = [
          for (final s in cpu) ChartSeries('cpu', s.points, TC.fg),
        ];
        _historyMem = [
          for (final s in mem)
            ChartSeries(
              'memory',
              [
                for (final p in s.points) PromPoint(p.t, p.v / (1024 * 1024 * 1024)),
              ],
              TC.cyan,
            ),
        ];
        _historyTemp = [
          for (final s in hwmon)
            ChartSeries(
              s.labels['label'] ?? s.labels['sensor'] ?? 'sensor',
              s.points,
              s.labels['label'] == 'Tctl' ? TC.fg : TC.cyan,
            ),
          // GPU temperature shares the axis with the host sensors — both are
          // degrees — but keeps the amber it has everywhere else.
          for (final s in gpuTemp)
            ChartSeries(
              'gpu${s.labels["gpu"] ?? "0"}',
              s.points,
              TC.amber,
            ),
        ];
        _historyGpuUtil = [
          for (final s in gpuUtil)
            ChartSeries(
              'gpu${s.labels["gpu"] ?? "0"}',
              s.points,
              TC.amber,
            ),
        ];
        _historyEnd = queryEnd;
        _historyLoadedAt = DateTime.now();
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          !widget.active ||
          requestId != _historyRequestId ||
          _historyFor != instance) {
        return;
      }
      setState(() {
        _historyCpu = const [];
        _historyMem = const [];
        _historyTemp = const [];
        _historyGpuUtil = const [];
        _historyEnd = queryEnd;
        _historyLoadedAt = DateTime.now();
        _historyLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.store.snapshot;
    if (snap == null) {
      return Center(
        child: Text('NO DATA', style: ts(size: TZ.large, color: TC.dim)),
      );
    }
    final nodes = snap.nodes;
    if (nodes.isEmpty) {
      return Center(
        child: Text(
          'NO NODE TARGETS',
          style: ts(size: TZ.large, color: TC.dim, letterSpacing: 1.2),
        ),
      );
    }

    final selected = nodes.firstWhere(
      (n) => n.instance == _selected,
      orElse: () => nodes.first,
    );
    if (widget.active &&
        !_historyLoading &&
        (_historyFor != selected.instance || _historyExpired())) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _loadHistory(selected.instance);
      });
    }

    return Row(
      children: [
        SizedBox(
          width: 262,
          child: TermPanel(
            title: 'targets',
            padding: const EdgeInsets.fromLTRB(6, TermPanel.titleGutter, 6, 6),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: nodes.length,
              itemBuilder: (context, i) {
                final n = nodes[i];
                return _TargetTile(
                  node: n,
                  health: snap.healthOf(n),
                  selected: n.instance == selected.instance,
                  onTap: () => setState(() => _selected = n.instance),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _Detail(
            node: selected,
            snap: snap,
            store: widget.store,
            historyCpu: _forSelected(selected.instance, _historyCpu),
            historyMem: _forSelected(selected.instance, _historyMem),
            historyTemp: _forSelected(selected.instance, _historyTemp),
            historyGpuUtil: _forSelected(selected.instance, _historyGpuUtil),
            historyLoading:
                _historyFor == selected.instance && _historyLoading,
            historyWindow: _historyWindow,
            historyEnd: _historyFor == selected.instance ? _historyEnd : null,
          ),
        ),
      ],
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.node,
    required this.health,
    required this.selected,
    required this.onTap,
  });

  final NodeStat node;
  final NodeHealth health;
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
            _HealthGlyph(health: health, onLitTile: selected),
          ],
        ),
      ),
    );
  }
}

/// Worst-of status for a target, as one character.
///
/// A bare CPU percentage here answered a question nobody was asking: the list
/// exists to say which target needs looking at, and a target can be fine on
/// CPU while its root filesystem is full. The glyphs differ in shape, not only
/// in colour, so the distinction survives on a washed-out panel.
class _HealthGlyph extends StatelessWidget {
  const _HealthGlyph({required this.health, required this.onLitTile});

  final NodeHealth health;

  /// The selected tile is drawn on white, so the glyph inverts with it.
  final bool onLitTile;

  @override
  Widget build(BuildContext context) {
    final (glyph, color) = switch (health) {
      NodeHealth.ok => ('✓', TC.green),
      NodeHealth.warn => ('▲', TC.amber),
      NodeHealth.critical => ('!', TC.red),
      NodeHealth.unknown => ('·', TC.dim),
    };
    return SizedBox(
      width: 14,
      child: Text(
        glyph,
        textAlign: TextAlign.center,
        style: ts(
          size: TZ.body,
          color: onLitTile ? TC.bg : color,
          weight: FontWeight.w700,
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
    required this.historyCpu,
    required this.historyMem,
    required this.historyTemp,
    required this.historyGpuUtil,
    required this.historyLoading,
    required this.historyWindow,
    required this.historyEnd,
  });

  /// Height of one history chart inside the scrolling detail column.
  static const _chartHeight = 132.0;

  final NodeStat node;
  final Snapshot snap;
  final MetricsStore store;
  final List<ChartSeries> historyCpu;
  final List<ChartSeries> historyMem;
  final List<ChartSeries> historyTemp;
  final List<ChartSeries> historyGpuUtil;
  final bool historyLoading;
  final Duration historyWindow;
  final DateTime? historyEnd;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final sensors = snap.tempsFor(n.instance);
    final gpus = snap.gpusFor(n.instance);

    return TermPanel(
      title: '${n.instance} · ${n.role}',
      trailing: TermTag(n.up ? 'UP' : 'DOWN', color: n.up ? TC.green : TC.red),
      padding: const EdgeInsets.fromLTRB(10, TermPanel.titleGutter, 10, 8),
      // Scrolls: with a GPU section and four charts there is more here than a
      // 7" panel can show at once, and clipping the bottom chart silently was
      // the alternative.
      child: ListView(
        padding: EdgeInsets.zero,
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
              if (sensors.isNotEmpty) ...[
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
                    SizedBox(
                      height: 104,
                      child: ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: sensors.length,
                              itemBuilder: (context, i) {
                                final t = sensors[i];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 82,
                                        child: Text(
                                          t.label,
                                          style: ts(size: TZ.body, color: TC.mid),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
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
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              ],
            ],
          ),
          if (gpus.isNotEmpty) ...[
            const TermRule(height: 14),
            _GpuSection(gpus: gpus),
          ],
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
          const SizedBox(height: 4),
          _HistoryChart(
            caption: 'CPU %',
            series: historyCpu,
            window: historyWindow,
            end: historyEnd,
            unit: '%',
            yMax: 100,
            empty: node.up ? 'NO CPU HISTORY' : 'TARGET DOWN · NO HISTORY',
          ),
          _HistoryChart(
            caption: 'MEMORY USED · GiB',
            series: historyMem,
            window: historyWindow,
            end: historyEnd,
            unit: 'G',
            empty: node.up ? 'NO MEMORY HISTORY' : 'TARGET DOWN · NO HISTORY',
          ),
          // Only for targets that have something thermal to report: the
          // hypervisor's hwmon chips, and any GPU on the box.
          if (sensors.isNotEmpty || gpus.isNotEmpty)
            _HistoryChart(
              caption: 'TEMPERATURE °C',
              series: historyTemp,
              window: historyWindow,
              end: historyEnd,
              unit: '°',
              empty: 'NO TEMPERATURE HISTORY',
            ),
          if (gpus.isNotEmpty)
            _HistoryChart(
              caption: 'GPU UTILISATION %',
              series: historyGpuUtil,
              window: historyWindow,
              end: historyEnd,
              unit: '%',
              yMax: 100,
              empty: 'NO GPU HISTORY',
            ),
        ],
      ),
    );
  }
}

/// One captioned history chart in the scrolling detail column.
class _HistoryChart extends StatelessWidget {
  const _HistoryChart({
    required this.caption,
    required this.series,
    required this.window,
    required this.end,
    required this.unit,
    required this.empty,
    this.yMax,
  });

  final String caption;
  final List<ChartSeries> series;
  final Duration window;
  final DateTime? end;
  final String unit;
  final String empty;
  final double? yMax;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caption,
            style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: _Detail._chartHeight,
            child: TermChart(
              series: series,
              window: window,
              endTime: end,
              unit: unit,
              yMin: 0,
              yMax: yMax,
              emptyMessage: empty,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-card GPU readings for a target that has one. The DASH panel only ever
/// shows the first GPU in the cluster; this is where a second card, or the
/// clocks and VRAM behind the headline numbers, actually appear.
class _GpuSection extends StatelessWidget {
  const _GpuSection({required this.gpus});

  final List<GpuStat> gpus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'GPU',
          style: ts(size: TZ.caption, color: TC.dim, letterSpacing: 1.2),
        ),
        const SizedBox(height: 4),
        for (final g in gpus)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'gpu${g.gpu} · ${g.modelShort}',
                      style: ts(size: TZ.body, color: TC.mid),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(width: 8),
                    if (g.stale)
                      TermTag(
                        g.age == null
                            ? 'DOWN'
                            : 'DOWN · ${fmtDuration(g.age)} OLD',
                        color: TC.amber,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          StatLine(
                            label: 'utilisation',
                            value: fmtPct(g.util, digits: 0),
                            valueColor: TC.forPct(g.util),
                            size: TZ.small,
                          ),
                          StatLine(
                            label: 'temperature',
                            value: fmtTemp(g.temp),
                            valueColor: TC.forTemp(g.temp, warn: 75, crit: 88),
                            size: TZ.small,
                          ),
                          StatLine(
                            label: 'memory temp',
                            value: fmtTemp(g.memTemp),
                            size: TZ.small,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          StatLine(
                            label: 'vram',
                            value:
                                '${fmtBytes(g.fbUsedBytes)} / '
                                '${fmtBytes(g.fbTotalBytes)}',
                            size: TZ.small,
                          ),
                          StatLine(
                            label: 'power',
                            value: g.powerWatts == null
                                ? '--'
                                : '${g.powerWatts!.toStringAsFixed(0)} W',
                            size: TZ.small,
                          ),
                          StatLine(
                            label: 'clocks sm/mem',
                            value: g.smClockMhz == null && g.memClockMhz == null
                                ? '--'
                                : '${fmtNum(g.smClockMhz, digits: 0)} / '
                                      '${fmtNum(g.memClockMhz, digits: 0)} MHz',
                            size: TZ.small,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
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
    required this.lines,
  });

  final String caption;
  final String big;
  final Color color;
  final double? pct;
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
        const SizedBox(height: 6),
        for (final (k, v) in lines)
          StatLine(label: k, value: v, size: TZ.small),
      ],
    );
  }
}
