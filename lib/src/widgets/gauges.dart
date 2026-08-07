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
  final probe = TextPainter(
    text: TextSpan(text: '█', style: ts(size: size)),
    textDirection: TextDirection.ltr,
  )..layout();
  final advance = probe.width;
  if (advance <= 0 || !maxWidth.isFinite) return want ?? 8;
  final fits = (maxWidth / advance).floor();
  final n = want == null ? fits : (fits < want ? fits : want);
  return n < 1 ? 1 : n;
}

/// `████████▌░░░░░░` bar rendered as text, so it stays on the monospace grid.
///
/// Sizes itself to the space it is given; [width] caps that rather than forcing
/// it, so a bar can never render wider than its box.
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
        final text = barText(pct, _cellsFor(constraints.maxWidth, size, width));
        // barText always emits fill first, then track, so one split colors both.
        final cut = text.indexOf(RegExp(r'[░·]'));
        final fill = cut < 0 ? text : text.substring(0, cut);
        final track = cut < 0 ? '' : text.substring(cut);
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: fill, style: ts(size: size, color: c)),
              TextSpan(text: track, style: ts(size: size, color: TC.barTrack)),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        );
      },
    );
  }
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

  final List<double> values;
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
    this.labelColor = TC.dim,
    this.size = TZ.small,
    this.trailing,
  });

  final String label;
  final String value;
  final Color valueColor;
  final Color labelColor;
  final double size;
  final Widget? trailing;

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
          style: ts(size: size, color: valueColor, weight: FontWeight.w500),
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
              Text(unit, style: ts(size: size * 0.45, color: color)),
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
      style: ts(
        size: size,
        color: present ? color : TC.dim,
        weight: weight,
      ),
    );
  }
}
