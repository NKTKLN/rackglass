import 'package:flutter/widgets.dart';

import '../theme.dart';
import '../util.dart';

/// Number of monospace cells that fit in [maxWidth] at [size], capped by
/// [want] when the caller asked for a specific length.
///
/// Gauges must never be clipped: the newest sample sits at the right-hand end,
/// so a cell that does not fit is not cosmetic loss — it silently drops the
/// most recent reading and leaves an older one looking current.
int _cellsFor(double maxWidth, double size, int? want) {
  // An unbounded box carries no information about how long the gauge should
  // be. Silently falling back to one cell is how a strip ends up a single
  // block next to an Expanded sibling that ate the row, so say so loudly.
  assert(
    maxWidth.isFinite || want != null,
    'a gauge with an unbounded width needs an explicit width cap — wrap it in '
    'an Expanded/SizedBox, or pass width:',
  );
  final advance = _cell(size).width;
  if (advance <= 0 || !maxWidth.isFinite) return want ?? 8;
  final fits = (maxWidth / advance).floor();
  final n = want == null ? fits : (fits < want ? fits : want);
  return n < 1 ? 1 : n;
}

/// Size of one `█` at [size], measured once per size and kept.
///
/// This is a constant of the font and the size, but working it out means laying
/// out a glyph, and every bar and every sparkline used to do that on every
/// build — twice, in the bar's case, once to count the cells and once to size
/// the canvas. On the panel, where llvmpipe draws the whole interface on the
/// CPU, that shaping work sat directly in the scroll frame budget.
Size _cell(double size) {
  final hit = _cellCache[size];
  if (hit != null) return hit;
  final probe = TextPainter(
    text: TextSpan(text: '█', style: ts(size: size)),
    textDirection: TextDirection.ltr,
  )..layout();
  return _cellCache[size] = Size(probe.width, probe.height);
}

/// Keyed by font size, of which this app uses six.
final _cellCache = <double, Size>{};

/// A bar drawn as rectangles, sized to the monospace grid it sits on.
///
/// It used to be text — a run of `█` with `░` behind it — which looked right in
/// a terminal and wrong on the panel. Two separate faults came from that: the
/// shade glyph washed out to invisible at 16px, and a run of full blocks does
/// not tile seamlessly, because each glyph lands on its own rounded pixel
/// boundary and leaves hairline seams at irregular intervals. Painting the two
/// rectangles directly removes both, keeps the exact same shape, and gives the
/// fill sub-pixel width instead of eighth-of-a-cell steps.
///
/// Sizes itself to the space it is given; [width] caps that in cells rather
/// than forcing it, so a bar can never render wider than its box.
class BarGauge extends StatelessWidget {
  const BarGauge({
    super.key,
    required this.pct,
    this.width,
    this.size = TZ.body,
    this.color,
  });

  final double? pct;
  final int? width;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? TC.forPct(pct);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = _cell(size);
        final cells = _cellsFor(constraints.maxWidth, size, width);
        return CustomPaint(
          size: Size(cells * cell.width, cell.height),
          painter: _BarPainter(pct: pct, fill: c, track: TC.barTrack),
        );
      },
    );
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter({
    required this.pct,
    required this.fill,
    required this.track,
  });

  final double? pct;
  final Color fill;
  final Color track;

  /// Fraction of the line box the bar occupies, so it carries about the weight
  /// a row of block characters did and sits on the same baseline as the text
  /// beside it.
  static const _weight = 0.72;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height * _weight;
    final top = (size.height - h) / 2;
    // Both rectangles are axis-aligned, so antialiasing has no edge to smooth
    // and only costs the panel's software rasteriser coverage work per pixel.
    final fillPaint = Paint()
      ..color = fill
      ..isAntiAlias = false;
    final trackPaint = Paint()
      ..color = track
      ..isAntiAlias = false;

    // No reading is not the same as a zero reading, and an empty track would
    // say the second. A rule through the middle says there is nothing to draw.
    if (pct == null) {
      canvas.drawRect(
        Rect.fromLTWH(0, size.height / 2 - 0.5, size.width, 1),
        trackPaint,
      );
      return;
    }

    canvas.drawRect(Rect.fromLTWH(0, top, size.width, h), trackPaint);
    final filled = (pct!.clamp(0, 100) / 100) * size.width;
    if (filled > 0) {
      canvas.drawRect(Rect.fromLTWH(0, top, filled, h), fillPaint);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.pct != pct || old.fill != fill || old.track != track;
}

