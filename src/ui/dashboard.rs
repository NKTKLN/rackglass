use super::{AppWindow, scene::*};
use crate::{fmt::*, store::StoreState};
use chrono::Local;

fn bytes(v: Option<f64>) -> String {
    fmt_bytes(v, 1)
}
fn big(scene: &mut Scene, width: f32, value: String, unit: &str, caption: String, ink: u32) {
    let wanted = value.chars().count() as f32 * 20.4 + 4. + unit.chars().count() as f32 * 9.18;
    let scale = (width / wanted).min(1.);
    scene.text(
        10.,
        12.,
        value.chars().count() as f32 * 20.4 * scale,
        value,
        34. * scale,
        ink,
        700,
    );
    scene.text(
        10. + (wanted - 4. - unit.chars().count() as f32 * 9.18) * scale + 4.,
        31.,
        unit.chars().count() as f32 * 9.18 * scale,
        unit,
        15.3 * scale,
        ink,
        400,
    );
    scene.text(10., 54., width, caption, 13., DIM, 400);
}
fn inline(
    scene: &mut Scene,
    width: f32,
    y: f32,
    label: &str,
    percentage: Option<f64>,
    dimmed: bool,
) {
    let ink = if dimmed { DIM } else { severity(percentage) };
    scene.text(10., y + 1.3, 48., label, 14., DIM, 400);
    scene.bar(58., y, width - 116., percentage, ink);
    scene
        .text(width - 58., y, 48., fmt_pct(percentage, 0), 16., ink, 500)
        .align = 1;
}
fn spark(
    scene: &mut Scene,
    bounds: (f32, f32, f32),
    label: &str,
    values: &[Option<f64>],
    range: (f64, f64),
    ink: u32,
) {
    let (x, y, width) = bounds;
    let (lo, hi) = range;
    let label_width = label.len() as f32 * 7.8;
    scene.text(x, y, label_width, label, 13., DIM, 400);
    let cells = ((width - label_width - 5.) / 9.6).floor().max(1.) as usize;
    scene.text(
        x + label_width + 5.,
        y - 1.5,
        cells as f32 * 9.6,
        spark_text(values, cells, Some(lo), Some(hi)),
        16.,
        ink,
        400,
    );
}
pub fn update(window: &AppWindow, state: &StoreState) {
    window.set_stale_message(if state.stale {
        format!("STALE · LAST GOOD {} AGO", fmt_duration(state.snapshot_age)).into()
    } else {
        "".into()
    });
    let Some(snapshot) = &state.snapshot else {
        window.set_dash_message(
            state
                .error
                .as_ref()
                .map(|e| format!("NO DATA · {e}"))
                .unwrap_or_else(|| "CONNECTING…".into())
                .into(),
        );
        return;
    };
    window.set_dash_message("".into());
    let host = snapshot.host();
    let package_temperature = snapshot.cpu_package_temp();
    let mut cpu = Scene::default();
    let mut gpu = Scene::default();
    let mut memory = Scene::default();
    let temp = package_temperature.map(|t| t.celsius);
    let tint = thermal(temp, 70., 85.);
    big(
        &mut cpu,
        190.,
        fmt_num(temp, 1),
        "°C",
        package_temperature
            .map(|t| t.label.clone())
            .unwrap_or_else(|| "no sensor".into()),
        tint,
    );
    for (i, t) in snapshot.other_host_temps().iter().take(2).enumerate() {
        cpu.text(
            208.,
            20. + i as f32 * 20.2,
            104.,
            format!("{} {}", t.label, fmt_temp(Some(t.celsius), 0)),
            14.,
            thermal(Some(t.celsius), 70., 85.),
            400,
        )
        .align = 1;
    }
    cpu.rect(10., 81.5, 302., 1., GRID);
    inline(
        &mut cpu,
        322.,
        86.,
        "UTIL",
        host.and_then(|node| node.cpu_pct),
        false,
    );
    cpu.text(10., 112.1, 42., "LOAD ", 14., DIM, 400);
    cpu.text(
        52.,
        112.1,
        160.,
        format!(
            "{} {} {}",
            fmt_num(host.and_then(|node| node.load1), 2),
            fmt_num(host.and_then(|node| node.load5), 2),
            fmt_num(host.and_then(|node| node.load15), 2)
        ),
        14.,
        MID,
        400,
    );
    cpu.text(
        236.4,
        112.1,
        75.6,
        format!("{} CORES", fmt_num(host.and_then(|node| node.cores), 0)),
        14.,
        DIM,
        400,
    )
    .align = 1;
    spark(
        &mut cpu,
        (10., 170., 157.),
        "TEMP",
        &state.host_temp_history.values(),
        (20., 100.),
        tint,
    );
    spark(
        &mut cpu,
        (169., 170., 143.),
        "CPU",
        &state.cpu_history(host.map(|node| node.instance.as_str()).unwrap_or("")),
        (0., 100.),
        MID,
    );
    let mut gpu_title = "GPU".to_owned();
    let mut gpu_tag = String::new();
    let stale = snapshot
        .gpus
        .first()
        .is_some_and(|gpu_stat| gpu_stat.stale());
    if let Some(gpu_stat) = snapshot.gpus.first() {
        gpu_title = format!("GPU · {}", gpu_stat.model_short()).to_uppercase();
        let tint = if stale {
            DIM
        } else {
            thermal(gpu_stat.temp, 80., 90.)
        };
        big(
            &mut gpu,
            198.,
            fmt_num(gpu_stat.temp, 0),
            "°C",
            if stale {
                format!("LAST SEEN {} AGO", fmt_duration(gpu_stat.age()))
            } else {
                format!("core · mem {}", fmt_temp(gpu_stat.mem_temp, 0))
            },
            tint,
        );
        gpu.text(
            216.,
            20.,
            118.,
            format!("{} W", fmt_num(gpu_stat.power_watts, 0)),
            16.,
            if stale { DIM } else { WHITE },
            400,
        )
        .align = 1;
        gpu.text(
            216.,
            40.8,
            118.,
            format!("SM {}MHz", fmt_num(gpu_stat.sm_clock_mhz, 0)),
            13.,
            DIM,
            400,
        )
        .align = 1;
        gpu.text(
            216.,
            57.7,
            118.,
            format!("MEM {}MHz", fmt_num(gpu_stat.mem_clock_mhz, 0)),
            13.,
            DIM,
            400,
        )
        .align = 1;
        gpu.rect(10., 81.5, 324., 1., GRID);
        inline(&mut gpu, 344., 86., "UTIL", gpu_stat.util, stale);
        inline(&mut gpu, 344., 110.8, "VRAM", gpu_stat.fb_pct(), stale);
        gpu.stat(
            10.,
            131.6,
            324.,
            "USED",
            format!(
                "{} / {}",
                bytes(gpu_stat.fb_used_bytes()),
                bytes(gpu_stat.fb_total_bytes())
            ),
            if stale { DIM } else { MID },
            400,
            14.,
        );
        spark(
            &mut gpu,
            (10., 170., 161.),
            "TEMP",
            &state.gpu_temp_history.values(),
            (20., 100.),
            tint,
        );
        spark(
            &mut gpu,
            (176., 170., 158.),
            "UTIL",
            &state.gpu_util_history.values(),
            (0., 100.),
            MID,
        );
        if stale {
            gpu_tag = "[ DOWN ]".into();
        }
    } else {
        gpu.text(10., 90., 324., "NO GPU SERIES IN TSDB", 14., DIM, 400)
            .align = 2;
    }
    let total = host.and_then(|node| node.mem_total);
    let mem_pct = host.and_then(|node| node.mem_pct());
    big(
        &mut memory,
        314.,
        bytes(host.and_then(|node| node.mem_used())),
        &format!("/ {}", bytes(total)),
        "HOST RAM IN USE".into(),
        severity(mem_pct),
    );
    memory.rect(10., 81.5, 314., 1., GRID);
    inline(&mut memory, 334., 86., "USED", mem_pct, false);
    let swap_color = severity(host.and_then(|node| node.swap_pct()));
    memory.stat(
        10.,
        106.8,
        314.,
        "SWAP",
        format!(
            "{} / {}",
            bytes(host.and_then(|node| node.swap_used())),
            bytes(host.and_then(|node| node.swap_total))
        ),
        if swap_color == FG { MID } else { swap_color },
        if swap_color == FG { 400 } else { 500 },
        14.,
    );
    let ram_count = snapshot
        .vms()
        .iter()
        .filter(|node| node.mem_total.is_some())
        .count();
    let used_count = snapshot
        .vms()
        .iter()
        .filter(|node| node.mem_used().is_some())
        .count();
    let guest_pct = total
        .filter(|v| *v > 0.)
        .map(|v| snapshot.vm_mem_reported_total() / v * 100.);
    memory.stat(
        10.,
        125.,
        314.,
        &format!("GUEST RAM SUM ({ram_count})"),
        if ram_count == 0 {
            "--".into()
        } else {
            format!(
                "{} · {}",
                bytes(Some(snapshot.vm_mem_reported_total())),
                fmt_pct(guest_pct, 0)
            )
        },
        MID,
        400,
        14.,
    );
    memory.stat(
        10.,
        143.2,
        314.,
        &format!("VM IN USE ({used_count})"),
        if used_count == 0 {
            "--".into()
        } else {
            bytes(Some(snapshot.vm_mem_used()))
        },
        MID,
        400,
        14.,
    );
    spark(
        &mut memory,
        (10., 170., 314.),
        "RAM",
        &state.mem_history(host.map(|node| node.instance.as_str()).unwrap_or("")),
        (0., 100.),
        MID,
    );
    let guests = snapshot.vms();
    let down = guests.iter().filter(|node| !node.up).count();
    sync(
        window.get_dash_titles(),
        vec![
            format!(
                "CPU · {}",
                host.map(|h| h.instance.as_str()).unwrap_or("host")
            )
            .to_uppercase()
            .into(),
            gpu_title.into(),
            format!("NODES · {}", guests.len()).into(),
        ],
        |m| window.set_dash_titles(m),
    );
    sync(
        window.get_dash_tags(),
        vec![
            if host.is_some_and(|node| !node.up) {
                "[ DOWN ]".into()
            } else {
                "".into()
            },
            gpu_tag.into(),
            if down > 0 {
                format!("[ {down} DOWN ]").into()
            } else {
                "".into()
            },
        ],
        |m| window.set_dash_tags(m),
    );
    window.set_host_down(host.is_some_and(|node| !node.up));
    window.set_gpu_stale(stale);
    sync_ink(window.get_dash_cpu(), cpu.0, |m| window.set_dash_cpu(m));
    sync_ink(window.get_dash_gpu(), gpu.0, |m| window.set_dash_gpu(m));
    sync_ink(window.get_dash_memory(), memory.0, |m| {
        window.set_dash_memory(m)
    });
    let mut headers = Scene::default();
    for (title, x, width) in header_boxes(996.) {
        let t = headers.text(x, 2.55, width, title, 13., DIM, 400);
        t.align = 2;
        t.tracking = 1.;
    }
    headers.rect(0., 22., 996., 1., GRID);
    sync_ink(window.get_dash_headers(), headers.0, |m| {
        window.set_dash_headers(m)
    });
    let mut rows = Scene::default();
    let extent = (261. / guests.len().max(1) as f32).max(44.);
    let columns = column_boxes(996.);
    for (i, node) in guests.iter().enumerate() {
        let y = i as f32 * extent + (extent - 20.8) / 2.;
        let texts = [
            if node.up { "●".into() } else { "○".into() },
            node.instance.clone(),
            fmt_pct(node.cpu_pct, 1),
            String::new(),
            fmt_pct(node.mem_pct(), 0),
            String::new(),
            if node.mem_total.is_some() {
                format!("{}/{}", bytes(node.mem_used()), bytes(node.mem_total))
            } else {
                "--".into()
            },
            if node.fs_size.is_some() {
                format!("{}/{}", bytes(node.fs_used()), bytes(node.fs_size))
            } else {
                "--".into()
            },
            fmt_duration(node.uptime()),
        ];
        for (j, (x, width)) in columns.iter().copied().enumerate() {
            if j == 3 || j == 5 {
                let percentage = if j == 3 { node.cpu_pct } else { node.mem_pct() };
                let bar_width = (width / 9.6).floor() * 9.6;
                rows.bar(
                    x + width - bar_width,
                    y,
                    bar_width,
                    percentage,
                    severity(percentage),
                );
                continue;
            }
            let ink = match j {
                0 => {
                    if node.up {
                        GREEN
                    } else {
                        RED
                    }
                }
                1 => {
                    if node.up {
                        WHITE
                    } else {
                        RED
                    }
                }
                2 => severity(node.cpu_pct),
                4 => severity(node.mem_pct()),
                6 => {
                    if node.mem_total.is_some() {
                        WHITE
                    } else {
                        DIM
                    }
                }
                _ => {
                    if node.up {
                        MID
                    } else {
                        DIM
                    }
                }
            };
            let t = rows.text(
                x,
                y,
                width,
                &texts[j],
                16.,
                ink,
                if [1, 2, 4].contains(&j) && node.up {
                    500
                } else {
                    400
                },
            );
            t.align = COLUMNS[j].align;
        }
        if i + 1 < guests.len() {
            rows.rect(0., (i + 1) as f32 * extent - 1., 996., 1., GRID);
        }
    }
    if guests.is_empty() {
        rows.text(0., 120., 996., "NO GUEST TARGETS", 14., DIM, 400)
            .align = 2;
    }
    window.set_rows_height((guests.len() as f32 * extent).max(261.));
    sync_ink(window.get_dash_rows(), rows.0, |m| window.set_dash_rows(m));
}
pub fn status(window: &AppWindow, state: &StoreState, clock: chrono::DateTime<Local>) {
    let mut scene = Scene::default();
    let mut x = 8.;
    for (label, value, ink, weight) in [
        (
            "status: ".to_owned(),
            if !state.healthy {
                "offline"
            } else if state.stale {
                "stale"
            } else {
                "online"
            }
            .to_owned(),
            if !state.healthy {
                RED
            } else if state.stale {
                AMBER
            } else {
                GREEN
            },
            700,
        ),
        ("time: ".to_owned(), fmt_clock(clock), FG, 400),
        (
            "last request: ".to_owned(),
            state
                .snapshot
                .as_ref()
                .map(|scene| {
                    format!(
                        "{} · {}ms",
                        fmt_clock(scene.at.with_timezone(&Local)),
                        scene.fetch_millis
                    )
                })
                .unwrap_or_else(|| "--".into()),
            FG,
            400,
        ),
    ] {
        if x > 8. {
            scene.text(x + 10., 3.9, 8.4, "·", 14., DIM, 400);
            x += 28.4;
        }
        let lw = label.chars().count() as f32 * 7.8;
        scene.text(x, 4.55, lw, label, 13., DIM, 400);
        x += lw;
        let vw = value.chars().count() as f32 * 8.4;
        scene.text(x, 3.9, vw, value, 14., ink, weight);
        x += vw;
    }
    let keys = "1-4 mode · ←→ cycle · r refresh · q quit";
    let kw = keys.chars().count() as f32 * 7.8;
    if !state.healthy {
        scene.text(
            x + 28.,
            4.55,
            (1006. - kw - x - 38.).max(0.),
            state
                .error
                .clone()
                .unwrap_or_else(|| "scrape failed".into()),
            13.,
            RED,
            400,
        );
    }
    scene.text(1016. - kw, 4.55, kw, keys, 13., DIM, 400);
    sync_ink(window.get_status(), scene.0, |m| window.set_status(m));
}
