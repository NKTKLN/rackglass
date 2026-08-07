import 'package:flutter/widgets.dart';

/// Phosphor-green terminal palette. Everything in the app draws from here so
/// the whole thing reads as one CRT rather than a pile of colored widgets.
abstract final class TC {
  static const bg = Color(0xFF03070A);
  static const panelBg = Color(0xFF060D0B);
  static const gridLine = Color(0xFF0E2418);
  static const border = Color(0xFF17422C);
  static const borderLit = Color(0xFF2E8055);

  static const dim = Color(0xFF2C6244);
  static const mid = Color(0xFF3E9C68);
  static const fg = Color(0xFF52E28C);
  static const bright = Color(0xFFB4FFD1);

  static const cyan = Color(0xFF46D9D2);
  static const amber = Color(0xFFFFB020);
  static const red = Color(0xFFFF4B3E);
  static const magenta = Color(0xFFC97BFF);
  static const blue = Color(0xFF5AA9FF);
  static const pink = Color(0xFFFF7BAC);

  /// Series colors for multi-line charts, in assignment order.
  static const series = <Color>[fg, cyan, amber, magenta, blue, pink];

  static Color seriesAt(int i) => series[i % series.length];

  /// Percentage-style severity: green under 75, amber to 90, red above.
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

const kFont = 'JetBrainsMono';

/// Monospace text style with an optional phosphor bloom.
TextStyle ts({
  double size = 12,
  Color color = TC.fg,
  FontWeight weight = FontWeight.w400,
  double glow = 0,
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
    shadows: glow > 0
        ? [Shadow(color: color.withValues(alpha: 0.55), blurRadius: glow)]
        : null,
  );
}
