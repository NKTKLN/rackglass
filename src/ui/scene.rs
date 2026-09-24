//! Layout primitives in design pixels. Slint owns text, bars and dirty regions.
use super::Ink;
use slint::{Color, Image, Model, ModelRc, VecModel};
use std::rc::Rc;

pub const BG: u32 = 0x000000;
pub const GRID: u32 = 0x474747;
pub const DIM: u32 = 0x8a8a8a;
pub const MID: u32 = 0xafafaf;
pub const FG: u32 = 0xd4d4d4;
pub const WHITE: u32 = 0xffffff;
pub const GREEN: u32 = 0x4ec94e;
pub const CYAN: u32 = 0x3fc7c7;
pub const AMBER: u32 = 0xd7b733;
pub const RED: u32 = 0xe05a4f;
pub const MAGENTA: u32 = 0xbe72c8;
pub const BLUE: u32 = 0x6e90d8;
pub const ORANGE: u32 = 0xe08a3c;
pub const NODE_COLORS: [u32; 5] = [FG, CYAN, MAGENTA, BLUE, GREEN];
pub const GPU_COLORS: [u32; 2] = [AMBER, ORANGE];
pub fn color(rgb: u32) -> Color {
    Color::from_rgb_u8((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
}
pub fn severity(v: Option<f64>) -> u32 {
    match v {
        None => DIM,
        Some(v) if v >= 90.0 => RED,
        Some(v) if v >= 75.0 => AMBER,
        _ => FG,
    }
}
pub fn thermal(v: Option<f64>, warn: f64, crit: f64) -> u32 {
    match v {
        None => DIM,
        Some(v) if v >= crit => RED,
        Some(v) if v >= warn => AMBER,
        _ => FG,
    }
}
pub fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    Rc::new(VecModel::from(v)).into()
}
/// Bring a model to `next` by changing only the rows that differ.
///
/// Handing Slint a fresh model makes the repeater tear down and rebuild every
/// element, and the software renderer then repaints the whole screen for a
/// poll that moved one number. Editing rows in place keeps the dirty region to
/// the elements that actually changed. The first call, before any VecModel is
/// installed, goes through `set`.
pub fn sync<T: Clone + PartialEq + 'static>(
    current: ModelRc<T>,
    next: Vec<T>,
    set: impl FnOnce(ModelRc<T>),
) {
    sync_by(current, next, set, |a, b| a == b);
}
/// [`sync`] for scene items, which cannot use their derived `PartialEq`.
pub fn sync_ink(current: ModelRc<Ink>, next: Vec<Ink>, set: impl FnOnce(ModelRc<Ink>)) {
    sync_by(current, next, set, same_ink);
}
fn sync_by<T: Clone + 'static>(
    current: ModelRc<T>,
    next: Vec<T>,
    set: impl FnOnce(ModelRc<T>),
    same: impl Fn(&T, &T) -> bool,
) {
    let Some(rows) = current.as_any().downcast_ref::<VecModel<T>>() else {
        set(model(next));
        return;
    };
    let kept = rows.row_count().min(next.len());
    while rows.row_count() > next.len() {
        rows.remove(rows.row_count() - 1);
    }
    for (i, item) in next.into_iter().enumerate() {
        if i >= kept {
            rows.push(item);
        } else if !rows.row_data(i).is_some_and(|old| same(&old, &item)) {
            rows.set_row_data(i, item);
        }
    }
}
/// Slint's `Image` never equals an empty `Image`, not even another empty one,
/// so the derived comparison calls every text element changed. Compare the
/// image only where one is drawn; a cached chart hands back the same image,
/// which does compare equal. The destructuring is exhaustive on purpose: a new
/// field must be added here or this stops compiling.
pub fn same_ink(a: &Ink, b: &Ink) -> bool {
    let Ink {
        kind,
        x,
        y,
        w,
        h,
        text,
        size,
        weight,
        tracking,
        color,
        align,
        pct,
        image,
    } = a;
    *kind == b.kind
        && *x == b.x
        && *y == b.y
        && *w == b.w
        && *h == b.h
        && *text == b.text
        && *size == b.size
        && *weight == b.weight
        && *tracking == b.tracking
        && *color == b.color
        && *align == b.align
        && *pct == b.pct
        && (*kind != 3 || *image == b.image)
}
#[derive(Default, Clone)]
pub struct Scene(pub Vec<Ink>);
impl Scene {
    #[allow(clippy::too_many_arguments)]
    pub fn text(
        &mut self,
        x: f32,
        y: f32,
        w: f32,
        text: impl Into<String>,
        size: f32,
        ink: u32,
        weight: i32,
    ) -> &mut Ink {
        self.0.push(Ink {
            kind: 0,
            x,
            y,
            w,
            h: size * 1.3,
            text: text.into().into(),
            size,
            weight,
            color: color(ink),
            ..Default::default()
        });
        self.0.last_mut().unwrap()
    }
    pub fn caption(&mut self, x: f32, y: f32, w: f32, text: impl Into<String>) {
        self.text(x, y, w, text, 13.0, DIM, 400).tracking = 1.2;
    }
    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, ink: u32) {
        self.0.push(Ink {
            kind: 1,
            x,
            y,
            w,
            h,
            color: color(ink),
            ..Default::default()
        });
    }
    pub fn bar(&mut self, x: f32, y: f32, w: f32, pct: Option<f64>, ink: u32) {
        // Callers quantise loose gauges to font cells. Expanded gauges use the
        // full available width, as Flutter's tight constraints require. Unknown
        // is a rule rather than an empty track, which would falsely imply zero.
        self.0.push(Ink {
            kind: 2,
            x,
            y,
            w,
            h: 20.8,
            pct: pct.unwrap_or(-1.0) as f32,
            color: color(ink),
            ..Default::default()
        });
    }
    pub fn image(&mut self, x: f32, y: f32, w: f32, h: f32, image: Image) {
        self.0.push(Ink {
            kind: 3,
            x,
            y,
            w,
            h,
            image,
            ..Default::default()
        });
    }
    #[allow(clippy::too_many_arguments)]
    /// Reserve the value first so a long label ellipsizes instead of overlapping.
    pub fn stat(
        &mut self,
        x: f32,
        y: f32,
        w: f32,
        label: &str,
        value: impl Into<String>,
        ink: u32,
        weight: i32,
        size: f32,
    ) {
        let value = value.into();
        let vw = value.chars().count() as f32 * size * 0.6;
        self.text(x, y, (w - vw - 8.0).max(0.0), label, size, DIM, 400);
        self.text(
            x + (w - vw).max(0.0),
            y,
            vw.min(w),
            value,
            size,
            ink,
            weight,
        )
        .align = 1;
    }
    pub fn append_at(&mut self, other: &[Ink], x: f32, y: f32) {
        self.0.extend(other.iter().cloned().map(|mut i| {
            i.x += x;
            i.y += y;
            i
        }));
    }
}
/// The header and body use these exact column boxes. Elastic gaps keep the
/// final uptime cell clear of the frame even when headings span several cells.
pub struct Column {
    pub width: f32,
    pub heading: &'static str,
    pub span: usize,
    pub align: i32,
}
pub const COLUMNS: [Column; 9] = [
    Column {
        width: 24.,
        heading: "",
        span: 1,
        align: 0,
    },
    Column {
        width: 160.,
        heading: "INSTANCE",
        span: 1,
        align: 0,
    },
    Column {
        width: 52.,
        heading: "CPU",
        span: 2,
        align: 1,
    },
    Column {
        width: 120.,
        heading: "",
        span: 1,
        align: 1,
    },
    Column {
        width: 56.,
        heading: "MEMORY",
        span: 3,
        align: 1,
    },
    Column {
        width: 120.,
        heading: "",
        span: 1,
        align: 1,
    },
    Column {
        width: 112.,
        heading: "",
        span: 1,
        align: 0,
    },
    Column {
        width: 108.,
        heading: "ROOT",
        span: 1,
        align: 0,
    },
    Column {
        width: 72.,
        heading: "UPTIME",
        span: 1,
        align: 2,
    },
];
pub fn column_boxes(width: f32) -> Vec<(f32, f32)> {
    let gap = ((width - 14.0 - COLUMNS.iter().map(|c| c.width).sum::<f32>()) / 8.0).max(0.0);
    let mut x = 0.;
    COLUMNS
        .iter()
        .map(|c| {
            let b = (x, c.width);
            x += c.width + gap;
            b
        })
        .collect()
}
pub fn header_boxes(width: f32) -> Vec<(&'static str, f32, f32)> {
    let boxes = column_boxes(width);
    COLUMNS
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.heading.is_empty())
        .map(|(i, c)| {
            let end = boxes[i + c.span - 1];
            (c.heading, boxes[i].0, end.0 + end.1 - boxes[i].0)
        })
        .collect()
}
