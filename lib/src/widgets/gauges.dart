import 'package:flutter/widgets.dart';

import '../theme.dart';
import '../util.dart';

/// `████████▌░░░░░░` bar rendered as text, so it stays on the monospace grid.
class BarGauge extends StatelessWidget {
  const BarGauge({
    super.key,
    required this.pct,
    this.width = 16,
    this.size = 12,
    this.color,
    this.glow = 4,
  });

  final double? pct;
  final int width;
  final double size;
  final Color? color;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final c = color ?? TC.forPct(pct);
    final text = barText(pct, width);
    // barText always emits fill first, then track, so one split colors both.
    final cut = text.indexOf(RegExp(r'[░·]'));
    final fill = cut < 0 ? text : text.substring(0, cut);
    final track = cut < 0 ? '' : text.substring(cut);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: fill, style: ts(size: size, color: c, glow: glow)),
          TextSpan(text: track, style: ts(size: size, color: TC.gridLine)),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// Inline `▁▂▃▅▇` history strip.
class SparkText extends StatelessWidget {
  const SparkText({
    super.key,
    required this.values,
    this.width = 14,
    this.size = 12,
    this.color = TC.dim,
    this.min,
    this.max,
  });

  final List<double> values;
  final int width;
  final double size;
  final Color color;
  final double? min;
  final double? max;

  @override
  Widget build(BuildContext context) {
    return Text(
      sparkText(values, width, min: min, max: max),
      style: ts(size: size, color: color, height: 1.0),
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// Label + value pair on one line, with the label left and value right.
class StatLine extends StatelessWidget {
  const StatLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = TC.bright,
    this.labelColor = TC.dim,
    this.size = 12,
    this.trailing,
    this.glow = 0,
  });

  final String label;
  final String value;
  final Color valueColor;
  final Color labelColor;
  final double size;
  final Widget? trailing;
  final double glow;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: ts(size: size, color: labelColor)),
        const Spacer(),
        Text(
          value,
          style: ts(
            size: size,
            color: valueColor,
            weight: FontWeight.w500,
            glow: glow,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 6), trailing!],
      ],
    );
  }
}

/// The one big number in a panel — CPU package temp, GPU temp.
class BigReading extends StatelessWidget {
  const BigReading({
    super.key,
    required this.value,
    required this.unit,
    required this.color,
    this.caption,
    this.size = 38,
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: ts(
                size: size,
                color: color,
                weight: FontWeight.w700,
                glow: 12,
                height: 1.0,
              ),
            ),
            const SizedBox(width: 3),
            Text(unit, style: ts(size: size * 0.42, color: color, glow: 5)),
          ],
        ),
        if (caption != null)
          Text(caption!, style: ts(size: 10, color: TC.dim)),
      ],
    );
  }
}

/// Small `●`/`○` target-state dot.
class StateDot extends StatelessWidget {
  const StateDot(this.up, {super.key, this.size = 12});

  final bool up;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      up ? '●' : '○',
      style: ts(
        size: size,
        color: up ? TC.fg : TC.red,
        glow: up ? 6 : 8,
        height: 1.0,
      ),
    );
  }
}

/// Renders a value that may be missing, so `--` never gets mistaken for `0`.
class MaybeText extends StatelessWidget {
  const MaybeText(
    this.text, {
    super.key,
    this.present = true,
    this.size = 12,
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
      style: ts(
        size: size,
        color: present ? color : TC.dim,
        weight: weight,
      ),
    );
  }
}
