/// Formatting helpers. Every number that reaches the screen goes through one of
/// these so column widths stay stable between polls and nothing jitters.
library;

const _eighths = ['', '▏', '▎', '▍', '▌', '▋', '▊', '▉'];
const _sparkChars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

/// A `████████▌░░░░░░` style bar with sub-cell resolution.
String barText(double? pct, int width) {
  if (pct == null) return '·' * width;
  final f = (pct.clamp(0, 100) / 100) * width;
  final full = f.floor();
  final rem = ((f - full) * 8).floor();
  final partial = full < width ? _eighths[rem] : '';
  final used = full + (partial.isEmpty ? 0 : 1);
  return '█' * full + partial + '░' * (width - used).clamp(0, width);
}

/// Inline sparkline from a value series.
///
/// [min] and [max] pin the scale. Leave them out and the strip autoscales to
/// the window, which puts the largest sample at full height *by construction* —
/// a CPU idling at 12% then draws a solid wall. Pin the scale whenever an
/// absolute reading sits next to the strip, or the two disagree on screen.
///
/// Under three samples there is no shape to draw yet — a lone block would read
/// as a spike — so the strip stays an empty dotted track until history builds.
String sparkText(List<double> values, int width, {double? min, double? max}) {
  if (values.length < 3) return '·' * width;
  final tail = values.length > width
      ? values.sublist(values.length - width)
      : values;
  var lo = min ?? tail.reduce((a, b) => a < b ? a : b);
  var hi = max ?? tail.reduce((a, b) => a > b ? a : b);
  if (hi - lo < 1e-9) {
    lo -= 0.5;
    hi += 0.5;
  }
  final body = tail
      .map((v) {
        final n = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
        return _sparkChars[(n * (_sparkChars.length - 1)).round()];
      })
      .join();
  // Pad with the same dots as the empty state so a short history reads as a
  // partly-filled track rather than as a floating fragment.
  return body.padLeft(width, '·');
}

/// Binary-prefix bytes, fixed to 4 significant-ish chars: `15.1G`, `937M`.
String fmtBytes(double? b, {int digits = 1}) {
  if (b == null || b.isNaN) return '--';
  const units = ['B', 'K', 'M', 'G', 'T', 'P'];
  var v = b.abs();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final d = v >= 100 ? 0 : digits;
  return '${(b.isNegative ? -v : v).toStringAsFixed(d)}${units[i]}';
}

/// Decimal-prefix rate, for network throughput.
String fmtRate(double? bytesPerSec) {
  if (bytesPerSec == null || bytesPerSec.isNaN) return '--';
  const units = ['B', 'K', 'M', 'G'];
  var v = bytesPerSec.abs();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)}${units[i]}/s';
}

String fmtPct(double? p, {int digits = 1}) =>
    p == null || p.isNaN ? '--' : '${p.clamp(0, 100).toStringAsFixed(digits)}%';

String fmtTemp(double? c, {int digits = 1}) =>
    c == null || c.isNaN ? '--' : '${c.toStringAsFixed(digits)}°C';

String fmtNum(double? v, {int digits = 2}) =>
    v == null || v.isNaN ? '--' : v.toStringAsFixed(digits);

/// Compact duration: `46h 7m`, `2d 3h`, `12m 4s`.
String fmtDuration(Duration? d) {
  if (d == null) return '--';
  final s = d.inSeconds.abs();
  if (s >= 86400) return '${s ~/ 86400}d ${(s % 86400) ~/ 3600}h';
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  if (s >= 60) return '${s ~/ 60}m ${s % 60}s';
  return '${s}s';
}

String two(int v) => v.toString().padLeft(2, '0');

String fmtClock(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

String fmtDate(DateTime t) =>
    '${t.year}-${two(t.month)}-${two(t.day)} ${fmtClock(t)}';

/// Axis/legend label for a chart time offset relative to now.
String fmtAgoShort(Duration d) {
  final s = d.inSeconds;
  if (s >= 86400) return '-${(s / 86400).toStringAsFixed(0)}d';
  if (s >= 3600) return '-${(s / 3600).toStringAsFixed(0)}h';
  if (s >= 60) return '-${(s / 60).toStringAsFixed(0)}m';
  return '-${s}s';
}
