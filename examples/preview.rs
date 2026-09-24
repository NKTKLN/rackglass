//! Renders every screen offscreen against the fake cluster and writes PNGs to
//! target/preview/, the same states the Flutter version was approved in. This is
//! how a visual change gets reviewed: compare against tests/reference/.
//!
//!   cargo run --release --example preview

#[path = "../tests/fake_prometheus.rs"]
#[allow(dead_code)]
mod fake_prometheus;

use chrono::{Local, Utc};
use fake_prometheus::FakePrometheus;
use rackglass::capture::{CaptureDevice, CaptureMode, CaptureSnapshot, CaptureState, Frame};
use rackglass::ui::{
    AppWindow, capture_view, chart::ChartCache, dashboard, history, nodes, runtime::present_graphs,
};
use rackglass::{Config, MetricsStore};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter};
use slint::{ComponentHandle, PhysicalSize, Rgb8Pixel};
use std::{error::Error, fs, path::Path, rc::Rc, sync::Arc, time::Duration};

const W: u32 = 1024;
const H: u32 = 600;

struct Offscreen(Rc<MinimalSoftwareWindow>);

impl Platform for Offscreen {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.0.clone())
    }
}

/// Polls the fake cluster enough times for the sparklines to have a shape.
fn store_for(prom: &FakePrometheus) -> MetricsStore {
    let cfg = Config {
        prom_url: prom.url.clone(),
        ..Config::default()
    };
    let store = MetricsStore::new(cfg, prom.client());
    for _ in 0..2 {
        if let Some(poll) = store.refresh() {
            poll.join().expect("poll thread");
        }
    }
    store
}

fn shoot(window: &MinimalSoftwareWindow, out: &Path, name: &str) -> Result<(), Box<dyn Error>> {
    let mut pixels = vec![Rgb8Pixel::default(); (W * H) as usize];
    window.request_redraw();
    slint::platform::update_timers_and_animations();
    window.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, W as usize);
    });
    let rgb: Vec<u8> = pixels.iter().flat_map(|p| [p.r, p.g, p.b]).collect();
    let file = fs::File::create(out.join(name))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), W, H);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header()?.write_image_data(&rgb)?;
    println!("wrote {}", out.join(name).display());
    Ok(())
}

/// A console-like test card: dark background with a few bright text rows, so
/// the signal check reads it as a live picture.
fn synthetic_frame() -> Frame {
    let (width, height) = (W, H);
    let mut rgb = vec![0u8; (width * height * 3) as usize];
    for y in 0..height {
        for x in 0..width {
            let i = ((y * width + x) * 3) as usize;
            let band = (x * 7 / width) as u8;
            let text_row = y % 24 < 14 && (y / 24) % 3 == 1 && x % 12 < 8 && x < 700;
            let (r, g, b) = if text_row {
                (200, 200, 200)
            } else if y < 40 {
                (band * 30, 60, 120)
            } else {
                (10, 12, 16)
            };
            rgb[i..i + 3].copy_from_slice(&[r, g, b]);
        }
    }
    Frame { width, height, rgb }
}

fn main() -> Result<(), Box<dyn Error>> {
    let out = Path::new("target/preview");
    fs::create_dir_all(out)?;

    let surface = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(Offscreen(surface.clone())))
        .map_err(|e| format!("{e:?}"))?;
    surface.set_size(PhysicalSize::new(W, H));

    let window = AppWindow::new()?;
    window.show()?;
    window.set_boot(false);

    let mut cache = ChartCache::default();

    // DASH with the GPU exporter down, then live.
    for (gpu_up, name) in [
        (false, "01-dash-gpu-down.png"),
        (true, "02-dash-gpu-live.png"),
    ] {
        let prom = FakePrometheus::new(gpu_up);
        let store = store_for(&prom);
        let state = store.state();
        window.set_mode(0);
        dashboard::update(&window, &state);
        dashboard::status(&window, &state, Local::now());
        shoot(&surface, out, name)?;
    }

    // GRAPHS and NODES against the live cluster.
    let prom = FakePrometheus::new(true);
    let store = store_for(&prom);
    let state = store.state();
    dashboard::status(&window, &state, Local::now());
    let end = Utc::now();

    let window_secs = 3600;
    let data = history::load_batch(&store, &history::graph_queries(), window_secs, end)?;
    let mut colors = history::Colors::default();
    let charts = history::graph_charts(&data, window_secs, end, &mut colors);
    window.set_mode(1);
    present_graphs(&window, &charts, &mut cache);
    shoot(&surface, out, "03-graphs.png")?;

    let node_prom = FakePrometheus::new(false);
    let node_store = store_for(&node_prom);
    let state = node_store.state();
    let snapshot = state
        .snapshot
        .as_ref()
        .ok_or("no snapshot from fake cluster")?;
    let host = snapshot.nodes.iter().find(|n| n.instance == "pve-host");
    let guest = snapshot.nodes.iter().find(|n| n.instance == "vm-node-1");
    window.set_mode(2);
    for (node, name) in [(host, "04-nodes-host.png"), (guest, "05-nodes-guest.png")] {
        let node = node.ok_or("fake cluster lacks a host or guest")?;
        let temps = !snapshot.temps_for(&node.instance).is_empty();
        let gpus = !snapshot.gpus_for(&node.instance).is_empty();
        let queries = history::node_queries(&node.instance, temps, gpus);
        let data = history::load_batch(&node_store, &queries, 3600, end)?;
        let mut charts = history::node_charts(&data, end, node.up);
        // The frozen guest reference captures the empty CPU-history state.
        if node.instance == "vm-node-1" {
            charts[0].series.clear();
        }
        nodes::update(&window, &state, &node.instance, &charts, &mut cache, false);
        shoot(&surface, out, name)?;
    }

    // CAPTURE with a synthetic live frame.
    let device = CaptureDevice {
        path: "/dev/video0".into(),
        name: "USB Video: USB Video".into(),
    };
    let capture = CaptureSnapshot {
        state: CaptureState::Streaming,
        error: None,
        frame: Some(Arc::new(synthetic_frame())),
        mode: CaptureMode {
            width: W,
            height: H,
            fps: 30,
        },
        device: Some(device.clone()),
        devices: vec![device],
        running: true,
        frames_total: 1843,
        frames_dropped: 0,
        decode_errors: 0,
        bytes_total: 271_000_000,
        fps: 29.8,
        uptime: Some(Duration::from_secs(61)),
        stderr_tail: Vec::new(),
        generation: 1,
    };
    window.set_mode(3);
    capture_view::update(&window, &capture);
    window.set_capture_frame(capture_view::frame_image(capture.frame.as_deref().unwrap()));
    shoot(&surface, out, "06-capture.png")?;

    // Match the initial boot frame captured by Flutter, before the first tick.
    window.set_boot_lines(Default::default());
    window.set_boot(true);
    shoot(&surface, out, "07-boot.png")?;

    Ok(())
}
