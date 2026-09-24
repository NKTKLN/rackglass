use chrono::{Local, TimeDelta, TimeZone};
use rackglass::fmt::*;
fn spark(values: &[f64], width: usize, min: Option<f64>, max: Option<f64>) -> String {
    spark_text(
        &values.iter().copied().map(Some).collect::<Vec<_>>(),
        width,
        min,
        max,
    )
}
#[test]
fn steady_cpu_fixed_scale_reads_low() {
    assert_eq!(
        spark(
            &[11.8, 12.0, 12.3, 11.9, 12.1, 12.0],
            6,
            Some(0.0),
            Some(100.0)
        ),
        "▂▂▂▂▂▂"
    );
}
#[test]
fn autoscale_pins_maximum_to_top() {
    assert!(spark(&[11.8, 12.0, 12.3, 11.9, 12.1, 12.0], 6, Some(0.0), None).contains('█'));
}
#[test]
fn real_load_has_shape_on_fixed_scale() {
    assert_eq!(
        spark(&[5.0, 30.0, 60.0, 95.0], 4, Some(0.0), Some(100.0)),
        "▁▃▅█"
    );
}
#[test]
fn fixed_scale_clamps() {
    assert_eq!(spark(&[0.0, 50.0, 140.0], 3, Some(0.0), Some(100.0)), "▁▅█");
}
#[test]
fn temperature_noise_stays_flat() {
    assert_eq!(
        spark(&[43.2, 43.6, 43.4, 43.5, 43.3], 5, Some(20.0), Some(100.0)),
        "▃▃▃▃▃"
    );
}
#[test]
fn too_few_samples_stays_empty() {
    assert_eq!(spark(&[12.0, 12.0], 6, Some(0.0), Some(100.0)), "······");
    assert_eq!(spark_text(&[], 3, None, None), "···");
    assert_eq!(
        spark_text(&[Some(1.0), Some(2.0), None], 3, None, None),
        "···"
    );
}
#[test]
fn gaps_remain_gaps() {
    assert_eq!(
        spark_text(
            &[Some(10.0), Some(20.0), None, Some(30.0), Some(40.0)],
            5,
            Some(0.0),
            Some(100.0)
        ),
        "▂▂·▃▄"
    );
}
#[test]
fn tail_padding_constant_and_nan() {
    assert_eq!(spark(&[1.0, 1.0, 1.0], 5, None, None), "··▅▅▅");
    assert_eq!(
        spark(&[90.0, 0.0, 50.0, 100.0], 3, Some(0.0), Some(100.0)),
        "▁▅█"
    );
    assert_eq!(
        spark_text(
            &[Some(0.0), Some(f64::NAN), Some(50.0), Some(100.0)],
            4,
            Some(0.0),
            Some(100.0)
        ),
        "▁·▅█"
    );
    assert_eq!(spark(&[1.0, 2.0, 3.0], 0, None, None), "");
}
#[test]
fn bars_have_exact_subcells_and_solid_track() {
    for (p, w, fill, track) in [
        (None, 3, "", "···"),
        (Some(0.0), 4, "", "████"),
        (Some(100.0), 4, "████", ""),
        (Some(12.5), 4, "▌", "███"),
        (Some(37.5), 4, "█▌", "██"),
        (Some(-1.0), 2, "", "██"),
        (Some(150.0), 2, "██", ""),
        (Some(50.0), 0, "", ""),
    ] {
        assert_eq!(bar_cells(p, w), (fill.into(), track.into()));
    }
}
#[test]
fn bytes_binary_and_rate_decimal() {
    for (v, w) in [
        (0.0, "0.0B"),
        (1024.0, "1.0K"),
        (1048576.0, "1.0M"),
        (1073741824.0, "1.0G"),
        (1099511627776.0, "1.0T"),
        (1125899906842624.0, "1.0P"),
        (937.0 * 1048576.0, "937M"),
        (-1536.0, "-1.5K"),
    ] {
        assert_eq!(fmt_bytes(Some(v), 1), w);
    }
    assert_eq!(fmt_bytes(Some(1536.0), 2), "1.50K");
    assert_eq!(fmt_bytes(None, 1), "--");
    assert_eq!(fmt_bytes(Some(f64::NAN), 1), "--");
    for (v, w) in [
        (0.0, "0B/s"),
        (999.0, "999B/s"),
        (1000.0, "1.0K/s"),
        (5574.87, "5.6K/s"),
        (1103.31, "1.1K/s"),
        (-1234.0, "1.2K/s"),
        (100000.0, "100K/s"),
        (1e6, "1.0M/s"),
        (1e9, "1.0G/s"),
    ] {
        assert_eq!(fmt_rate(Some(v)), w);
    }
    assert_eq!(fmt_rate(None), "--");
    assert_eq!(fmt_rate(Some(f64::NAN)), "--");
}
#[test]
fn percent_temperature_and_numbers() {
    assert_eq!(fmt_pct(Some(123.0), 1), "100.0%");
    assert_eq!(fmt_pct(Some(-1.0), 0), "0%");
    assert_eq!(fmt_pct(Some(12.345), 2), "12.35%");
    assert_eq!(fmt_pct(None, 1), "--");
    assert_eq!(fmt_pct(Some(f64::NAN), 1), "--");
    assert_eq!(fmt_temp(Some(43.375), 1), "43.4°C");
    assert_eq!(fmt_temp(Some(-5.0), 0), "-5°C");
    assert_eq!(fmt_temp(None, 1), "--");
    assert_eq!(fmt_num(Some(3.0), 2), "3.00");
    assert_eq!(fmt_num(Some(2.5), 0), "3");
    assert_eq!(fmt_num(Some(-2.5), 0), "-3");
    assert_eq!(fmt_num(None, 2), "--");
    assert_eq!(fmt_num(Some(f64::INFINITY), 2), "Infinity");
}
#[test]
fn compact_durations_and_ago_labels() {
    assert_eq!(fmt_duration(None), "--");
    for (s, w) in [
        (0, "0s"),
        (59, "59s"),
        (60, "1m 0s"),
        (724, "12m 4s"),
        (3600, "1h 0m"),
        (166020, "1d 22h"),
        (183600, "2d 3h"),
        (-724, "12m 4s"),
    ] {
        assert_eq!(fmt_duration(Some(TimeDelta::seconds(s))), w);
    }
    for (s, w) in [
        (0, "-0s"),
        (59, "-59s"),
        (60, "-1m"),
        (90, "-2m"),
        (3600, "-1h"),
        (5400, "-2h"),
        (86400, "-1d"),
        (129600, "-2d"),
        (-5, "--5s"),
    ] {
        assert_eq!(fmt_ago_short(TimeDelta::seconds(s)), w);
    }
}
#[test]
fn local_clock_date_and_two_digits() {
    let t = Local
        .with_ymd_and_hms(2026, 9, 24, 18, 5, 52)
        .single()
        .unwrap();
    assert_eq!(fmt_clock(t), "6:05:52 PM");
    assert_eq!(fmt_date(t), "2026-09-24 6:05:52 PM");
    assert_eq!(
        fmt_clock(
            Local
                .with_ymd_and_hms(2026, 1, 2, 0, 0, 1)
                .single()
                .unwrap()
        ),
        "12:00:01 AM"
    );
    assert_eq!(
        fmt_clock(
            Local
                .with_ymd_and_hms(2026, 1, 2, 12, 0, 0)
                .single()
                .unwrap()
        ),
        "12:00:00 PM"
    );
    assert_eq!(two(1), "01");
    assert_eq!(two(100), "100");
}
#[test]
fn dart_binary_rounding_negative_zero_and_large_numbers() {
    // Captured directly from lib/src/util.dart, not decimal arithmetic guesses.
    for (v, d, w) in [
        (2.55, 1, "2.5"),
        (2.35, 1, "2.4"),
        (1.005, 2, "1.00"),
        (12.345, 2, "12.35"),
        (0.125, 2, "0.13"),
        (-0.125, 2, "-0.13"),
        (-0.0, 0, "-0"),
        (-0.0, 2, "-0.00"),
        (1e21, 2, "1e+21"),
        (1e22, 1, "1e+22"),
    ] {
        assert_eq!(fmt_num(Some(v), d), w);
    }
    assert_eq!(bar_cells(Some(f64::NAN), 4), ("████".into(), "".into()));
}
#[test]
fn dart_negative_zero_pct_and_infinite_spark_scale() {
    assert_eq!(fmt_pct(Some(-0.0), 1), "0.0%");
    assert_eq!(spark(&[f64::INFINITY, 0.0, 1.0], 3, None, None), "█▁▁");
    assert_eq!(spark(&[f64::INFINITY; 3], 3, None, None), "███");
}
