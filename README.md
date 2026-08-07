# promterm

Terminal-style Prometheus dashboard for a 7" 1024x600 panel. Phosphor green,
box-drawing frames, block-character bars, optional CRT scanlines.

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

Other keys: `←` `→` cycle modes, `r` force a refresh, `c` toggle the CRT
overlay, `q` / `Esc` quit. Every tab and button is also a touch target sized for
a finger on a 7" screen.

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
  widgets/                 panel frame, gauges, chart painter, CRT overlay
  screens/                 dash, graphs, nodes, capture
```
