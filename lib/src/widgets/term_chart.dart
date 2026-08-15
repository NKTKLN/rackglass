import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/widgets.dart';

import '../prom/prom_client.dart';
import '../theme.dart';
import '../util.dart';

/// One line on a [TermChart].
class ChartSeries {
  const ChartSeries(this.label, this.points, this.color);

  final String label;
  final List<PromPoint> points;
  final Color color;
}

/// Time-series line chart on a dashed console grid: flat 1px lines, a faint
/// area fill, and axis ticks in the console palette.
class TermChart extends StatelessWidget {
  const TermChart({
    super.key,
    required this.series,
    required this.window,
    this.endTime,
    this.unit = '',
    this.yMin,
    this.yMax,
    this.yTicks = 4,
    this.emptyMessage = 'NO DATA IN RANGE',
  });

  final List<ChartSeries> series;
  final Duration window;

  /// Exact end boundary used for the Prometheus range query. Without this, a
  /// dead series' last sample would be shifted to the right edge and labelled
  /// `now`, visually hiding the gap since it stopped.
  final DateTime? endTime;
  final String unit;

  /// Force the y-range; otherwise it is derived from the data with headroom.
  final double? yMin;
  final double? yMax;
  final int yTicks;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final hasData = series.any((s) => s.points.isNotEmpty);
    if (!hasData) {
      return Center(
        child: Text(
          emptyMessage,
          style: ts(size: TZ.small, color: TC.dim, letterSpacing: 1.5),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: CustomPaint(
            painter: _ChartPainter(
              series: series,
              window: window,
              endTime: endTime,
              unit: unit,
              forcedMin: yMin,
              forcedMax: yMax,
              yTicks: yTicks,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 3),
        _Legend(series: series, unit: unit),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.series, required this.unit});

  final List<ChartSeries> series;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in series)
            if (s.points.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(
                  children: [
                    Text(
                      '─',
                      style: ts(size: TZ.body, color: s.color),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      s.label,
                      style: ts(size: TZ.caption, color: TC.mid),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${fmtNum(s.points.last.v, digits: 1)}$unit',
                      style: ts(size: TZ.caption, color: TC.bright),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.series,
    required this.window,
    required this.endTime,
    required this.unit,
    required this.forcedMin,
    required this.forcedMax,
    required this.yTicks,
  });

  final List<ChartSeries> series;
  final Duration window;

  /// Exact end boundary used for the Prometheus range query. Without this, a
  /// dead series' last sample would be shifted to the right edge and labelled
  /// `now`, visually hiding the gap since it stopped.
  final DateTime? endTime;
  final String unit;
  final double? forcedMin;
  final double? forcedMax;
  final int yTicks;

  static const _leftGutter = 54.0;
  static const _topGutter = 10.0;
  static const _bottomGutter = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    // The top tick label is centred on plot.top, so leave half a line of room
    // above it or it gets clipped by the panel edge.
    final plot = Rect.fromLTRB(
      _leftGutter,
      _topGutter,
      size.width - 4,
      size.height - _bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    final all = [
      for (final s in series)
        for (final p in s.points) p.v,
    ];
    if (all.isEmpty) return;

    var lo = forcedMin ?? all.reduce(math.min);
    var hi = forcedMax ?? all.reduce(math.max);
    if (forcedMax == null) hi += (hi - lo).abs() * 0.15 + 0.5;
    if (forcedMin == null) lo -= (hi - lo).abs() * 0.05;
    if (hi - lo < 1e-6) hi = lo + 1;

    final sampleEnd = series
        .expand((s) => s.points)
        .map((p) => p.t)
        .reduce(math.max);
    final tEnd = endTime == null
        ? sampleEnd
        : endTime!.millisecondsSinceEpoch / 1000.0;
    final tStart = tEnd - window.inSeconds;
    final tSpan = math.max(tEnd - tStart, 1.0);

    double xOf(double t) =>
        plot.left + ((t - tStart) / tSpan).clamp(0.0, 1.0) * plot.width;
    double yOf(double v) =>
        plot.bottom - ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * plot.height;

    _paintGrid(canvas, plot, lo, hi, xOf);
    for (final s in series) {
      _paintSeries(canvas, plot, s, xOf, yOf);
    }

    // Plot frame last so lines never overdraw it.
    canvas.drawRect(
      plot,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = TC.border
        ..isAntiAlias = false,
    );
  }

  void _paintGrid(
    Canvas canvas,
    Rect plot,
    double lo,
    double hi,
    double Function(double) xOf,
  ) {
    // Every dash is horizontal or vertical: antialiasing has nothing to smooth
    // here, and on the panel it is coverage work llvmpipe does per pixel.
    final dash = Paint()
      ..color = TC.gridLine
      ..strokeWidth = 1
      ..isAntiAlias = false;

    for (var i = 0; i <= yTicks; i++) {
      final f = i / yTicks;
      final y = plot.bottom - f * plot.height;
      _dashedLine(canvas, Offset(plot.left, y), Offset(plot.right, y), dash);
      _label(
        canvas,
        fmtNum(lo + f * (hi - lo), digits: (hi - lo) < 10 ? 1 : 0),
        Offset(plot.left - 5, y),
        align: _Align.right,
      );
    }

    // Four time ticks across the window, labelled relative to now.
    const xTicks = 4;
    for (var i = 0; i <= xTicks; i++) {
      final f = i / xTicks;
      final x = plot.left + f * plot.width;
      if (i > 0 && i < xTicks) {
        _dashedLine(canvas, Offset(x, plot.top), Offset(x, plot.bottom), dash);
      }
      final ago = Duration(seconds: ((1 - f) * window.inSeconds).round());
      _label(
        canvas,
        i == xTicks ? 'now' : fmtAgoShort(ago),
        Offset(x, plot.bottom + 3),
        align: i == 0
            ? _Align.left
            : (i == xTicks ? _Align.rightTop : _Align.centerTop),
      );
    }
  }

  void _paintSeries(
    Canvas canvas,
    Rect plot,
    ChartSeries s,
    double Function(double) xOf,
    double Function(double) yOf,
  ) {
    if (s.points.isEmpty) return;

    // A matrix can contain a real time gap when a target stops exporting. Do
    // not draw a diagonal bridge across it. MetricsStore aims for ~240 points
    // per range, with a 15s floor, so three expected steps is a conservative
    // discontinuity threshold that still tolerates normal scrape jitter.
    final expectedStep = math.max(15.0, window.inSeconds / 240.0);
    final gapThreshold = expectedStep * 3;
    final segments = <(Path, Path)>[];
    Path? path;
    Path? area;
    Offset? last;
    double? previousT;

    void finishSegment() {
      if (path == null || area == null || last == null) return;
      area!.lineTo(last.dx, plot.bottom);
      area!.close();
      segments.add((path!, area!));
      path = null;
      area = null;
    }

    for (final p in s.points) {
      final o = Offset(xOf(p.t), yOf(p.v));
      if (previousT != null && p.t - previousT > gapThreshold) {
        finishSegment();
      }
      if (path == null) {
        path = Path()..moveTo(o.dx, o.dy);
        area = Path()
          ..moveTo(o.dx, plot.bottom)
          ..lineTo(o.dx, o.dy);
      } else {
        path!.lineTo(o.dx, o.dy);
        area!.lineTo(o.dx, o.dy);
      }
      last = o;
      previousT = p.t;
    }
    finishSegment();
    if (last == null) return;

    canvas.save();
    canvas.clipRect(plot);
    for (final (line, fill) in segments) {
      canvas.drawPath(fill, Paint()..color = s.color.withValues(alpha: 0.09));
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..color = s.color,
      );
    }
    canvas.restore();

    // Head marker on the most recent sample, held inside the frame. The newest
    // point sits exactly on plot.right, so a circle centred on it hangs half
    // outside the chart — and this one is drawn after the clip is released,
    // because clipping it would leave a half-moon instead.
    const r = 2.4;
    canvas.drawCircle(
      Offset(
        last.dx.clamp(plot.left + r, plot.right - r),
        last.dy.clamp(plot.top + r, plot.bottom - r),
      ),
      r,
      Paint()..color = s.color,
    );
  }

  /// One `drawPoints` call for the whole dashed run.
  ///
  /// This used to be a `drawLine` per dash: a grid line across a 600px plot is
  /// about 85 of them, and a chart draws eight such lines, so a repaint issued
  /// some 700 separate draw calls before a single sample was plotted. On the
  /// panel that is llvmpipe setting up 700 antialiased rasterisations on a
  /// 1.2 GHz core. The same dashes as one point list cost one.
  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const on = 3.0, off = 4.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    final ends = <Offset>[];
    var t = 0.0;
    while (t < total) {
      final end = math.min(t + on, total);
      ends.add(a + dir * t);
      ends.add(a + dir * end);
      t = end + off;
    }
    canvas.drawPoints(PointMode.lines, ends, paint);
  }

  void _label(Canvas canvas, String text, Offset at, {required _Align align}) {
    // Tick labels repeat across repaints and across the four charts on a
    // screen — `now`, `-6h`, `50` — so lay each string out once.
    // A y-range that drifts mints new strings, so cap the cache rather than
    // let a panel that has been up for a month accumulate them.
    if (_labelCache.length > 128) _labelCache.clear();
    final tp = _labelCache.putIfAbsent(
      text,
      () => TextPainter(
        text: TextSpan(text: text, style: ts(size: TZ.caption, color: TC.dim)),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
    final o = switch (align) {
      _Align.right => Offset(at.dx - tp.width, at.dy - tp.height / 2),
      _Align.left => Offset(at.dx, at.dy),
      _Align.centerTop => Offset(at.dx - tp.width / 2, at.dy),
      _Align.rightTop => Offset(at.dx - tp.width, at.dy),
    };
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.series != series ||
      old.window != window ||
      old.endTime != endTime ||
      old.unit != unit ||
      old.forcedMin != forcedMin ||
      old.forcedMax != forcedMax ||
      old.yTicks != yTicks;
}

enum _Align { right, left, centerTop, rightTop }

/// Laid-out tick labels, keyed by their text. Axis labels come from a small
/// vocabulary — the time ticks repeat exactly, and the value ticks repeat
/// whenever the y-range holds still — so this settles at a few dozen entries
/// on a panel that runs for weeks.
final _labelCache = <String, TextPainter>{};
