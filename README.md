# promterm

Terminal-style Prometheus dashboard for a 7" 1024x600 panel. Plain Linux
console look: black background, grey-white text, box-drawing frames,
block-character bars. No phosphor tint, no glow, no scanlines.

Built against the live setup at `http://192.168.1.13:9090`: a Proxmox host
(`pve-host`, 12 cores / 32 GiB) with four guests plus a Tesla V100 behind
dcgm-exporter.

## Modes

| Key | Mode | What's on it |
| --- | --- | --- |
| `1` | **DASH** | Host CPU package temp + hwmon sensors, CPU usage, load; GPU temp/util/VRAM/power; host memory and swap with the guest-reported RAM sum; one row per scrape target with CPU%, memory, sparklines, load, root fs, network, iowait, uptime |
| `2` | **GRAPHS** | Four range-query charts (CPU %, memory %, temperatures, speedtest download) over 15m / 1h / 6h / 24h / 7d |
| `3` | **NODES** | Master/detail per target: CPU, memory, root fs, network, boot time, a GPU section and hwmon list where the target has them, and separate CPU / memory / temperature / GPU history charts |
| `4` | **CAPTURE** | Live view from the USB capture card, letterboxed to fit: fullscreen, frame stats, and a no-signal banner for when the card streams black |

Other keys: `←` `→` cycle modes, `r` force a refresh, `q` / `Esc` quit. Every
tab and button is also a touch target sized for a finger on a 7" screen.

There is no title bar. Mode buttons, link state and the clock share one row —
the app name and the endpoint told you nothing you could act on, and the row
they cost is worth more to the data. The endpoint lives in the diagnostics line
at the bottom, next to the poll time.

## Typography

The panel is roughly 170 DPI and gets read at arm's length, so nothing is set
below 13px and body text is 16px — a real console on this screen runs an 8x16
font, and that is the floor the scale in `theme.dart` is built around. Because
the type is large, screen density is a real constraint: panels carry a metric
per line rather than a stacked label-and-bar, and anything that did not fit
moved to NODES.

## Running

```sh
flutter run -d linux
```

Point it somewhere else at build time:

```sh
flutter run -d linux --dart-define=PROM_URL=http://10.0.0.5:9090
```

Network totals exclude loopback and common virtual/bridge devices by default
(`veth*`, `tap*`, `fw*`, `vmbr*`, Docker/libvirt bridges) so forwarded traffic
is not counted twice on a Proxmox host. Override the regex at build time when
your interface topology differs:

```sh
flutter run -d linux --dart-define=NET_DEVICE_EXCLUDE='^(lo|docker.*)$'
```

### On the panel

```sh
flutter build linux --release
PROMTERM_FULLSCREEN=1 ./build/linux/x64/release/bundle/promterm
```

`PROMTERM_FULLSCREEN` drops the titlebar and goes fullscreen. Without it you get
a normal 1024x600 window, which is the exact panel size — what you see while
developing is what lands on the device.

Build dependencies on Fedora:

```sh
sudo dnf install -y clang cmake ninja-build gtk3-devel
```

## Layout

Everything is laid out against a fixed 1024x600 canvas and then scaled with a
`FittedBox`. The panel is pixel-perfect, larger windows get a proportionally
larger copy, and no arrangement of data can push a widget off screen.

Table columns are declared once as constants shared by the header and the rows,
and a test asserts they still share an edge.

`test/overlap_test.dart` goes further: on every mode it collects the rect of
each visible `Text` and fails if any two share pixels. That is the failure mode
no overflow check catches — a panel title sitting on the first row of content, a
label with no room to ellipsize — and it looks broken on the panel while every
other test stays green. Panel titles hang off the top border, so `TermPanel`
exposes the `titleGutter` its callers must leave for them.

## USB capture

The card on this desk (MACROSILICON `345f:2109`) exposes MJPG natively, so
ffmpeg runs as a pure stream copy — nothing is decoded, scaled or re-encoded in
the child process — and the app splits the concatenated JPEGs itself and hands
each to Skia. Measured on the real device: ~1% CPU for the child at 1280x720@30.

