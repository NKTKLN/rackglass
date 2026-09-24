//! Small, deliberately boring formatters. Stable widths keep polls from jittering.
use chrono::{DateTime, Datelike, Local, TimeDelta, Timelike};
const EIGHTHS: [&str; 8] = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];
const SPARK: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
/// Filled part and track can be coloured separately. Solid blocks survive the
/// little panel; a shaded track washed out until it was almost invisible.
pub fn bar_cells(pct: Option<f64>, width: usize) -> (String, String) {
    let Some(pct) = pct else {
        return (String::new(), "·".repeat(width));
    };
    let pct = if pct.is_nan() { 100.0 } else { pct };
    let f = pct.clamp(0.0, 100.0) / 100.0 * width as f64;
    let full = f.floor() as usize;
    let partial = if full < width {
        EIGHTHS[((f - full as f64) * 8.0).floor() as usize]
    } else {
        ""
    };
    let used = full + usize::from(!partial.is_empty());
    (
        format!("{}{partial}", "█".repeat(full)),
        "█".repeat(width.saturating_sub(used)),
    )
}
/// Pin the scale beside an absolute reading: autoscaling makes even idle CPU a
/// wall. Under three real samples there is no shape yet, only an empty track.
pub fn spark_text(
    values: &[Option<f64>],
    width: usize,
    min: Option<f64>,
    max: Option<f64>,
) -> String {
    let tail = &values[values.len().saturating_sub(width)..];
    let valid: Vec<f64> = tail
        .iter()
        .copied()
        .flatten()
        .filter(|v| !v.is_nan())
        .collect();
    if valid.len() < 3 {
        return "·".repeat(width);
    }
    let mut lo = min.unwrap_or_else(|| valid.iter().copied().reduce(f64::min).unwrap());
    let mut hi = max.unwrap_or_else(|| valid.iter().copied().reduce(f64::max).unwrap());
    if hi - lo < 1e-9 {
        lo -= 0.5;
        hi += 0.5;
    }
    let body: String = tail
        .iter()
        .map(|v| match v {
            Some(v) if !v.is_nan() => {
                let n = (v - lo) / (hi - lo);
                let n = if n.is_nan() { 1.0 } else { n.clamp(0.0, 1.0) };
                SPARK[(n * 7.0).round() as usize]
            }
            _ => '·',
        })
        .collect();
    format!("{}{body}", "·".repeat(width - tail.len()))
}
// Dart rounds exact halfway values away from zero; Rust uses ties-to-even.
// Test the binary significand, not a rounded multiplication by 10^digits:
// 2.55 * 10 rounds to 25.5 even though 2.55 itself lies just below the tie.
fn fixed(v: f64, digits: usize) -> String {
    assert!(digits <= 100, "fraction digits must be between 0 and 100");
    if v.is_infinite() {
        return if v.is_sign_negative() {
            "-Infinity"
        } else {
            "Infinity"
        }
        .into();
    }
    if v.abs() >= 1e21 {
        let text = format!("{v:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap();
        return format!("{mantissa}e+{exponent}");
    }
    let bits = v.abs().to_bits();
    let biased = ((bits >> 52) & 0x7ff) as i32;
    let mantissa = (bits & ((1_u64 << 52) - 1)) | if biased == 0 { 0 } else { 1_u64 << 52 };
    let exponent = if biased == 0 {
        -1074
    } else {
        biased - 1023 - 52
    };
    let halfway =
        mantissa != 0 && exponent + mantissa.trailing_zeros() as i32 + digits as i32 == -1;
    let rounded = if halfway {
        if v.is_sign_negative() {
            v.next_down()
        } else {
            v.next_up()
        }
    } else {
        v
    };
    format!("{rounded:.digits$}")
}
/// Binary-prefix bytes, fixed to four significant-ish characters.
pub fn fmt_bytes(b: Option<f64>, digits: usize) -> String {
    let Some(b) = b.filter(|v| !v.is_nan()) else {
        return "--".into();
    };
    let units = ["B", "K", "M", "G", "T", "P"];
    let mut v = b.abs();
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!(
        "{}{}",
        fixed(
            if b.is_sign_negative() { -v } else { v },
            if v >= 100.0 { 0 } else { digits }
        ),
        units[i]
    )
}
/// Decimal-prefix rate, for network throughput (magnitude, as in Dart).
pub fn fmt_rate(b: Option<f64>) -> String {
    let Some(b) = b.filter(|v| !v.is_nan()) else {
        return "--".into();
    };
    let units = ["B", "K", "M", "G"];
    let mut v = b.abs();
    let mut i = 0;
    while v >= 1000.0 && i < units.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    format!(
        "{}{}/s",
        fixed(v, if v >= 100.0 || i == 0 { 0 } else { 1 }),
        units[i]
    )
}
pub fn fmt_pct(p: Option<f64>, digits: usize) -> String {
    p.filter(|p| !p.is_nan())
        .map(|p| {
            format!(
                "{}%",
                fixed(if p <= 0.0 { 0.0 } else { p.min(100.0) }, digits)
            )
        })
        .unwrap_or("--".into())
}
pub fn fmt_temp(c: Option<f64>, digits: usize) -> String {
    c.filter(|c| !c.is_nan())
        .map(|c| format!("{}°C", fixed(c, digits)))
        .unwrap_or("--".into())
}
pub fn fmt_num(v: Option<f64>, digits: usize) -> String {
    v.filter(|v| !v.is_nan())
        .map(|v| fixed(v, digits))
        .unwrap_or("--".into())
}
/// Compact duration, taking the magnitude even for a future boot timestamp.
pub fn fmt_duration(d: Option<TimeDelta>) -> String {
    let Some(d) = d else {
        return "--".into();
    };
    let s = d.num_seconds().unsigned_abs();
    if s >= 86400 {
        format!("{}d {}h", s / 86400, s % 86400 / 3600)
    } else if s >= 3600 {
        format!("{}h {}m", s / 3600, s % 3600 / 60)
    } else if s >= 60 {
        format!("{}m {}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}
pub fn two(v: i64) -> String {
    format!("{v:0>2}")
}
/// Seconds stay in: a ticking clock is cheap proof the panel has not frozen.
pub fn fmt_clock(t: DateTime<Local>) -> String {
    let h = t.hour() % 12;
    format!(
        "{}:{:02}:{:02} {}",
        if h == 0 { 12 } else { h },
        t.minute(),
        t.second(),
        if t.hour() < 12 { "AM" } else { "PM" }
    )
}
pub fn fmt_date(t: DateTime<Local>) -> String {
    format!(
        "{}-{:02}-{:02} {}",
        t.year(),
        t.month(),
        t.day(),
        fmt_clock(t)
    )
}
pub fn fmt_ago_short(d: TimeDelta) -> String {
    let s = d.num_seconds();
    if s >= 86400 {
        format!("-{}d", fixed(s as f64 / 86400.0, 0))
    } else if s >= 3600 {
        format!("-{}h", fixed(s as f64 / 3600.0, 0))
    } else if s >= 60 {
        format!("-{}m", fixed(s as f64 / 60.0, 0))
    } else {
        format!("-{s}s")
    }
}
