import 'dart:math' as math;

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
    this.unit = '',
    this.yMin,
    this.yMax,
    this.yTicks = 4,
    this.emptyMessage = 'NO DATA IN RANGE',
  });

  final List<ChartSeries> series;
  final Duration window;
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
                    Text('─', style: ts(size: TZ.body, color: s.color)),
                    const SizedBox(width: 3),
                    Text(s.label, style: ts(size: TZ.caption, color: TC.mid)),
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
    required this.unit,
    required this.forcedMin,
    required this.forcedMax,
    required this.yTicks,
  });

  final List<ChartSeries> series;
  final Duration window;
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

    final tEnd = series
        .expand((s) => s.points)
        .map((p) => p.t)
        .reduce(math.max);
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
        ..color = TC.border,
    );
  }

  void _paintGrid(
    Canvas canvas,
    Rect plot,
    double lo,
    double hi,
    double Function(double) xOf,
  ) {
    final dash = Paint()
      ..color = TC.gridLine
      ..strokeWidth = 1;

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
      final ago = Duration(
        seconds: ((1 - f) * window.inSeconds).round(),
      );
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
    final path = Path();
    final area = Path();
    var started = false;
    Offset? last;
    for (final p in s.points) {
      final o = Offset(xOf(p.t), yOf(p.v));
      if (!started) {
        path.moveTo(o.dx, o.dy);
        area.moveTo(o.dx, plot.bottom);
        area.lineTo(o.dx, o.dy);
        started = true;
      } else {
        path.lineTo(o.dx, o.dy);
        area.lineTo(o.dx, o.dy);
      }
      last = o;
    }
    if (last == null) return;
    area.lineTo(last.dx, plot.bottom);
    area.close();

    canvas.save();
    canvas.clipRect(plot);
    canvas.drawPath(area, Paint()..color = s.color.withValues(alpha: 0.09));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = s.color,
    );
    canvas.restore();

    // Head marker on the most recent sample.
    canvas.drawCircle(last, 2.4, Paint()..color = s.color);
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const on = 3.0, off = 4.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final end = math.min(t + on, total);
      canvas.drawLine(a + dir * t, a + dir * end, paint);
      t = end + off;
    }
  }

  void _label(Canvas canvas, String text, Offset at, {required _Align align}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: ts(size: TZ.caption, color: TC.dim)),
      textDirection: TextDirection.ltr,
    )..layout();
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
      old.series != series || old.window != window;
}

enum _Align { right, left, centerTop, rightTop }
