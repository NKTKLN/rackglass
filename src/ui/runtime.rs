//! Visible screens own range requests and capture; the clock only ticks once
//! a second. Store and capture callbacks coalesce onto the Slint event thread.
use super::{
    AppWindow, capture_view,
    chart::{Chart, ChartCache},
    dashboard,
    history::{self, Colors, RequestGuard, Ticket},
    layout::*,
    nodes,
    scene::{model, sync_ink},
};
use crate::{
    Config, MetricsStore, PromClient,
    capture::CaptureController,
    fmt::fmt_duration,
    prom::client::{PromError, PromSeries},
    store::StoreState,
};
use chrono::{Local, TimeDelta, Utc};
use slint::{ComponentHandle, Timer, TimerMode};
use std::{
    cell::RefCell,
    rc::{Rc, Weak},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

thread_local! {
    static ACTIVE: RefCell<Weak<RefCell<Runtime>>> = const { RefCell::new(Weak::new()) };
}
fn with_runtime(f: impl FnOnce(&mut Runtime)) {
    ACTIVE.with(|active| {
        if let Some(runtime) = active.borrow().upgrade() {
            f(&mut runtime.borrow_mut());
        }
    });
}
fn post(f: impl FnOnce(&mut Runtime) + Send + 'static) {
    let _ = slint::invoke_from_event_loop(move || with_runtime(f));
}
#[derive(Default)]
struct Drag {
    start_y: f32,
    start_offset: f32,
    last_y: f32,
    last_time: Option<Instant>,
    velocity: f32,
    moved: bool,
}
/// Coast lasts 180ms, with the same capped launch velocity as the Flutter panel.
pub fn fling_distance(velocity: f32) -> f32 {
    velocity.clamp(-1200., 1200.) * 0.09
}
pub struct Runtime {
    window: slint::Weak<AppWindow>,
    store: MetricsStore,
    capture: CaptureController,
    state: StoreState,
    graph_guard: RequestGuard,
    node_guard: RequestGuard,
    colors: Colors,
    cache: ChartCache,
    range: usize,
    selected: String,
    node_charts: [Chart; 4],
    last_graph: Option<Instant>,
    last_node: Option<Instant>,
    last_frame: Option<(u64, u64)>,
    drags: [Drag; 3],
    clock: Timer,
    boot_timer: Timer,
}
impl Runtime {
    pub fn attach(window: &AppWindow, cfg: Config) -> Rc<RefCell<Self>> {
        let store = MetricsStore::new(cfg.clone(), PromClient::new(&cfg.prom_url));
        let capture = CaptureController::new(cfg.clone());
        let state = store.state();
        let runtime = Rc::new(RefCell::new(Self {
            window: window.as_weak(),
            store,
            capture,
            state,
            graph_guard: RequestGuard::default(),
            node_guard: RequestGuard::default(),
            colors: Colors::default(),
            cache: ChartCache::default(),
            range: 1,
            selected: String::new(),
            node_charts: empty_node_charts(true),
            last_graph: None,
            last_node: None,
            last_frame: None,
            drags: Default::default(),
            clock: Timer::default(),
            boot_timer: Timer::default(),
        }));
        ACTIVE.with(|active| *active.borrow_mut() = Rc::downgrade(&runtime));
        window.on_select_mode(|mode| with_runtime(|runtime| runtime.select_mode(mode)));
        window.on_select_range(|i| {
            with_runtime(|runtime| {
                if runtime.range != i as usize {
                    runtime.range = i.clamp(0, 4) as usize;
                    runtime.load_graphs();
                }
            })
        });
        window.on_reload_range(|| with_runtime(Self::load_graphs));
        window.on_refresh(|| {
            with_runtime(|runtime| {
                runtime.store.refresh();
            })
        });
        window.on_capture_toggle(|| {
            with_runtime(|runtime| {
                if runtime.capture.state().running {
                    runtime.capture.stop();
                } else {
                    runtime.capture.start();
                }
            })
        });
        window.on_capture_fullscreen(|v| {
            with_runtime(|runtime| {
                if let Some(window) = runtime.window.upgrade() {
                    window.set_video_full(v && window.get_mode() == 3);
                    runtime.update_capture();
                }
            })
        });
        window.on_scroll(|which, kind, y| {
            with_runtime(|runtime| runtime.scroll(which as usize, kind, y))
        });
        window.on_quit(|| {
            let _ = slint::quit_event_loop();
        });
        {
            let runtime = runtime.borrow();
            runtime
                .store
                .on_change(Box::new(|| post(Self::store_changed)));
            // Coalesce UI delivery too: a 30fps worker never builds an unbounded
            // event queue when the software renderer temporarily falls behind.
            let pending = Arc::new(AtomicBool::new(false));
            runtime.capture.on_change(move || {
                if pending.swap(true, Ordering::AcqRel) {
                    return;
                }
                let pending = pending.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    pending.store(false, Ordering::Release);
                    with_runtime(Self::update_capture);
                });
            });
            runtime
                .clock
                .start(TimerMode::Repeated, Duration::from_secs(1), || {
                    with_runtime(Self::tick)
                });
            let script = [
                "rackglass 1.0.0  ·  prometheus + hdmi capture".to_owned(),
                "panel     1024x600 @ 7\"".into(),
                format!("endpoint  {}", cfg.prom_url),
                "probing scrape targets ......... ok".into(),
                "loading node_exporter series ... ok".into(),
                "loading dcgm series ............ ok".into(),
                "ready.".into(),
            ];
            let started = Instant::now();
            runtime
                .boot_timer
                .start(TimerMode::Repeated, Duration::from_millis(170), move || {
                    with_runtime(|runtime| {
                        let Some(window) = runtime.window.upgrade() else {
                            return;
                        };
                        if !window.get_boot() {
                            runtime.boot_timer.stop();
                            return;
                        }
                        let elapsed = started.elapsed();
                        let count = (elapsed.as_millis() / 170).min(7) as usize;
                        window.set_boot_lines(model(
                            script[..count].iter().map(|s| s.into()).collect(),
                        ));
                        if elapsed >= Duration::from_millis(1710) {
                            window.set_boot(false);
                            runtime.boot_timer.stop();
                        }
                    })
                });
            dashboard::status(window, &runtime.state, Local::now());
            runtime.store.start();
        }
        runtime
    }
    fn select_mode(&mut self, mode: i32) {
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let mode = mode.clamp(0, 3);
        let old = window.get_mode();
        if old == mode {
            return;
        }
        if old == 1 {
            self.graph_guard.deactivate();
        }
        if old == 2 {
            self.node_guard.deactivate();
        }
        if old == 3 {
            self.capture.stop();
            self.last_frame = None;
            window.set_capture_frame(Default::default());
        }
        window.set_mode(mode);
        if mode != 3 {
            window.set_video_full(false);
        }
        self.state = self.store.state();
        match mode {
            0 => dashboard::update(&window, &self.state),
            1 => {
                self.graph_guard.activate();
                self.load_graphs();
            }
            2 => {
                self.node_guard.activate();
                self.last_node = None;
                self.ensure_selected();
                self.load_node();
                self.update_nodes();
            }
            3 => {
                self.capture.start();
                self.update_capture();
            }
            _ => {}
        }
    }
    fn store_changed(&mut self) {
        self.state = self.store.state();
        if let Some(window) = self.window.upgrade() {
            dashboard::status(&window, &self.state, Local::now());
            match window.get_mode() {
                0 => dashboard::update(&window, &self.state),
                2 => {
                    let changed = self.ensure_selected();
                    if changed || (!self.node_guard.loading && self.last_node.is_none()) {
                        self.load_node();
                    }
                    self.update_nodes();
                }
                _ => {}
            }
        }
    }
    fn tick(&mut self) {
        let was_stale = self.state.stale;
        self.state = self.store.state();
        if let Some(window) = self.window.upgrade() {
            dashboard::status(&window, &self.state, Local::now());
            if was_stale != self.state.stale && window.get_mode() == 0 {
                dashboard::update(&window, &self.state);
            }
            if window.get_mode() == 1
                && !self.graph_guard.loading
                && self
                    .last_graph
                    .is_none_or(|t| t.elapsed() >= Duration::from_secs(60))
            {
                self.load_graphs();
            }
            if window.get_mode() == 2
                && !self.node_guard.loading
                && self
                    .last_node
                    .is_none_or(|t| t.elapsed() >= Duration::from_secs(60))
            {
                self.load_node();
            }
        }
    }
    fn load_graphs(&mut self) {
        let Some(ticket) = self.graph_guard.begin(self.range.to_string()) else {
            return;
        };
        let window_seconds = history::WINDOWS[self.range];
        let end = Utc::now();
        let store = self.store.clone();
        if let Some(window) = self.window.upgrade() {
            window.set_range_index(self.range as i32);
            window.set_range_step(
                fmt_duration(
                    TimeDelta::from_std(MetricsStore::step_for(Duration::from_secs(
                        window_seconds,
                    )))
                    .ok(),
                )
                .into(),
            );
            window.set_range_status("LOADING…".into());
        }
        std::thread::spawn(move || {
            let result =
                history::load_batch(&store, &history::graph_queries(), window_seconds, end);
            post(move |runtime| runtime.finish_graphs(ticket, result, window_seconds, end));
        });
    }
    fn finish_graphs(
        &mut self,
        ticket: Ticket,
        result: Result<Vec<Vec<PromSeries>>, PromError>,
        window_seconds: u64,
        end: chrono::DateTime<Utc>,
    ) {
        if !self.graph_guard.finish(&ticket) {
            return;
        }
        self.last_graph = Some(Instant::now());
        let Some(window) = self.window.upgrade() else {
            return;
        };
        match result {
            Ok(data) => {
                let charts = history::graph_charts(&data, window_seconds, end, &mut self.colors);
                present_graphs(&window, &charts, &mut self.cache);
                window.set_range_status("OK".into());
            }
            Err(e) => window.set_range_status(format!("RANGE QUERY FAILED: {e}").into()),
        }
    }
    fn ensure_selected(&mut self) -> bool {
        let key = nodes::selected(&self.state, &self.selected)
            .map(|n| n.instance.clone())
            .unwrap_or_default();
        if key == self.selected {
            return false;
        }
        self.selected = key;
        self.node_charts = empty_node_charts(true);
        true
    }
    fn load_node(&mut self) {
        self.ensure_selected();
        let Some(snap) = &self.state.snapshot else {
            return;
        };
        let Some(n) = nodes::selected(&self.state, &self.selected) else {
            return;
        };
        let queries = history::node_queries(
            &n.instance,
            !snap.temps_for(&n.instance).is_empty(),
            !snap.gpus_for(&n.instance).is_empty(),
        );
        let up = n.up;
        let key = n.instance.clone();
        if self.node_guard.key != key {
            self.node_charts = empty_node_charts(up);
        }
        let Some(ticket) = self.node_guard.begin(key) else {
            return;
        };
        self.update_nodes();
        let store = self.store.clone();
        let end = Utc::now();
        std::thread::spawn(move || {
            let result = history::load_batch(&store, &queries, 3600, end);
            post(move |runtime| {
                if !runtime.node_guard.finish(&ticket) {
                    return;
                }
                runtime.node_charts = result
                    .map(|data| history::node_charts(&data, end, up))
                    .unwrap_or_else(|_| empty_node_charts(up));
                runtime.last_node = Some(Instant::now());
                runtime.update_nodes();
            });
        });
    }
    fn update_nodes(&mut self) {
        if let Some(window) = self.window.upgrade() {
            nodes::update(
                &window,
                &self.state,
                &self.selected,
                &self.node_charts,
                &mut self.cache,
                self.node_guard.loading,
            );
        }
    }
    fn update_capture(&mut self) {
        let Some(window) = self.window.upgrade() else {
            return;
        };
        if window.get_mode() != 3 {
            return;
        }
        let c = self.capture.state();
        let frame_key = c.frame.as_ref().map(|_| (c.generation, c.frames_total));
        if self.last_frame != frame_key {
            window.set_capture_frame(
                c.frame
                    .as_ref()
                    .map(|f| capture_view::frame_image(f))
                    .unwrap_or_default(),
            );
            self.last_frame = frame_key;
        }
        capture_view::update(&window, &c);
    }
    fn scroll(&mut self, which: usize, kind: i32, y: f32) {
        if which >= 3 {
            return;
        }
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let (offset, content, viewport) = match which {
            0 => (
                window.get_table_offset(),
                window.get_rows_height(),
                TABLE_VIEWPORT,
            ),
            1 => (
                window.get_targets_offset(),
                window.get_targets_height(),
                TARGETS_VIEWPORT,
            ),
            _ => (
                window.get_detail_offset(),
                window.get_detail_height(),
                DETAIL_VIEWPORT,
            ),
        };
        let minimum = (viewport - content).min(0.);
        let now = Instant::now();
        let d = &mut self.drags[which];
        let mut next = offset;
        let mut coast = false;
        let mut pick = None;
        match kind {
            0 => {
                *d = Drag {
                    start_y: y,
                    last_y: y,
                    start_offset: offset,
                    last_time: Some(now),
                    ..Default::default()
                };
            }
            1 => {
                if let Some(t) = d.last_time {
                    let dt = now.duration_since(t).as_secs_f32();
                    if dt > 0. {
                        d.velocity = ((y - d.last_y) / dt).clamp(-1200., 1200.);
                    }
                }
                d.moved |= (y - d.start_y).abs() > 4.;
                next = d.start_offset + y - d.start_y;
                d.last_y = y;
                d.last_time = Some(now);
            }
            2 => {
                if d.moved {
                    coast = true;
                    let v = if d
                        .last_time
                        .is_some_and(|t| now.duration_since(t) < Duration::from_millis(100))
                    {
                        d.velocity
                    } else {
                        0.
                    };
                    next = offset + fling_distance(v);
                } else if which == 1 {
                    pick = Some(((y - offset) / nodes::TARGET_STRIDE).floor() as usize);
                }
                d.last_time = None;
            }
            4 => {
                next = offset + y;
            }
            _ => {
                d.last_time = None;
            }
        }
        next = next.clamp(minimum, 0.);
        match which {
            0 => {
                window.set_table_coast(coast);
                window.set_table_offset(next);
            }
            1 => {
                window.set_targets_coast(coast);
                window.set_targets_offset(next);
            }
            _ => {
                window.set_detail_coast(coast);
                window.set_detail_offset(next);
            }
        }
        if let Some(index) = pick
            && let Some(n) = self
                .state
                .snapshot
                .as_ref()
                .and_then(|s| s.nodes.get(index))
            && n.instance != self.selected
        {
            self.selected = n.instance.clone();
            self.last_node = None;
            window.set_detail_coast(false);
            window.set_detail_offset(0.);
            self.load_node();
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.store.stop();
        self.capture.stop();
    }
}
pub fn empty_node_charts(up: bool) -> [Chart; 4] {
    history::node_charts(&vec![vec![]; 5], Utc::now(), up)
}
pub fn present_graphs(window: &AppWindow, charts: &[Chart; 4], cache: &mut ChartCache) {
    let [util, temp, memory, speed] = charts
        .each_ref()
        .map(|c| cache.render(c, GRAPH_CHART.0, GRAPH_CHART.1));
    sync_ink(window.get_graph_util(), util, |m| window.set_graph_util(m));
    sync_ink(window.get_graph_temp(), temp, |m| window.set_graph_temp(m));
    sync_ink(window.get_graph_memory(), memory, |m| {
        window.set_graph_memory(m)
    });
    sync_ink(window.get_graph_speed(), speed, |m| {
        window.set_graph_speed(m)
    });
}
