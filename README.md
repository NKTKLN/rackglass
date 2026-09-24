# 📟 Rackglass

[![Rust](https://img.shields.io/badge/Rust-2024-000000?logo=rust&logoColor=white)](https://www.rust-lang.org/)
[![Slint](https://img.shields.io/badge/Slint-1.18-2379F4)](https://slint.dev/)
[![Linux](https://img.shields.io/badge/Linux-KMS-FCC624?logo=linux&logoColor=black)](https://docs.slint.dev/latest/docs/slint/guide/backends-and-renderers/backend_linuxkms/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Proxmox](https://img.shields.io/badge/Proxmox-VE-E57000?logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![NVIDIA DCGM](https://img.shields.io/badge/NVIDIA-DCGM-76B900?logo=nvidia&logoColor=white)](https://github.com/NVIDIA/dcgm-exporter)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-007808?logo=ffmpeg&logoColor=white)](https://ffmpeg.org/)
[![V4L2](https://img.shields.io/badge/V4L2-MJPEG-555555?logo=linux&logoColor=white)](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-FE5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Made with Claude Code](https://img.shields.io/badge/Made%20with-Claude%20Code-D97757?logo=anthropic&logoColor=white)](https://claude.com/claude-code)

**Rackglass** is a terminal-style Prometheus dashboard for a 7" 1024x600 panel
sitting on a desk next to the rack. Plain Linux console look: black background,
grey-white text, box-drawing frames, block-character bars. No phosphor tint, no
glow, no scanlines.

It is built against one real cluster — a Proxmox host (`pve-host`, 12 cores /
32 GiB) with four guests and a Tesla V100 behind dcgm-exporter — and the design
follows from that: an exporter on this cluster is down often enough that
*telling live numbers from remembered ones* is the feature, not an edge case.
That cluster, and the exporters this reads, are set up and documented in
[NKTKLN/homelab](https://github.com/NKTKLN/homelab).

The same panel also carries a live view from a USB HDMI capture card, so the
machine being monitored can be watched booting on the screen that monitors it.

![DASH](docs/screenshots/dash.png)

## 📦 Dependencies

* [Rust](https://www.rust-lang.org/tools/install), edition 2024 (1.85 or newer)
* [ffmpeg](https://ffmpeg.org/) — spawned as a child process for V4L2 capture
* `fontconfig` headers for any build; for the `kms` build (straight to the
  display, no X or Wayland) also `libinput`, `libgbm`, `libdrm`, `libudev`,
  `libseat` and `libxkbcommon`

Runtime services it reads:

* [Prometheus](https://prometheus.io/) — the only data source; nothing is
  scraped directly
* [node_exporter](https://github.com/prometheus/node_exporter) under
  `job="node"` — hypervisor and guests
* [dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter) under `job="dcgm"` —
  GPU, may be down for days at a time
* a speedtest exporter publishing `speedtest_download_bits_per_second`

On Fedora:

```sh
sudo dnf install -y fontconfig-devel ffmpeg
```

and for the `kms` build:

```sh
sudo dnf install -y libinput-devel mesa-libgbm-devel libdrm-devel systemd-devel libseat-devel libxkbcommon-devel
```

## 🖥 Screens

| Key | Mode | What's on it |
| --- | --- | --- |
| `1` | **DASH** | Host CPU package temp and named hwmon sensors, CPU usage, load; GPU temp/util/VRAM/power; host memory and swap with the guest-reported RAM sum; one row per scrape target with CPU%, memory, sparklines, load, root fs, network, iowait, uptime |
| `2` | **GRAPHS** | Four range-query charts — CPU %, memory %, temperatures, speedtest download — over 15m / 1h / 6h / 24h / 7d |
| `3` | **NODES** | Master/detail per target: CPU, memory, root fs, network, boot time, a GPU section and hwmon list where the target has them, and separate CPU / memory / temperature / GPU history charts |
| `4` | **CAPTURE** | Live view from the USB capture card, letterboxed to fit: fullscreen, frame stats, and a no-signal banner for when the card streams black |

**GRAPHS** — range queries over a shared window. GPU keeps amber wherever it
appears, so it stays apart from the node series on a shared axis.

![GRAPHS](docs/screenshots/graphs.png)

**NODES** — one target at a time, with the glyph in the list carrying the worst
of its CPU, memory, root fs and GPU rather than a single number.

![NODES](docs/screenshots/nodes.png)

**CAPTURE** — the HDMI input, letterboxed, with the frame counters that say
whether the stream is healthy.

![CAPTURE](docs/screenshots/capture.png)

Other keys:

* `←` `→` — cycle modes
* `r` — force a refresh
* `Esc` — leave fullscreen
* `q` — quit

Every tab and button is also a touch target sized for a finger on a 7" screen.
There is no title bar: mode buttons, link state and the clock share one row,
because the app name and the endpoint told you nothing you could act on and the
row they cost is worth more to the data. The endpoint lives in the diagnostics
line at the bottom, next to the poll time.

## 🔧 Configuration

There is no settings screen — a kiosk panel has nobody in front of it to fill
one in. Configuration is read once at startup from a `KEY=VALUE` file and the
environment:

```sh
cp config.env.example config.env
$EDITOR config.env
```

The file is the first one found of `$RACKGLASS_CONFIG`, `./config.env` and
`/etc/rackglass/config.env`, and any key set in the environment wins over the
file. `config.env` is gitignored, so your endpoint and your topology stay out of
the repository. A one-off override needs no file at all:

```sh
PROM_URL=http://10.0.0.5:9090 cargo run
```

| Key | Default | What it is |
| --- | --- | --- |
| `PROM_URL` | `http://localhost:9090` | Prometheus base URL, no trailing slash |
| `POLL_SECONDS` | `5` | Seconds between polls; staleness is three of these |
| `NET_DEVICE_EXCLUDE` | `^(lo\|veth.*\|tap.*\|fwbr.*\|fwln.*\|fwpr.*\|vmbr.*\|docker.*\|br-.*\|virbr.*)$` | Interfaces kept out of network totals |
| `HYPERVISOR` | `pve-host` | The node_exporter instance that is the host; every other target is a guest |
| `CAPTURE_DEVICE` | `/dev/video0` | V4L2 node to capture from; empty to scan for one |
| `CAPTURE_W` | `1024` | Capture width requested from the card |
| `CAPTURE_H` | `600` | Capture height |
| `CAPTURE_FPS` | `30` | Capture frame rate |
| `FFMPEG` | `ffmpeg` | Binary used to read the capture device |

The default endpoint points at localhost on purpose: an unconfigured build
should fail to connect in a way you notice, rather than quietly querying
whatever answers at an address left in the source by someone else.

The interface exclusion matters on a Proxmox host: without it the same
forwarded packet is counted on the physical NIC, the bridge and the tap device,
and the host appears to be moving three times the traffic it is.

Two more environment variables control the window rather than the data:

* `RACKGLASS_FULLSCREEN` — any value except `0`, `false`, `no` or `off` drops the
  titlebar and goes fullscreen
* `SLINT_BACKEND` — overrides the backend the build picked, e.g.
  `winit-software` or `linuxkms-software`

## 🚀 Running

Development, in a window on the desktop:

```sh
cargo run
```

On the panel, drawing straight to the display through KMS with no X or Wayland
underneath:

```sh
cargo build --release --no-default-features --features kms
RACKGLASS_FULLSCREEN=1 ./target/release/rackglass
```

Without `RACKGLASS_FULLSCREEN` you get a normal 1024x600 window, which is the
exact panel size — what you see while developing is what lands on the device.

Everything is drawn by Slint's software renderer, which repaints only the
regions that changed. That choice comes from the Raspberry Pi 3B this runs on:
its GPU offers OpenGL ES 2.0 only, which Flutter, the previous implementation,
could not use, so the whole interface ended up rasterised through llvmpipe on
the CPU anyway. See [docs/raspberry-pi.md](docs/raspberry-pi.md) for the arm64
build and the Pi setup.

## 🧪 Tests

```sh
cargo test
```

The core tests drive the store against a fake Prometheus serving canned
responses for the whole cluster — including the down `vm-gpu-worker-1` target
and a DCGM exporter that is down with only seven-day history to fall back on.
The capture tests feed real JPEG fixtures through a fake ffmpeg process, and a
render test draws the app offscreen at 1024x600 and checks frozen panel
positions pixel by pixel.

There is also a live smoke test that checks every PromQL expression the UI
issues still returns usable data. It needs the server reachable, so it is off by
default:

```sh
RACKGLASS_LIVE_PROM_URL=http://10.0.0.5:9090 cargo test --test live_smoke -- --ignored
```

Every screen can be rendered to PNG against the fake cluster, which is how a
visual change gets reviewed — against the approved design in `tests/reference/`:

```sh
cargo run --release --example preview
```

## 📐 Layout

The panel is roughly 170 DPI and gets read at arm's length, so nothing is set
below 13px and body text is 16px — a real console on this screen runs an 8x16
font, and that is the floor the scale in `ui/theme.slint` is built around. Because
the type is large, screen density is a real constraint: panels carry a metric
per line rather than a stacked label-and-bar, and anything that did not fit
moved to NODES.

Everything is laid out against a fixed 1024x600 canvas and then scaled to the
window. The panel is pixel-perfect, larger windows get a proportionally
larger copy, and no arrangement of data can push a widget off screen.

Table columns are declared once as constants shared by the header and the rows,
so a column cannot be one width in the heading and another in the data.
Leftover row width is split evenly between column groups rather than pooling
into a single gap.

## 🎥 USB capture

The card on this desk (MACROSILICON `345f:2109`) exposes MJPG natively, so
ffmpeg runs as a pure stream copy — nothing is decoded, scaled or re-encoded in
the child process — and the app splits the concatenated JPEGs itself and decodes
each on a worker thread. Measured on the real device: 4–8% of one core for the child at
1024x600@30, all of it moving bytes rather than touching pixels.

The geometry is fixed rather than pickable. The card is flashed to offer
1024x600, the panel's own resolution, so the source arrives at exactly the size
the screen can show and nothing is captured only to be thrown away again on the
way to the display. That firmware, and how it was put on the stick, are in
[NKTKLN/ms2109-d7-1024x600](https://github.com/NKTKLN/ms2109-d7-1024x600) —
stock firmware offers no mode narrower than 16:9 at this height. Re-measured on the card after that reflash, against the same
source, every mode holds its rate:

| Mode | fps | Stream | Frame |
| --- | --- | --- | --- |
| 1920x1080@30 | 30.1 | 10.23 MB/s | 332 KB |
| 1280x720@30 | 30.1 | 5.98 MB/s | 194 KB |
| **1024x600@30** | 29.1 | 4.42 MB/s | 148 KB |
| 800x600@30 | 30.1 | 3.80 MB/s | 123 KB |

The figures are what the firmware emits, not what the resolution implies: this
card encodes at a generous quality, so a frame costs far more than a JPEG of
that size usually would, and the decode the app pays per frame scales with it.
Dropping from 720p to the panel's own 1024x600 takes about a third off both.

The picture is letterboxed to fit and nothing else. The card scales the source
into whatever mode it is asked for, so a 1:1 view magnified the capture rather
than revealing more of the source — it never held detail the fitted view did
not.

The node is named rather than discovered. A UVC stick exposes a capture node
and a metadata node side by side, and which index each gets is up to the order
the kernel probed them, so a reboot can swap them; on a panel with nobody in
front of it, a list of nodes to choose between is no help. `CAPTURE_DEVICE`
states which one it is, and nothing else is ever opened. Left empty it falls
back to scanning `/dev/video*` and stepping past nodes that reject capture.

Decoding keeps the newest frame and drops whatever arrived meanwhile; a queue
would only ever show progressively staler video. The stream runs while CAPTURE
is on screen and stops when it leaves, and every asynchronous step carries a
generation token so a late process exit or a decode finishing after a restart
cannot disturb the session that replaced it.

A capture card with nothing on its HDMI input streams valid black frames
forever, which is indistinguishable from a broken app, so the frame is
downscaled to 64x36 and averaged. The picture has to stay black for roughly
three seconds — 30 sampled frames — before the banner appears, since a fade or
one dark scene is not a lost signal, and the last good frame keeps showing
meanwhile. A returning source clears it with no hold at all.

## 📊 Handling missing data

This is most of the design. A dashboard that cannot tell a live reading from a
remembered one is worse than no dashboard, because you act on it.

**GPU metrics.** The exporter on this cluster is frequently down. Current DCGM
values are used while it is up, and `last_over_time(...[7d])` only while it is
down — so a single field vanishing from a healthy exporter renders `--` rather
than yesterday's number dressed as a reading. The seven-day scans are awaited
once, on the first poll that sees an exporter down, and refreshed in the
background from then on, so a slow TSDB scan never holds up node metrics that
are already in hand.

**Staleness age.** `timestamp()` loses the original sample time when it passes
through `last_over_time`, so the age needs its own expression — but a subquery
only evaluates on its own step boundaries, and its answer sawtooths from zero to
a full step. Measured against the live server it swung 0..300s while the true
age never passed 15s, which made a healthy GPU appear to drop out every few
minutes. A fresh series is therefore timed exactly with `time() - timestamp()`,
and the subquery is kept only for one that stopped long enough ago to fall out
of the lookback window, where minutes do not matter.

**Gaps stay gaps.** A failed poll or an absent target records a null sample, so
two readings either side of an outage are never drawn adjacent as though
monitoring had been continuous, and range charts break the line across a real
hole in the matrix instead of bridging it with a diagonal.

**Whole-snapshot staleness.** After 15 seconds without a successful poll the
dashboard dims and is marked `STALE`, rather than presenting the last good
values as current.

A stale GPU panel is drawn amber and badged `[ DOWN ]` with the age of its
readings. The same rule applies everywhere: a metric with no series renders
`--`, never `0`.

## 📁 Source layout

```
src/
  config.rs                runtime configuration, thresholds, staleness rules
  fmt.rs                   bars, sparklines, byte/rate/duration formatting
  prom/client.rs           Prometheus HTTP API v1 (instant + range)
  prom/queries.rs          every PromQL expression, in one place
  model.rs                 NodeStat / GpuStat / TempReading / Snapshot
  store.rs                 polling, history rings, range passthrough
  capture.rs               v4l2 capture: ffmpeg child, MJPEG framing, decode
  ui/                      scene building per screen, charts, lifecycle glue
ui/                        Slint markup: theme, components, the four screens
examples/preview.rs        offscreen render of every screen to PNG
tools/arm64/               podman cross-build for the Raspberry Pi
```

## 🤖 Built with Claude Code

This project was written with [Claude Code](https://claude.com/claude-code),
Anthropic's agentic coding tool. The measured figures in this README — capture
bandwidth per mode, child-process CPU, the 0..300s staleness sawtooth — come
from running against the real hardware and the live Prometheus server rather
than from estimation, and were taken on the Flutter version; the capture child is
unchanged in the Rust port, which was written with OpenAI Codex under Claude
Code's review.

## 📜 License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
