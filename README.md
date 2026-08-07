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
| `1` / `F1` | **DASH** | Host CPU package temp + labelled hwmon sensors, CPU usage, load; GPU temp/util/VRAM/power; host memory and swap with the VM memory budget; one row per scrape target with CPU%, memory, sparklines, load, root fs, network, iowait, uptime |
| `2` / `F2` | **GRAPHS** | Four range-query charts (CPU %, memory %, temperatures, GPU util + network) over 15m / 1h / 6h / 24h / 7d |
| `3` / `F3` | **NODES** | Master/detail per target: CPU, memory, root fs, network, boot time, full hwmon sensor list |
| `4` / `F4` | **CAPTURE** | Reserved stub for the USB capture card — no device bound yet |

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

## Handling missing data

The GPU exporter on this cluster is frequently down. Rather than blanking the
panel or showing a misleading `0`, GPU metrics are read through
`last_over_time(...[7d])` and paired with a staleness age computed from a
subquery over `timestamp()` — `timestamp()` loses the original sample time when
it passes through `last_over_time`, so the age needs its own expression. A stale
panel is drawn amber, badged `[ DOWN ]`, and states how old the readings are.
The same rule applies everywhere: a metric with no series renders `--`, never
`0`.

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
  screens/                 dash, graphs, nodes, capture
```
