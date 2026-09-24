//! History request identity is separate from data: hiding, changing window or
//! changing target invalidates both successful and failed late completions.
use super::{
    chart::{Chart, Series},
    scene::*,
};
use crate::{
    MetricsStore,
    prom::{
        client::{PromError, PromSeries},
        queries as q,
    },
};
use chrono::{DateTime, Utc};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

pub const WINDOWS: [u64; 5] = [900, 3600, 21600, 86400, 604800];
#[derive(Default, Debug)]
pub struct RequestGuard {
    pub active: bool,
    pub serial: u64,
    pub key: String,
    pub loading: bool,
}
#[derive(Clone, Debug)]
pub struct Ticket {
    serial: u64,
    key: String,
}
impl RequestGuard {
    pub fn activate(&mut self) {
        self.serial += 1;
        self.active = true;
        self.loading = false;
    }
    pub fn deactivate(&mut self) {
        self.serial += 1;
        self.active = false;
        self.loading = false;
    }
    pub fn begin(&mut self, key: String) -> Option<Ticket> {
        if !self.active {
            return None;
        }
        self.serial += 1;
        self.key = key;
        self.loading = true;
        Some(Ticket {
            serial: self.serial,
            key: self.key.clone(),
        })
    }
    pub fn accepts(&self, t: &Ticket) -> bool {
        self.active && self.serial == t.serial && self.key == t.key
    }
    pub fn finish(&mut self, t: &Ticket) -> bool {
        if !self.accepts(t) {
            return false;
        }
        self.loading = false;
        true
    }
}
/// Allocate colours in sorted order and remember them across refreshes. A
/// disappearing target must not change the identity of every remaining line.
#[derive(Default)]
pub struct Colors {
    nodes: BTreeMap<String, u32>,
    gpus: BTreeMap<String, u32>,
    paths: BTreeMap<String, u32>,
}
fn assign(map: &mut BTreeMap<String, u32>, keys: impl Iterator<Item = String>, palette: &[u32]) {
    for key in keys.collect::<BTreeSet<_>>() {
        let next = palette[map.len() % palette.len()];
        map.entry(key).or_insert(next);
    }
}
fn gpu_key(s: &PromSeries) -> String {
    format!(
        "{}/{}",
        s.instance().unwrap_or("?"),
        s.labels
            .get("UUID")
            .or_else(|| s.labels.get("gpu"))
            .map(String::as_str)
            .unwrap_or("0")
    )
}
fn speed_key(s: &PromSeries, direction: &str) -> String {
    format!(
        "{} {direction}",
        s.labels.get("path").map(String::as_str).unwrap_or("direct")
    )
}
fn series(s: &PromSeries, label: String, color: u32, scale: f64) -> Series {
    Series {
        label,
        color,
        points: s
            .points
            .iter()
            .map(|p| crate::prom::client::PromPoint {
                t: p.t,
                v: p.v * scale,
            })
            .collect(),
    }
}
pub fn graph_queries() -> Vec<String> {
    [
        q::RANGE_CPU,
        q::RANGE_TEMP_CPU,
        q::RANGE_TEMP_GPU,
        q::RANGE_GPU_UTIL,
        q::RANGE_MEM_PCT,
        q::RANGE_SPEEDTEST_DOWN,
        q::RANGE_SPEEDTEST_UP,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}
pub fn load_batch(
    store: &MetricsStore,
    queries: &[String],
    window: u64,
    end: DateTime<Utc>,
) -> Result<Vec<Vec<PromSeries>>, PromError> {
    std::thread::scope(|scope| {
        let jobs: Vec<_> = queries
            .iter()
            .map(|q| {
                scope.spawn(move || {
                    if q.is_empty() {
                        Ok(vec![])
                    } else {
                        store.load_range(q, Duration::from_secs(window), Some(end))
                    }
                })
            })
            .collect();
        jobs.into_iter()
            .map(|j| {
                j.join()
                    .unwrap_or_else(|_| Err(PromError("range worker panicked".into())))
            })
            .collect()
    })
}
pub fn graph_charts(
    data: &[Vec<PromSeries>],
    window: u64,
    end: DateTime<Utc>,
    colors: &mut Colors,
) -> [Chart; 4] {
    // Same order as graph_queries().
    let [
        cpu,
        cpu_temp,
        gpu_temp,
        gpu_util,
        memory,
        speed_down,
        speed_up,
    ] = data
    else {
        panic!("graph_charts needs one result per graph query");
    };
    assign(
        &mut colors.nodes,
        cpu.iter()
            .chain(memory)
            .map(|s| s.instance().unwrap_or("?").into()),
        &NODE_COLORS,
    );
    assign(
        &mut colors.gpus,
        gpu_temp.iter().chain(gpu_util).map(gpu_key),
        &GPU_COLORS,
    );
    assign(
        &mut colors.paths,
        speed_down
            .iter()
            .map(|s| speed_key(s, "↓"))
            .chain(speed_up.iter().map(|s| speed_key(s, "↑"))),
        &NODE_COLORS,
    );
    let base = Chart {
        window,
        end: end.timestamp_millis() as f64 / 1000.,
        ..Default::default()
    };
    let by_node = |s: &PromSeries| {
        series(
            s,
            s.instance().unwrap_or("?").into(),
            *colors
                .nodes
                .get(s.instance().unwrap_or("?"))
                .unwrap_or(&DIM),
            1.,
        )
    };
    let by_gpu = |s: &PromSeries| {
        series(
            s,
            format!(
                "gpu{}",
                s.labels.get("gpu").map(String::as_str).unwrap_or("0")
            ),
            *colors.gpus.get(&gpu_key(s)).unwrap_or(&AMBER),
            1.,
        )
    };
    [
        Chart {
            series: cpu
                .iter()
                .map(by_node)
                .chain(gpu_util.iter().map(by_gpu))
                .collect(),
            min: Some(0.),
            unit: "%".into(),
            ..base.clone()
        },
        Chart {
            series: cpu_temp
                .iter()
                .map(|s| {
                    let label = s
                        .labels
                        .get("label")
                        .or_else(|| s.labels.get("sensor"))
                        .map(String::as_str)
                        .unwrap_or("?");
                    series(
                        s,
                        format!("cpu {label}"),
                        if label == "Tctl" { FG } else { CYAN },
                        1.,
                    )
                })
                .chain(gpu_temp.iter().map(by_gpu))
                .collect(),
            unit: "°".into(),
            ..base.clone()
        },
        Chart {
            series: memory.iter().map(by_node).collect(),
            min: Some(0.),
            max: Some(100.),
            unit: "%".into(),
            ..base.clone()
        },
        Chart {
            series: [("↓", speed_down), ("↑", speed_up)]
                .into_iter()
                .flat_map(|(dir, list)| list.iter().map(move |s| (s, dir)))
                .map(|(s, dir)| {
                    let key = speed_key(s, dir);
                    let color = *colors.paths.get(&key).unwrap_or(&FG);
                    series(s, key, color, 1e-6)
                })
                .collect(),
            min: Some(0.),
            unit: "M".into(),
            empty: "NO SPEEDTEST RESULTS IN RANGE".into(),
            ..base
        },
    ]
}
pub fn node_queries(instance: &str, temps: bool, gpus: bool) -> Vec<String> {
    vec![
        q::cpu_for(instance),
        q::mem_used_bytes_for(instance),
        if temps {
            q::hwmon_temp_for(instance)
        } else {
            String::new()
        },
        if gpus {
            q::gpu_temp_for(instance)
        } else {
            String::new()
        },
        if gpus {
            q::gpu_util_for(instance)
        } else {
            String::new()
        },
    ]
}
pub fn node_charts(data: &[Vec<PromSeries>], end: DateTime<Utc>, up: bool) -> [Chart; 4] {
    // Same order as node_queries().
    let [cpu, memory, hwmon, gpu_temp, gpu_util] = data else {
        panic!("node_charts needs one result per node query");
    };
    let base = Chart {
        window: 3600,
        end: end.timestamp_millis() as f64 / 1000.,
        min: Some(0.),
        ..Default::default()
    };
    let gpu = |s: &PromSeries| {
        series(
            s,
            format!(
                "gpu{}",
                s.labels.get("gpu").map(String::as_str).unwrap_or("0")
            ),
            AMBER,
            1.,
        )
    };
    [
        Chart {
            series: cpu
                .iter()
                .map(|s| series(s, "cpu".into(), FG, 1.))
                .collect(),
            max: Some(100.),
            unit: "%".into(),
            empty: if up {
                "NO CPU HISTORY"
            } else {
                "TARGET DOWN · NO HISTORY"
            }
            .into(),
            ..base.clone()
        },
        Chart {
            series: memory
                .iter()
                .map(|s| series(s, "memory".into(), CYAN, 1. / (1024. * 1024. * 1024.)))
                .collect(),
            unit: "G".into(),
            empty: if up {
                "NO MEMORY HISTORY"
            } else {
                "TARGET DOWN · NO HISTORY"
            }
            .into(),
            ..base.clone()
        },
        Chart {
            series: hwmon
                .iter()
                .map(|s| {
                    let label = s
                        .labels
                        .get("label")
                        .or_else(|| s.labels.get("sensor"))
                        .map(String::as_str)
                        .unwrap_or("sensor");
                    series(s, label.into(), if label == "Tctl" { FG } else { CYAN }, 1.)
                })
                .chain(gpu_temp.iter().map(gpu))
                .collect(),
            unit: "°".into(),
            empty: "NO TEMPERATURE HISTORY".into(),
            ..base.clone()
        },
        Chart {
            series: gpu_util.iter().map(gpu).collect(),
            max: Some(100.),
            unit: "%".into(),
            empty: "NO GPU HISTORY".into(),
            ..base
        },
    ]
}
