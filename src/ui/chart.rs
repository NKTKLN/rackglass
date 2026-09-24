//! Rasterise only the plot. Axis and legend glyphs remain ordinary Slint Text.
use super::{Ink, scene::*};
use crate::{
    fmt::{fmt_ago_short, fmt_num},
    prom::client::PromPoint,
};
use chrono::TimeDelta;
use slint::{Image, Rgba8Pixel, SharedPixelBuffer};
use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
};
use tiny_skia::{Paint, PathBuilder, Pixmap, Stroke, Transform};

#[derive(Clone, Debug)]
pub struct Series {
    pub label: String,
    pub points: Vec<PromPoint>,
    pub color: u32,
}
#[derive(Clone, Debug)]
pub struct Chart {
    pub series: Vec<Series>,
    pub window: u64,
    pub end: f64,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub unit: String,
    pub empty: String,
}
impl Default for Chart {
    fn default() -> Self {
        Self {
            series: vec![],
            window: 3600,
            end: 0.,
            min: None,
            max: None,
            unit: String::new(),
            empty: "NO DATA IN RANGE".into(),
        }
    }
}
/// Break outages at three expected scrape steps, never bridge a stopped target.
pub fn segments(points: &[PromPoint], window: u64) -> Vec<&[PromPoint]> {
    let threshold = (window as f64 / 240.).max(15.) * 3.;
    let mut out = Vec::new();
    let mut start = 0;
    for i in 1..points.len() {
        if points[i].t - points[i - 1].t > threshold
            || !points[i - 1].v.is_finite()
            || !points[i].v.is_finite()
        {
            if i > start {
                out.push(&points[start..i]);
            }
            start = i;
        }
    }
    if start < points.len() {
        out.push(&points[start..]);
    }
    out
}
/// Cache by data and viewport size. Clock ticks and unrelated metric updates
/// must not rasterise these plots again on the Pi's software renderer.
#[derive(Default)]
pub struct ChartCache {
    entries: HashMap<u64, Vec<Ink>>,
}
impl ChartCache {
    pub fn render(&mut self, chart: &Chart, width: u32, height: u32) -> Vec<Ink> {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        (
            width,
            height,
            chart.window,
            chart.end.to_bits(),
            chart.min.map(f64::to_bits),
            chart.max.map(f64::to_bits),
            &chart.unit,
            &chart.empty,
        )
            .hash(&mut h);
        for series in &chart.series {
            (&series.label, series.color).hash(&mut h);
            for p in &series.points {
                (p.t.to_bits(), p.v.to_bits()).hash(&mut h);
            }
        }
        let key = h.finish();
        if let Some(hit) = self.entries.get(&key) {
            return hit.clone();
        }
        let items = render(chart, width, height);
        // Bounded over weeks of range changes; images are shared with the UI.
        if self.entries.len() >= 24 {
            self.entries.clear();
        }
        self.entries.insert(key, items.clone());
        items
    }
}
fn paint(rgb: u32, alpha: f32, aa: bool) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color_rgba8(
        (rgb >> 16) as u8,
        (rgb >> 8) as u8,
        rgb as u8,
        (alpha * 255.).round() as u8,
    );
    p.anti_alias = aa;
    p
}
fn render(chart: &Chart, width: u32, height: u32) -> Vec<Ink> {
    let mut scene = Scene::default();
    let values: Vec<f64> = chart
        .series
        .iter()
        .flat_map(|series| series.points.iter())
        .map(|p| p.v)
        .filter(|v| v.is_finite())
        .collect();
    if values.is_empty() {
        let t = scene.text(
            0.,
            (height as f32 - 18.2) / 2.,
            width as f32,
            &chart.empty,
            14.,
            DIM,
            400,
        );
        t.align = 2;
        t.tracking = 1.5;
        return scene.0;
    }
    let mut minimum = chart
        .min
        .unwrap_or_else(|| values.iter().copied().reduce(f64::min).unwrap());
    let mut maximum = chart
        .max
        .unwrap_or_else(|| values.iter().copied().reduce(f64::max).unwrap());
    if chart.max.is_none() {
        maximum += (maximum - minimum).abs() * 0.15 + 0.5;
    }
    if chart.min.is_none() {
        minimum -= (maximum - minimum).abs() * 0.05;
    }
    if maximum - minimum < 1e-6 {
        maximum = minimum + 1.;
    }
    let (left, top, right, bottom) = (54., 10., width as f32 - 4., height as f32 - 39.);
    if right <= left || bottom <= top {
        return vec![];
    }
    let x_for_time = |t: f64| {
        left + (((t - (chart.end - chart.window as f64)) / chart.window.max(1) as f64) as f32)
            .clamp(0., 1.)
            * (right - left)
    };
    let y_for_value = |v: f64| {
        bottom - (((v - minimum) / (maximum - minimum)) as f32).clamp(0., 1.) * (bottom - top)
    };
    let mut pixels = Pixmap::new(width, height - 21).unwrap();
    let mut grid = PathBuilder::new();
    for i in 0..=4 {
        let f = i as f32 / 4.;
        let y = bottom - f * (bottom - top);
        let mut x = left;
        while x < right {
            grid.move_to(x, y);
            grid.line_to((x + 3.).min(right), y);
            x += 7.;
        }
        scene
            .text(
                0.,
                y - 8.45,
                49.,
                fmt_num(
                    Some(minimum + f as f64 * (maximum - minimum)),
                    if maximum - minimum < 10. { 1 } else { 0 },
                ),
                13.,
                DIM,
                400,
            )
            .align = 1;
        let x = left + f * (right - left);
        if i > 0 && i < 4 {
            let mut y = top;
            while y < bottom {
                grid.move_to(x, y);
                grid.line_to(x, (y + 3.).min(bottom));
                y += 7.;
            }
        }
        let label = if i == 4 {
            "now".into()
        } else {
            fmt_ago_short(TimeDelta::seconds(
                ((1. - f) * chart.window as f32).round() as i64
            ))
        };
        let text_width = label.chars().count() as f32 * 7.8;
        scene.text(
            if i == 0 {
                x
            } else if i == 4 {
                x - text_width
            } else {
                x - text_width / 2.
            },
            bottom + 3.,
            text_width,
            label,
            13.,
            DIM,
            400,
        );
    }
    if let Some(path) = grid.finish() {
        pixels.stroke_path(
            &path,
            &paint(GRID, 1., false),
            &Stroke::default(),
            Transform::identity(),
            None,
        );
    }
    let clip = tiny_skia::Rect::from_ltrb(left, top, right, bottom).unwrap();
    let mut mask = tiny_skia::Mask::new(width, height - 21).unwrap();
    mask.fill_path(
        &PathBuilder::from_rect(clip),
        tiny_skia::FillRule::Winding,
        false,
        Transform::identity(),
    );
    for series in &chart.series {
        for segment in segments(&series.points, chart.window) {
            let points: Vec<_> = segment
                .iter()
                .filter(|p| p.v.is_finite())
                .map(|p| (x_for_time(p.t), y_for_value(p.v)))
                .collect();
            let Some(&(x, y)) = points.first() else {
                continue;
            };
            let mut line = PathBuilder::new();
            let mut fill = PathBuilder::new();
            line.move_to(x, y);
            fill.move_to(x, bottom);
            fill.line_to(x, y);
            for &(x, y) in &points[1..] {
                line.line_to(x, y);
                fill.line_to(x, y);
            }
            fill.line_to(points.last().unwrap().0, bottom);
            fill.close();
            if let Some(p) = fill.finish() {
                pixels.fill_path(
                    &p,
                    &paint(series.color, 0.09, true),
                    tiny_skia::FillRule::Winding,
                    Transform::identity(),
                    Some(&mask),
                );
            }
            if let Some(p) = line.finish() {
                pixels.stroke_path(
                    &p,
                    &paint(series.color, 1., true),
                    &Stroke {
                        width: 1.6,
                        line_join: tiny_skia::LineJoin::Round,
                        ..Default::default()
                    },
                    Transform::identity(),
                    Some(&mask),
                );
            }
        }
        if let Some(p) = series.points.iter().rev().find(|p| p.v.is_finite()) {
            let mut head = PathBuilder::new();
            head.push_circle(
                x_for_time(p.t).clamp(left + 2.4, right - 2.4),
                y_for_value(p.v).clamp(top + 2.4, bottom - 2.4),
                2.4,
            );
            if let Some(p) = head.finish() {
                pixels.fill_path(
                    &p,
                    &paint(series.color, 1., true),
                    tiny_skia::FillRule::Winding,
                    Transform::identity(),
                    None,
                );
            }
        }
    }
    pixels.stroke_path(
        &PathBuilder::from_rect(clip),
        &paint(0x565656, 1., false),
        &Stroke::default(),
        Transform::identity(),
        None,
    );
    let buffer =
        SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(pixels.data(), width, height - 21);
    scene.0.insert(
        0,
        Ink {
            kind: 3,
            x: 0.,
            y: 0.,
            w: width as f32,
            h: (height - 21) as f32,
            image: Image::from_rgba8_premultiplied(buffer),
            ..Default::default()
        },
    );
    let mut x = 0.;
    let y = height as f32 - 18.;
    for series in chart
        .series
        .iter()
        .filter(|series| !series.points.is_empty())
    {
        scene.text(x, y - 1.3, 9.6, "─", 16., series.color, 400);
        x += 12.6;
        let w = series.label.chars().count() as f32 * 7.8;
        scene.text(x, y, w, &series.label, 13., MID, 400);
        x += w + 4.;
        let value = format!(
            "{}{}",
            fmt_num(series.points.last().map(|p| p.v), 1),
            chart.unit
        );
        let w = value.chars().count() as f32 * 7.8;
        scene.text(x, y, w, value, 13., WHITE, 700);
        x += w + 10.;
    }
    scene.0
}