The geometry is fixed at 1280x720@30 rather than pickable. A 16:9 source
letterboxes into 1024x576 on this panel, so 720 sits just above what the screen
can show and downscales cleanly; 1080p costs three times the bandwidth and
decode for detail the panel cannot display. Measured on the card, every mode
holds its full rate:

| Mode | fps | Stream | Frame |
| --- | --- | --- | --- |
| 1920x1080@60 | 60.2 | 5.89 MB/s | 95 KB |
| 1920x1080@30 | 30.2 | 2.96 MB/s | 95 KB |
| 1280x720@30 | 30.2 | 1.33 MB/s | 42 KB |
| 800x600@30 | 30.2 | 0.70 MB/s | 22 KB |

Override with `--dart-define=CAPTURE_W=1920 --dart-define=CAPTURE_H=1080`.

Decoding keeps the newest frame and drops whatever arrived meanwhile; a queue
would only ever show progressively staler video. The stream runs while CAPTURE
is on screen and stops when it leaves.

A capture card with nothing on its HDMI input streams valid black frames
forever, which is indistinguishable from a broken app, so the frame is
downscaled to 32x18 and averaged. The picture has to stay black for roughly three
seconds (30 sampled frames) before the banner appears — a fade or one dark
scene is not a lost signal — while the last good frame keeps showing. A returning source clears it
with no hold at all.

## Handling missing data

The GPU exporter on this cluster is frequently down. Rather than blanking the
panel or showing a misleading `0`, current DCGM metrics are used while the
exporter is healthy and `last_over_time(...[7d])` is only used while that
exporter is down. The expensive seven-day fallback scans are cached for one
minute while the same exporter remains down, instead of being rerun on every
five-second poll. That distinction matters: a single metric disappearing from
a healthy exporter must render `--`, not yesterday's value as if it were live.
Historical fallback values are paired with a staleness age computed from two
age queries. `timestamp()` loses the original sample time when it passes
through `last_over_time`, so the age needs its own expression — but a subquery
only evaluates on its own step boundaries, so its answer sawtooths from zero to
a full step. Measured against the live server it swung 0..300s while the true
age never passed 15s, which made a healthy GPU drop out every few minutes. A
fresh series is therefore timed exactly with `time() - timestamp()`, and the
subquery is kept only for one that stopped long enough ago to fall out of the
lookback window, where minutes do not matter.

A stale GPU panel is drawn amber, badged `[ DOWN ]`, and states how old the
readings are. Cluster snapshots are also age-checked: after 15 seconds without a
successful poll the dashboard is visibly dimmed and marked `STALE` instead of
presenting the last good values as current. The same rule applies everywhere: a
metric with no series renders `--`, never `0`.

## Tests

```sh
flutter test
```

The widget tests drive the app against a fake Prometheus built from real
captured responses — including the down `vm-gpu-worker-1` node target — and load
the bundled JetBrains Mono so layout assertions measure the true 0.6em advance
instead of `flutter_test`'s 1em stand-in font. A `RenderFlex` overflow at
1024x600 fails the suite.

There is also a live smoke test that checks every PromQL expression the UI
issues still returns usable data. It needs the server reachable, so it is off by
default:

```sh
flutter test test/live_smoke_test.dart --dart-define=PROMTERM_LIVE=true --tags live
```

## Source layout

```
lib/src/
  config.dart              endpoint, poll interval, design canvas
  theme.dart               palette and monospace text styles
  util.dart                bars, sparklines, byte/rate/duration formatting
  prom/prom_client.dart    Prometheus HTTP API v1 (instant + range)
  prom/queries.dart        every PromQL expression, in one place
  model/snapshot.dart      NodeStat / GpuStat / Snapshot
  state/metrics_store.dart polling, history rings, range passthrough
  widgets/                 panel frame, gauges, chart painter, cursor
  capture/                 v4l2 capture: ffmpeg child, MJPEG framing, decode
  screens/                 dash, graphs, nodes, capture
```
