use super::{
    AppWindow, InkAlign,
    chart::{Chart, ChartCache},
    layout::*,
    scene::*,
};
use crate::{
    fmt::*,
    model::{NodeHealth, NodeStat},
    store::StoreState,
};
use chrono::{DateTime, Local};
/// A target tile has two line boxes, padding and a 3px gap. Selection and
/// hit testing share this stride so dragging never selects the adjacent row.
pub const TARGET_STRIDE: f32 = 55.0;

fn bytes(v: Option<f64>) -> String {
    fmt_bytes(v, 1)
}
fn metric(s: &mut Scene, x: f32, caption: &str, pct: Option<f64>, lines: [(&str, String); 4]) {
    let width = 231.33333;
    s.caption(x, 0., width, caption);
    s.text(x, 18.9, width, fmt_pct(pct, 1), 30., severity(pct), 700)
        .h = 33.;
    s.bar(x, 53.9, 192., pct, severity(pct));
    for (i, (label, value)) in lines.into_iter().enumerate() {
        s.stat(
            x,
            80.7 + i as f32 * 18.2,
            width,
            label,
            value,
            WHITE,
            500,
            14.,
        );
    }
}
pub fn selected<'a>(state: &'a StoreState, key: &str) -> Option<&'a NodeStat> {
    state.snapshot.as_ref().and_then(|s| {
        s.nodes
            .iter()
            .find(|n| n.instance == key)
            .or(s.nodes.first())
    })
}
pub fn update(
    window: &AppWindow,
    state: &StoreState,
    key: &str,
    charts: &[Chart; 4],
    cache: &mut ChartCache,
    loading: bool,
) {
    let Some(snapshot) = &state.snapshot else {
        window.set_node_message("NO DATA".into());
        return;
    };
    let Some(node) = selected(state, key) else {
        window.set_node_message("NO NODE TARGETS".into());
        return;
    };
    window.set_node_message("".into());
    window.set_node_title(
        format!("{} · {}", node.instance, node.role)
            .to_uppercase()
            .into(),
    );
    window.set_node_tag(if node.up { "[ UP ]" } else { "[ DOWN ]" }.into());
    window.set_node_tag_color(color(if node.up { GREEN } else { RED }));
    let mut targets = Scene::default();
    // 12px vertical padding + two font line boxes + 2px border, then a 3px gap.
    let tile_height = TARGET_STRIDE - 3.0;
    let stride = TARGET_STRIDE;
    for (i, target) in snapshot.nodes.iter().enumerate() {
        let y = i as f32 * stride;
        let selected = target.instance == node.instance;
        if selected {
            targets.rect(0., y, TARGET_WIDTH, tile_height, WHITE);
        }
        targets.text(
            7.,
            y + 15.45,
            9.6,
            if selected { "▸" } else { " " },
            16.,
            if selected { BG } else { DIM },
            400,
        );
        targets.text(
            20.6,
            y + 16.75,
            8.4,
            if target.up { "●" } else { "○" },
            14.,
            if target.up { GREEN } else { RED },
            400,
        );
        targets.text(
            35.,
            y + 7.,
            186.,
            &target.instance,
            16.,
            if !target.up {
                RED
            } else if selected {
                BG
            } else {
                FG
            },
            if selected { 700 } else { 400 },
        );
        targets.text(
            35.,
            y + 27.8,
            186.,
            if target.is_hypervisor {
                "hypervisor"
            } else {
                &target.role
            },
            13.,
            if selected { GRID } else { DIM },
            400,
        );
        let (glyph, ink) = match snapshot.health_of(target) {
            NodeHealth::Ok => ("✓", GREEN),
            NodeHealth::Warn => ("▲", AMBER),
            NodeHealth::Critical => ("!", RED),
            NodeHealth::Unknown => ("·", DIM),
        };
        targets
            .text(
                221.,
                y + 15.45,
                14.,
                glyph,
                16.,
                if selected { BG } else { ink },
                700,
            )
            .align = InkAlign::Center;
    }
    window.set_targets_height(snapshot.nodes.len() as f32 * stride);
    sync_ink(window.get_node_targets(), targets.0, |m| {
        window.set_node_targets(m)
    });
    let mut detail = Scene::default();
    metric(
        &mut detail,
        0.,
        "CPU",
        node.cpu_pct,
        [
            ("cores", fmt_num(node.cores, 0)),
            ("iowait", fmt_pct(node.io_wait_pct, 1)),
            (
                "load 1/5/15",
                format!(
                    "{} {} {}",
                    fmt_num(node.load1, 2),
                    fmt_num(node.load5, 2),
                    fmt_num(node.load15, 2)
                ),
            ),
            ("load/core", fmt_num(node.load_per_core(), 2)),
        ],
    );
    metric(
        &mut detail,
        241.33333,
        "MEMORY",
        node.mem_pct(),
        [
            ("used", bytes(node.mem_used())),
            ("available", bytes(node.mem_available)),
            ("total", bytes(node.mem_total)),
            (
                "swap",
                format!("{} / {}", bytes(node.swap_used()), bytes(node.swap_total)),
            ),
        ],
    );
    metric(
        &mut detail,
        482.66666,
        "ROOT FS",
        node.fs_pct(),
        [
            ("used", bytes(node.fs_used())),
            ("avail", bytes(node.fs_avail)),
            ("size", bytes(node.fs_size)),
            ("uptime", fmt_duration(node.uptime())),
        ],
    );
    detail.rect(0., 160., DETAIL_WIDTH, 1., GRID);
    let sensors = snapshot.temps_for(&node.instance);
    let gpus = snapshot.gpus_for(&node.instance);
    let net_width = if sensors.is_empty() {
        DETAIL_WIDTH
    } else {
        280.
    };
    detail.caption(0., 167.5, net_width, "NETWORK");
    detail.stat(
        0.,
        188.4,
        net_width,
        "receive",
        fmt_rate(node.net_rx),
        CYAN,
        500,
        16.,
    );
    detail.stat(
        0.,
        209.2,
        net_width,
        "transmit",
        fmt_rate(node.net_tx),
        CYAN,
        500,
        16.,
    );
    detail.caption(0., 238., net_width, "BOOT");
    let boot = node
        .boot_time
        .and_then(|sensor| DateTime::from_timestamp_millis((sensor * 1000.).round() as i64))
        .map(|sensor| fmt_date(sensor.with_timezone(&Local)))
        .unwrap_or_else(|| "--".into());
    detail.stat(0., 258.9, net_width, "booted", boot, WHITE, 500, 16.);
    detail.stat(
        0.,
        279.7,
        net_width,
        "uptime",
        fmt_duration(node.uptime()),
        WHITE,
        500,
        16.,
    );
    if !sensors.is_empty() {
        detail.caption(294., 167.5, 420., "HWMON SENSORS");
        for (i, sensor) in sensors.iter().take(4).enumerate() {
            let y = 188.4 + i as f32 * 22.8;
            detail.text(294., y, 82., &sensor.label, 16., MID, 400);
            detail
                .text(
                    376.,
                    y,
                    74.,
                    fmt_temp(Some(sensor.celsius), 1),
                    16.,
                    thermal(Some(sensor.celsius), 70., 85.),
                    500,
                )
                .align = InkAlign::Right;
            detail.bar(
                458.,
                y,
                134.4,
                Some(sensor.celsius),
                thermal(Some(sensor.celsius), 70., 85.),
            );
            detail.text(600.4, y + 1.95, 113.6, sensor.chip_short(), 13., DIM, 400);
        }
    }
    let mut y = 300.5;
    if !gpus.is_empty() {
        detail.rect(0., y + 6.5, DETAIL_WIDTH, 1., GRID);
        y += 14.;
        detail.caption(0., y, DETAIL_WIDTH, "GPU");
        y += 20.9;
        for gpu in &gpus {
            let title = format!("gpu{} · {}", gpu.gpu, gpu.model_short());
            let title_width = title.chars().count() as f32 * 9.6;
            detail.text(0., y, title_width, title, 16., MID, 400);
            if gpu.stale() {
                detail.text(
                    title_width + 8.,
                    y + 1.95,
                    DETAIL_WIDTH - title_width - 8.,
                    gpu.age()
                        .map(|a| format!("[ DOWN · {} OLD ]", fmt_duration(Some(a))))
                        .unwrap_or_else(|| "[ DOWN ]".into()),
                    13.,
                    AMBER,
                    700,
                );
            }
            y += 22.8;
            for (i, (label, value, ink)) in [
                ("utilisation", fmt_pct(gpu.util, 0), severity(gpu.util)),
                (
                    "temperature",
                    fmt_temp(gpu.temp, 1),
                    thermal(gpu.temp, 75., 88.),
                ),
                ("memory temp", fmt_temp(gpu.mem_temp, 1), WHITE),
            ]
            .into_iter()
            .enumerate()
            {
                detail.stat(0., y + i as f32 * 18.2, 350., label, value, ink, 500, 14.);
            }
            for (i, (label, value)) in [
                (
                    "vram",
                    format!(
                        "{} / {}",
                        bytes(gpu.fb_used_bytes()),
                        bytes(gpu.fb_total_bytes())
                    ),
                ),
                (
                    "power",
                    gpu.power_watts
                        .map(|p| format!("{p:.0} W"))
                        .unwrap_or_else(|| "--".into()),
                ),
                (
                    "clocks sm/mem",
                    if gpu.sm_clock_mhz.is_none() && gpu.mem_clock_mhz.is_none() {
                        "--".into()
                    } else {
                        format!(
                            "{} / {} MHz",
                            fmt_num(gpu.sm_clock_mhz, 0),
                            fmt_num(gpu.mem_clock_mhz, 0)
                        )
                    },
                ),
            ]
            .into_iter()
            .enumerate()
            {
                detail.stat(
                    364.,
                    y + i as f32 * 18.2,
                    350.,
                    label,
                    value,
                    WHITE,
                    500,
                    14.,
                );
            }
            y += 60.6;
        }
    }
    detail.rect(0., y + 5.5, DETAIL_WIDTH, 1., GRID);
    y += 12.;
    detail.caption(0., y, 300., "LAST 1H");
    if loading {
        detail
            .text(500., y, 214., "LOADING…", 13., AMBER, 400)
            .align = InkAlign::Right;
    }
    y += 20.9;
    for (i, caption) in [
        "CPU %",
        "MEMORY USED · GiB",
        "TEMPERATURE °C",
        "GPU UTILISATION %",
    ]
    .iter()
    .enumerate()
    {
        if (i == 2 && sensors.is_empty() && gpus.is_empty()) || (i == 3 && gpus.is_empty()) {
            continue;
        }
        detail.caption(0., y, DETAIL_WIDTH, *caption);
        y += 18.9;
        detail.append_at(&cache.render(&charts[i], NODE_CHART.0, NODE_CHART.1), 0., y);
        y += 142.;
    }
    window.set_detail_height(y);
    sync_ink(window.get_node_detail(), detail.0, |m| {
        window.set_node_detail(m)
    });
}
