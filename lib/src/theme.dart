import 'package:flutter/widgets.dart';

/// Plain Linux console palette: black background, grey-white text, ANSI colors
/// used only to carry meaning. No phosphor wash, no bloom.
abstract final class TC {
  static const bg = Color(0xFF000000);
  static const panelBg = Color(0xFF000000);

  static const gridLine = Color(0xFF2E2E2E);

  /// Unfilled part of a bar gauge — visible enough that a 0% bar still reads
  /// as an empty gauge rather than as nothing at all.
  static const barTrack = Color(0xFF3C3C3C);
  static const border = Color(0xFF565656);
  static const borderLit = Color(0xFFC8C8C8);

  static const dim = Color(0xFF8A8A8A);
  static const mid = Color(0xFFAFAFAF);
  static const fg = Color(0xFFD4D4D4);
  static const bright = Color(0xFFFFFFFF);

  // ANSI accents. These appear only where they mean something: state, severity
  // and chart series identity.
  static const green = Color(0xFF4EC94E);
  static const cyan = Color(0xFF3FC7C7);
  static const amber = Color(0xFFD7B733);
  static const red = Color(0xFFE05A4F);
  static const magenta = Color(0xFFBE72C8);
  static const blue = Color(0xFF6E90D8);

  /// Series colors for multi-line charts, in assignment order.
  static const series = <Color>[fg, cyan, amber, magenta, blue, green];

  static Color seriesAt(int i) => series[i % series.length];

  /// Percentage severity: normal text under 75, yellow to 90, red above.
  static Color forPct(double? pct) {
    if (pct == null) return dim;
    if (pct >= 90) return red;
    if (pct >= 75) return amber;
    return fg;
  }

  /// Temperature severity. Defaults suit a desktop CPU; GPUs run hotter, so
  /// callers pass their own thresholds.
  static Color forTemp(double? c, {double warn = 70, double crit = 85}) {
    if (c == null) return dim;
    if (c >= crit) return red;
    if (c >= warn) return amber;
    return fg;
  }
}

/// Type scale for a 7" 1024x600 panel — roughly 170 DPI, viewed at arm's
/// length. A real Linux console on this panel runs an 8x16 font; nothing here
/// goes below that, because below it the glyphs stop being readable.
abstract final class TZ {
  /// Column headers and captions. The floor.
  static const caption = 13.0;

  /// Secondary detail lines.
  static const small = 14.0;

  /// Default body text and table cells.
  static const body = 16.0;

  /// Emphasis inside a panel.
  static const large = 18.0;

  /// Screen title.
  static const title = 20.0;

  /// The one big number per panel.
  static const huge = 40.0;

  /// Fixed band for temperature sparklines, in Celsius. Wide enough to cover a
  /// cold idle and a throttling die, so the strip reports the real level
  /// instead of magnifying sensor noise.
  static const tempFloor = 20.0;
  static const tempCeiling = 100.0;
}

const kFont = 'JetBrainsMono';

/// Monospace text style. Flat — no shadows anywhere in this app.
TextStyle ts({
  double size = TZ.body,
  Color color = TC.fg,
  FontWeight weight = FontWeight.w400,
  double? height,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: kFont,
    fontSize: size,
    color: color,
    fontWeight: weight,
    height: height,
    letterSpacing: letterSpacing,
  );
}
