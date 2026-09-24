//! Exercise actual Slint layout as well as the Rust scene boxes. Implicit child
//! centering once moved whole panels and made correctly positioned text drift.
#[allow(dead_code)]
mod fake_prometheus;

use fake_prometheus::FakePrometheus;
use rackglass::{
    Config, MetricsStore,
    ui::{
        AppWindow, InkAlign, InkKind,
        chart::{Chart, ChartCache},
        dashboard, nodes,
    },
};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter};
use slint::{ComponentHandle, Model, PhysicalSize, Rgb8Pixel};
use std::rc::Rc;

struct Offscreen(Rc<MinimalSoftwareWindow>);
impl Platform for Offscreen {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.0.clone())
    }
}
fn render(surface: &MinimalSoftwareWindow) -> Vec<Rgb8Pixel> {
    let mut pixels = vec![Rgb8Pixel::default(); 1024 * 600];
    surface.request_redraw();
    slint::platform::update_timers_and_animations();
    surface.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, 1024);
    });
    pixels
}
fn gray_at(pixels: &[Rgb8Pixel], x: usize, y: usize) -> u8 {
    let pixel = pixels[y * 1024 + x];
    assert_eq!(pixel.r, pixel.g);
    assert_eq!(pixel.g, pixel.b);
    pixel.r
}

#[test]
fn frozen_panel_positions_left_growing_bars_and_target_selection() {
    let surface = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(Offscreen(surface.clone()))).unwrap();
    surface.set_size(PhysicalSize::new(1024, 600));
    let window = AppWindow::new().unwrap();
    window.show().unwrap();
    window.set_boot(false);
    let prometheus = FakePrometheus::new(false);
    let store = MetricsStore::new(
        Config {
            prom_url: prometheus.url.clone(),
            ..Config::default()
        },
        prometheus.client(),
    );
    store.refresh().unwrap().join().unwrap();
    let state = store.state();
    dashboard::update(&window, &state);
    let pixels = render(&surface);
    // Top panels begin immediately below the tabs and end at 58 + 196.
    assert_eq!(gray_at(&pixels, 6, 58), 86);
    assert_eq!(gray_at(&pixels, 100, 253), 86);
    assert_eq!(gray_at(&pixels, 100, 259), 0);
    assert_eq!(gray_at(&pixels, 400, 260), 86);
    // The CPU is only 9% full. A centred fill would leave this first pixel dark.
    assert!(gray_at(&pixels, 65, 152) > 150);
    assert_eq!(gray_at(&pixels, 160, 152), 78);
    let name = window
        .get_dash_rows()
        .iter()
        .find(|item| item.text == "vm-node-1")
        .unwrap();
    assert_eq!(name.align, InkAlign::Left);
    assert_eq!(name.weight, 500);

    window.set_mode(2);
    nodes::update(
        &window,
        &state,
        "pve-host",
        &std::array::from_fn::<_, 4, _>(|_| Chart::default()),
        &mut ChartCache::default(),
        false,
    );
    let pixels = render(&surface);
    assert_eq!(gray_at(&pixels, 6, 200), 86);
    assert_eq!(gray_at(&pixels, 12, 78), 255);
    assert_eq!(gray_at(&pixels, 250, 129), 255);
    assert_eq!(gray_at(&pixels, 250, 132), 0);
    assert_eq!(
        gray_at(&pixels, 250, 145),
        0,
        "only the selected tile is inverted"
    );
    // Chip labels must start beyond the complete 14-cell sensor gauge.
    let detail: Vec<_> = window.get_node_detail().iter().collect();
    for gauge in detail
        .iter()
        .filter(|item| item.kind == InkKind::Bar && item.x == 458.)
    {
        assert!((gauge.w - 134.4).abs() < 0.001);
        let chip = detail
            .iter()
            .find(|item| {
                item.kind == InkKind::Text
                    && item.x > gauge.x
                    && (item.y - gauge.y - 1.95).abs() < 0.01
            })
            .unwrap();
        assert!(chip.x >= gauge.x + gauge.w + 8.);
        assert_eq!(chip.align, InkAlign::Left);
    }
    // Dynamic Ink weights must reach the renderer, not just the scene model.
    let mut labels = rackglass::ui::scene::Scene::default();
    for (row, weight) in [400, 500, 700].into_iter().enumerate() {
        labels.text(
            10.,
            20. + row as f32 * 40.,
            300.,
            "vm-amnezia-proxy 47%",
            16.,
            0xffffff,
            weight,
        );
    }
    window.set_mode(0);
    window.set_dash_cpu(rackglass::ui::scene::model(labels.0));
    let pixels = render(&surface);
    let ink: Vec<u64> = (0..3)
        .map(|row| {
            (78 + row * 40..99 + row * 40)
                .flat_map(|y| (16..316).map(move |x| (x, y)))
                .map(|(x, y)| pixels[y * 1024 + x].r as u64)
                .sum()
        })
        .collect();
    assert!(
        ink[1] > ink[0] && ink[2] > ink[1],
        "font weights collapsed: {ink:?}"
    );
    window.set_mode(3);
    window.set_capture_running(true);
    window.set_capture_show_frame(true);
    window.set_capture_frame(slint::Image::from_rgb8(
        slint::SharedPixelBuffer::<Rgb8Pixel>::clone_from_slice(&[255u8; 12], 2, 2),
    ));
    let pixels = render(&surface);
    assert_eq!(gray_at(&pixels, 7, 60), 255, "STOP starts at the left edge");
    assert_eq!(
        gray_at(&pixels, 512, 300),
        255,
        "the capture image is visible"
    );
    assert_eq!(
        gray_at(&pixels, 11, 300),
        0,
        "capture is letterboxed, never stretched"
    );
}