/// Inline `▁▂▃▅▇` history strip, newest sample on the right.
///
/// Like [BarGauge] it fits itself to the available width; [width] is a cap.
class SparkText extends StatelessWidget {
  const SparkText({
    super.key,
    required this.values,
    this.width,
    this.size = TZ.body,
    this.color = TC.dim,
    this.min,
    this.max,
  });

  /// A strip on the same fixed 0-100 scale the bar gauges use, so a reading and
  /// its history never contradict each other on screen.
  const SparkText.percent({
    super.key,
    required this.values,
    this.width,
    this.size = TZ.body,
    this.color = TC.dim,
  }) : min = 0,
       max = 100;

  final List<double?> values;
  final int? width;
  final double size;
  final Color color;
  final double? min;
  final double? max;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        sparkText(
          values,
          _cellsFor(constraints.maxWidth, size, width),
          min: min,
          max: max,
        ),
        style: ts(size: size, color: color, height: 1.0),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    );
  }
}

/// Label on the left, value on the right. The label lives in an [Expanded] and
/// ellipsizes, so it can never run into the value however long it gets.
class StatLine extends StatelessWidget {
  const StatLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = TC.bright,
    this.contextColor = TC.mid,
    this.labelColor = TC.dim,
    this.size = TZ.small,
    this.trailing,
    this.emphasis = true,
  });

  final String label;
  final String value;
  final Color valueColor;

  /// Colour a non-emphasis line uses. The default is the grey the CPU panel
  /// gives its load average; a panel whose readings have gone stale overrides
  /// it so its context lines dim with everything else.
  final Color contextColor;
  final Color labelColor;
  final double size;
  final Widget? trailing;

  /// Values read brighter and heavier than their labels by default. Turn it
  /// off for figures that are context rather than a reading you act on: those
  /// drop to [contextColor] at normal weight, and [valueColor] is ignored — a
  /// line that is context does not get to carry severity as well.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: ts(size: size, color: labelColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: ts(
            size: size,
            color: emphasis ? valueColor : contextColor,
            weight: emphasis ? FontWeight.w500 : FontWeight.w400,
          ),
          maxLines: 1,
          softWrap: false,
        ),
        if (trailing != null) ...[const SizedBox(width: 6), trailing!],
      ],
    );
  }
}

/// The one big number in a panel. Scales itself down rather than colliding with
/// whatever sits beside it.
class BigReading extends StatelessWidget {
  const BigReading({
    super.key,
    required this.value,
    required this.unit,
    required this.color,
    this.caption,
    this.size = TZ.huge,
  });

  final String value;
  final String unit;
  final Color color;
  final String? caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: ts(
                  size: size,
                  color: color,
                  weight: FontWeight.w700,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: ts(size: size * 0.45, color: color),
              ),
            ],
          ),
        ),
        if (caption != null)
          Text(
            caption!,
            style: ts(size: TZ.caption, color: TC.dim),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// Small `●`/`○` target-state dot.
class StateDot extends StatelessWidget {
  const StateDot(this.up, {super.key, this.size = TZ.body});

  final bool up;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      up ? '●' : '○',
      style: ts(size: size, color: up ? TC.green : TC.red, height: 1.0),
    );
  }
}

/// Renders a value that may be missing, so `--` never gets mistaken for `0`.
class MaybeText extends StatelessWidget {
  const MaybeText(
    this.text, {
    super.key,
    this.present = true,
    this.size = TZ.body,
    this.color = TC.bright,
    this.weight = FontWeight.w400,
    this.align = TextAlign.left,
  });

  final String text;
  final bool present;
  final double size;
  final Color color;
  final FontWeight weight;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Text(
      present ? text : '--',
      textAlign: align,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: ts(size: size, color: present ? color : TC.dim, weight: weight),
    );
  }
}
