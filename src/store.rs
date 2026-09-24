//! Threaded polling, a current snapshot, and short histories for sparklines.
use crate::{
    config::{Config, GPU_FALLBACK_REFRESH, HISTORY_DEPTH},
    model::{GpuStat, NodeStat, Snapshot, TempReading},
    prom::{
        client::{PromClient, PromError, PromSample, PromSeries},
        queries::{self, InstantQuery as Q},
    },
};
use chrono::{DateTime, Utc};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

type Batch = BTreeMap<Q, Vec<PromSample>>;
type Callback = Arc<dyn Fn() + Send + Sync>;
/// Null is a real sample: two readings separated by an outage must not appear
/// adjacent as if monitoring had been continuous.
#[derive(Clone, Debug, Default)]
pub struct Ring(VecDeque<Option<f64>>);
impl Ring {
    pub fn add(&mut self, v: Option<f64>) {
        self.0.push_back(v.filter(|v| !v.is_nan()));
        if self.0.len() > HISTORY_DEPTH {
            self.0.pop_front();
        }
    }
    pub fn values(&self) -> Vec<Option<f64>> {
        self.0.iter().copied().collect()
    }
}
/// A coherent copy of observable state. Call `state()` again as time advances.
#[derive(Clone, Debug)]
pub struct StoreState {
    pub snapshot: Option<Snapshot>,
    pub error: Option<String>,
    pub healthy: bool,
    pub stale: bool,
    pub snapshot_age: Option<chrono::TimeDelta>,
    pub consecutive_errors: usize,
    pub last_success: Option<DateTime<Utc>>,
    pub endpoint: String,
    pub cpu_history: BTreeMap<String, Ring>,
    pub mem_history: BTreeMap<String, Ring>,
    pub host_temp_history: Ring,
    pub gpu_temp_history: Ring,
    pub gpu_util_history: Ring,
    primary_gpu_key: Option<String>,
}
impl StoreState {
    pub fn cpu_history(&self, instance: &str) -> Vec<Option<f64>> {
        self.cpu_history
            .get(instance)
            .map(Ring::values)
            .unwrap_or_default()
    }
    pub fn mem_history(&self, instance: &str) -> Vec<Option<f64>> {
        self.mem_history
            .get(instance)
            .map(Ring::values)
            .unwrap_or_default()
    }
    fn record(&mut self, snap: &Snapshot) {
        let nodes: BTreeMap<_, _> = snap.nodes.iter().map(|n| (n.instance.clone(), n)).collect();
        let known: BTreeSet<_> = self
            .cpu_history
            .keys()
            .chain(self.mem_history.keys())
            .chain(nodes.keys())
            .cloned()
            .collect();
        for instance in known {
            let n = nodes.get(&instance).filter(|n| n.up);
            self.cpu_history
                .entry(instance.clone())
                .or_default()
                .add(n.and_then(|n| n.cpu_pct));
            self.mem_history
                .entry(instance)
                .or_default()
                .add(n.and_then(|n| n.mem_pct()));
        }
        self.host_temp_history
            .add(snap.cpu_package_temp().map(|t| t.celsius));
        // Follow one card while it exists, then re-latch immediately. A changed
        // UUID must not leave the strip blank for the rest of the session.
        if !snap
            .gpus
            .iter()
            .any(|g| Some(g.key()) == self.primary_gpu_key)
        {
            self.primary_gpu_key = snap.gpus.first().map(GpuStat::key);
        }
        let g = snap
            .gpus
            .iter()
            .find(|g| Some(g.key()) == self.primary_gpu_key)
            .filter(|g| !g.stale());
        self.gpu_temp_history.add(g.and_then(|g| g.temp));
        self.gpu_util_history.add(g.and_then(|g| g.util));
    }
    fn failed(&mut self) {
        for ring in self
            .cpu_history
            .values_mut()
            .chain(self.mem_history.values_mut())
        {
            ring.add(None);
        }
        self.host_temp_history.add(None);
        self.gpu_temp_history.add(None);
        self.gpu_util_history.add(None);
    }
}
#[derive(Default)]
struct Fallback {
    cache: Batch,
    at: Option<DateTime<Utc>>,
    down: BTreeSet<String>,
    in_flight: bool,
}
struct Inner {
    cfg: Config,
    client: PromClient,
    state: Mutex<StoreState>,
    fallback: Mutex<Fallback>,
    callback: Mutex<Option<Callback>>,
    in_flight: AtomicBool,
    started: AtomicBool,
    wake: Arc<(Mutex<bool>, Condvar)>,
    now: Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        *self.wake.0.lock().unwrap() = true;
        self.wake.1.notify_all();
    }
}
/// Clones share one store. Dropping the last handle stops the timer; `stop()`
/// also prevents an already-running poll from publishing its result.
#[derive(Clone)]
pub struct MetricsStore(Arc<Inner>);
impl MetricsStore {
    pub fn new(cfg: Config, client: PromClient) -> Self {
        Self::with_clock(cfg, client, Arc::new(Utc::now))
    }
    /// An injected wall clock makes staleness and cache expiry deterministic.
    pub fn with_clock(
        cfg: Config,
        client: PromClient,
        now: Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>,
    ) -> Self {
        let state = StoreState {
            snapshot: None,
            error: None,
            healthy: false,
            stale: false,
            snapshot_age: None,
            consecutive_errors: 0,
            last_success: None,
            endpoint: client.base_url.clone(),
            cpu_history: BTreeMap::new(),
            mem_history: BTreeMap::new(),
            host_temp_history: Ring::default(),
            gpu_temp_history: Ring::default(),
            gpu_util_history: Ring::default(),
            primary_gpu_key: None,
        };
        Self(Arc::new(Inner {
            cfg,
            client,
            state: Mutex::new(state),
            fallback: Mutex::new(Fallback::default()),
            callback: Mutex::new(None),
            in_flight: AtomicBool::new(false),
            started: AtomicBool::new(false),
            wake: Arc::new((Mutex::new(false), Condvar::new())),
            now,
        }))
    }
    pub fn state(&self) -> StoreState {
        let mut s = self.0.state.lock().unwrap().clone();
        s.healthy = s.error.is_none() && s.snapshot.is_some();
        s.snapshot_age = s.last_success.map(|t| (self.0.now)() - t);
        s.stale = s.snapshot.is_some()
            && s.snapshot_age.is_some_and(|age| {
                age > chrono::TimeDelta::from_std(self.0.cfg.snapshot_stale_after())
                    .unwrap_or(chrono::TimeDelta::MAX)
            });
        s
    }
    /// Invoked outside state locks, on a worker thread, after each completed poll.
    pub fn on_change(&self, callback: Box<dyn Fn() + Send + Sync>) {
        *self.0.callback.lock().unwrap() = Some(Arc::from(callback));
    }
    fn stopped(&self) -> bool {
        *self.0.wake.0.lock().unwrap()
    }
    pub fn stop(&self) {
        *self.0.wake.0.lock().unwrap() = true;
        self.0.wake.1.notify_all();
    }
    /// Runs one poll on a background thread. Overlaps are dropped, never queued.
    /// Join the returned handle when a caller needs to wait for publication.
    pub fn refresh(&self) -> Option<JoinHandle<()>> {
        if self.stopped() || self.0.in_flight.swap(true, Ordering::AcqRel) {
            return None;
        }
        let store = self.clone();
        Some(thread::spawn(move || {
            let result = store.fetch();
            let stopped = store.0.wake.0.lock().unwrap();
            if !*stopped {
                let mut state = store.0.state.lock().unwrap();
                match result {
                    Ok(snap) => {
                        state.record(&snap);
                        state.snapshot = Some(snap);
                        state.error = None;
                        state.consecutive_errors = 0;
                        state.last_success = Some((store.0.now)());
                    }
                    Err(e) => {
                        state.error = Some(e.0);
                        state.consecutive_errors += 1;
                        state.failed();
                    }
                }
            }
            drop(stopped);
            store.0.in_flight.store(false, Ordering::Release);
            let callback = store.0.callback.lock().unwrap().clone();
            if !store.stopped()
                && let Some(callback) = callback
            {
                callback();
            }
        }))
    }
    /// Starts immediately and then on the configured cadence. Repeated starts
    /// share the same timer; slow polls are dropped by `refresh()`.
    pub fn start(&self) {
        if self.stopped() || self.0.started.swap(true, Ordering::AcqRel) {
            return;
        }
        self.refresh();
        let weak = Arc::downgrade(&self.0);
        let wake = self.0.wake.clone();
        let interval = self.0.cfg.poll_interval();
        thread::spawn(move || {
            loop {
                let (stop, _) = wake
                    .1
                    .wait_timeout_while(wake.0.lock().unwrap(), interval, |stop| !*stop)
                    .unwrap();
                if *stop {
                    break;
                }
                drop(stop);
                let Some(inner) = weak.upgrade() else {
                    break;
                };
                MetricsStore(inner).refresh();
            }
        });
    }
    pub fn load_range(
        &self,
        query: &str,
        window: Duration,
        end: Option<DateTime<Utc>>,
    ) -> Result<Vec<PromSeries>, PromError> {
        let end = end.unwrap_or_else(|| (self.0.now)());
        let delta = chrono::TimeDelta::from_std(window)
            .map_err(|_| PromError("range window too large".into()))?;
        let start = end
            .checked_sub_signed(delta)
            .ok_or_else(|| PromError("range window too large".into()))?;
        self.0
            .client
            .range(query, start, end, Self::step_for(window))
    }
    /// Roughly 240 points, never finer than the fifteen-second scrape interval.
    pub fn step_for(window: Duration) -> Duration {
        Duration::from_secs(((window.as_secs() as f64 / 240.0).round() as u64).max(15))
    }
    fn batch(&self, queries: Vec<(Q, String)>) -> Result<Batch, PromError> {
        thread::scope(|scope| {
            let jobs: Vec<_> = queries
                .into_iter()
                .map(|(key, q)| {
                    scope.spawn(move || self.0.client.instant(&q, None).map(|v| (key, v)))
                })
                .collect();
            let mut out = Batch::new();
            let mut error = None;
            for job in jobs {
                match job.join() {
                    Ok(Ok((key, v))) => {
                        out.insert(key, v);
                    }
                    Ok(Err(e)) => {
                        if error.is_none() {
                            error = Some(e);
                        }
                    }
                    Err(_) => {
                        if error.is_none() {
                            error = Some(PromError("query worker panicked".into()));
                        }
                    }
                }
            }
            error.map_or(Ok(out), Err)
        })
    }
    /// Await the first scan: nothing exists to show yet. Thereafter node metrics
    /// must not sit behind a TSDB scan; a later poll picks up background results.
    fn fallback_for(&self, down: BTreeSet<String>) -> Batch {
        let mut f = self.0.fallback.lock().unwrap();
        if down.is_empty() {
            f.down.clear();
            f.cache.clear();
            f.at = None;
            return Batch::new();
        }
        let same = f.down == down;
        let cached = if same { f.cache.clone() } else { Batch::new() };
        let expired = f.at.is_none_or(|at| {
            (self.0.now)() - at >= chrono::TimeDelta::from_std(GPU_FALLBACK_REFRESH).unwrap()
        });
        if !expired && same {
            return cached;
        }
        if f.in_flight {
            return f.cache.clone();
        }
        f.in_flight = true;
        drop(f);
        if cached.is_empty() {
            self.refresh_fallback(down)
        } else {
            let store = self.clone();
            thread::spawn(move || {
                store.refresh_fallback(down);
            });
            cached
        }
    }
    fn refresh_fallback(&self, down: BTreeSet<String>) -> Batch {
        let result = self.batch(queries::gpu_fallback_queries());
        let mut f = self.0.fallback.lock().unwrap();
        f.in_flight = false;
        match result {
            Ok(fetched) => {
                if !self.stopped() {
                    f.cache = fetched.clone();
                    f.at = Some((self.0.now)());
                    f.down = down;
                }
                fetched
            }
            // Historical diagnostics failing must not take current nodes offline.
            Err(_) => {
                if f.down == down {
                    f.cache.clone()
                } else {
                    Batch::new()
                }
            }
        }
    }
    fn fetch(&self) -> Result<Snapshot, PromError> {
        let started = Instant::now();
        let results = self.batch(queries::instant_poll_queries(&self.0.cfg))?;
        let r = |q| results.get(&q).map(Vec::as_slice).unwrap_or_default();
        let mut nodes = Vec::new();
        for s in r(Q::Up) {
            if s.labels.get("job").map(String::as_str) != Some("node") {
                continue;
            }
            let Some(inst) = s.instance() else {
                continue;
            };
            let v = |q| {
                r(q).iter()
                    .rev()
                    .find(|s| s.instance() == Some(inst))
                    .map(|s| s.value)
            };
            nodes.push(NodeStat {
                instance: inst.into(),
                role: s.labels.get("role").cloned().unwrap_or("-".into()),
                up: s.value != 0.0,
                is_hypervisor: inst == self.0.cfg.hypervisor,
                cpu_pct: v(Q::CpuBusy),
                io_wait_pct: v(Q::CpuIoWait),
                cores: v(Q::Cores),
                mem_total: v(Q::MemTotal),
                mem_available: v(Q::MemAvailable),
                swap_total: v(Q::SwapTotal),
                swap_free: v(Q::SwapFree),
                load1: v(Q::Load1),
                load5: v(Q::Load5),
                load15: v(Q::Load15),
                boot_time: v(Q::BootTime),
                fs_size: v(Q::FsSize),
                fs_avail: v(Q::FsAvail),
                net_rx: v(Q::NetRx),
                net_tx: v(Q::NetTx),
            });
        }
        nodes.sort_by(|a, b| {
            b.is_hypervisor
                .cmp(&a.is_hypervisor)
                .then(a.instance.cmp(&b.instance))
        });
        // The left join keeps raw channels alongside labelled temperatures.
        let mut temps: Vec<_> = r(Q::AllTemps)
            .iter()
            .map(|s| TempReading {
                instance: s.instance().unwrap_or("?").into(),
                chip: label(s, "chip", "?"),
                sensor: label(s, "sensor", "?"),
                label: s
                    .labels
                    .get("label")
                    .or_else(|| s.labels.get("sensor"))
                    .cloned()
                    .unwrap_or("?".into()),
                celsius: s.value,
                named: s.labels.contains_key("label"),
            })
            .collect();
        temps.sort_by(|a, b| {
            (&a.instance, &a.chip, &a.sensor).cmp(&(&b.instance, &b.chip, &b.sensor))
        });
        let dcgm: BTreeMap<String, bool> = r(Q::Up)
            .iter()
            .filter(|s| s.labels.get("job").map(String::as_str) == Some("dcgm"))
            .filter_map(|s| s.instance().map(|i| (i.into(), s.value != 0.0)))
            .collect();
        let down = dcgm
            .iter()
            .filter(|(_, up)| !**up)
            .map(|(i, _)| i.clone())
            .collect();
        let fallback = self.fallback_for(down);
        let from_down = |s: &&PromSample| s.instance().is_some_and(|i| dcgm.get(i) == Some(&false));
        let mut metrics = Batch::new();
        for q in GPU_METRICS {
            metrics.insert(
                q,
                r(q).iter()
                    .filter(|s| !from_down(s))
                    .chain(fallback.get(&q).into_iter().flatten().filter(from_down))
                    .cloned()
                    .collect(),
            );
        }
        metrics.insert(Q::GpuAgeFresh, r(Q::GpuAgeFresh).to_vec());
        metrics.insert(
            Q::GpuAgeDeep,
            fallback
                .get(&Q::GpuAgeDeep)
                .into_iter()
                .flatten()
                .filter(from_down)
                .cloned()
                .collect(),
        );
        Ok(Snapshot {
            at: (self.0.now)(),
            nodes,
            gpus: build_gpus(&metrics, &dcgm),
            temps,
            fetch_millis: started.elapsed().as_millis(),
            hypervisor: self.0.cfg.hypervisor.clone(),
        })
    }
}
const GPU_METRICS: [Q; 8] = [
    Q::GpuTemp,
    Q::GpuUtil,
    Q::GpuFbUsed,
    Q::GpuFbFree,
    Q::GpuPower,
    Q::GpuSmClock,
    Q::GpuMemClock,
    Q::GpuMemTemp,
];
fn label(s: &PromSample, key: &str, fallback: &str) -> String {
    s.labels
        .get(key)
        .map(String::as_str)
        .unwrap_or(fallback)
        .into()
}
fn gpu_key(s: &PromSample) -> String {
    format!(
        "{}/{}",
        s.instance().unwrap_or("?"),
        ["UUID", "gpu", "device"]
            .iter()
            .find_map(|k| s.labels.get(*k).map(String::as_str))
            .unwrap_or("0")
    )
}
fn build_gpus(metrics: &Batch, dcgm: &BTreeMap<String, bool>) -> Vec<GpuStat> {
    let mut seeds: Vec<(String, &PromSample)> = Vec::new();
    // Every field can prove a GPU exists. Losing temperature must only blank
    // temperature, not erase the entire card.
    for q in GPU_METRICS
        .into_iter()
        .chain([Q::GpuAgeFresh, Q::GpuAgeDeep])
    {
        for s in &metrics[&q] {
            let key = gpu_key(s);
            if !seeds.iter().any(|(k, _)| *k == key) {
                seeds.push((key, s));
            }
        }
    }
    // Temperature metadata consistently carries modelName and UUID.
    for s in &metrics[&Q::GpuTemp] {
        let key = gpu_key(s);
        if let Some((_, seed)) = seeds.iter_mut().find(|(k, _)| *k == key) {
            *seed = s;
        }
    }
    let mut out: Vec<_> = seeds
        .into_iter()
        .map(|(key, s)| {
            let v = |q| {
                metrics[&q]
                    .iter()
                    .rev()
                    .find(|s| gpu_key(s) == key)
                    .map(|s| s.value)
            };
            let inst = s.instance().unwrap_or("?");
            GpuStat {
                gpu: label(s, "gpu", "0"),
                instance: inst.into(),
                model: label(s, "modelName", "GPU"),
                uuid: s.labels.get("UUID").cloned(),
                exporter_up: *dcgm.get(inst).unwrap_or(&false),
                age_seconds: v(Q::GpuAgeFresh).or_else(|| v(Q::GpuAgeDeep)),
                temp: v(Q::GpuTemp),
                mem_temp: v(Q::GpuMemTemp),
                util: v(Q::GpuUtil),
                fb_used_mib: v(Q::GpuFbUsed),
                fb_free_mib: v(Q::GpuFbFree),
                power_watts: v(Q::GpuPower),
                sm_clock_mhz: v(Q::GpuSmClock),
                mem_clock_mhz: v(Q::GpuMemClock),
            }
        })
        .collect();
    out.sort_by(|a, b| {
        a.instance.cmp(&b.instance).then_with(|| {
            match (a.gpu.parse::<i64>(), b.gpu.parse::<i64>()) {
                (Ok(a), Ok(b)) => a.cmp(&b),
                _ => a.gpu.cmp(&b.gpu),
            }
        })
    });
    out
}
