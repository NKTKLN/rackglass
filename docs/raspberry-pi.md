# 🍓 Running on a Raspberry Pi

Notes for putting Rackglass on a Raspberry Pi 3B driving the 7" panel. The app
draws straight to the display through KMS with Slint's software renderer: no
X11, no Wayland compositor, no OpenGL at all.

> [!IMPORTANT]
> The Rust build has **not been run on the Pi yet**. The build below is
> verified (it produces an aarch64 binary on an x64 host), but installing,
> seat access, the systemd unit and anything about frame rate on the Pi are
> untested. The Flutter version this replaced was measured on the hardware;
> this one still has to be.

## The short version

| | |
| --- | --- |
| Build | Cross-compiled on an x64 host in podman, no emulation |
| Display | KMS/DRM directly — no X11, no Wayland |
| Rendering | Slint software renderer, repainting only what changed |
| Input and display access | `seatd`, with the user in `video` |

A Pi 4 or 5 runs the same binary; nothing here is specific to the 3B.

## Building

```sh
tools/arm64/build.sh
```

This builds a Debian bookworm image carrying the aarch64 cross toolchain and
the arm64 dev packages of every native library the `kms` feature links —
libdrm, libgbm, libinput, libseat, libudev, libxkbcommon, fontconfig — through
Debian multiarch, and compiles with
`--target aarch64-unknown-linux-gnu --no-default-features --features kms`.
Bookworm on purpose: it is what Raspberry Pi OS is based on, and its glibc
(2.36) is the one the binary is linked against.

The crate registry and the cargo target directory live in named podman
volumes, so after the first run a rebuild is incremental. Output lands in
`build/arm64-out/rackglass-arm64.tar.gz`: the binary, `config.env.example` and
`rackglass.service`.

Nothing about the deployment is baked in any more — configuration is read at
runtime — so one build serves every panel.

Verify what came out before copying it anywhere:

```sh
tar -xzf build/arm64-out/rackglass-arm64.tar.gz -C /tmp
file /tmp/rackglass/rackglass
```

## Installing on the Pi

```sh
sudo tar -xzf rackglass-arm64.tar.gz -C /opt
sudo apt install -y libinput10 libgbm1 libdrm2 libudev1 libseat1 \
                    libxkbcommon0 libfontconfig1 ffmpeg seatd
sudo usermod -aG video "$USER"        # takes effect on next login
sudo systemctl enable --now seatd
```

The binary opens the display and the input devices through libseat. A service
has no login session, so logind will not hand them out; `seatd` does, to
members of the group it runs with. The `video` group is also what makes
`/dev/video0` openable — without it capture fails on permissions and reports it
as a device error.

Configuration goes in `/etc/rackglass/config.env`, which the app reads at
startup:

```sh
sudo mkdir -p /etc/rackglass
sudo cp /opt/rackglass/config.env.example /etc/rackglass/config.env
sudoedit /etc/rackglass/config.env
```

### The capture node

A Pi puts its own V4L2 nodes at high indices — `bcm2835-codec` at 10–12, 18, 31
and `bcm2835-isp` at 13–16, 20–23 — so a USB stick still lands on `video0` and
`video1`, exactly as on a desktop. Confirm rather than assume:

```sh
v4l2-ctl --list-devices
```

and set `CAPTURE_DEVICE` in `/etc/rackglass/config.env` to whichever node the
stick got. It is read at startup, so a wrong guess costs a restart rather than
a rebuild.

## Running it

By hand, from a text console on the panel (not over SSH into a desktop
session — the display has to be free):

```sh
RACKGLASS_FULLSCREEN=1 /opt/rackglass/rackglass
```

As a service, so the panel comes up on power and can be driven over SSH:

```sh
sudo cp /opt/rackglass/rackglass.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now rackglass
journalctl -u rackglass -f
```

The unit runs as `nktkln`; change `User=` if the panel belongs to someone else.
Raspberry Pi OS Lite boots to a console and runs no display server, so nothing
else competes for the display. On a desktop image, disable the display manager
first.

If the panel blanks after a few minutes, it is the kernel console blanking
underneath; add `consoleblank=0` to `/boot/firmware/cmdline.txt`.

## Why not Flutter

The Flutter build could not use the Pi 3B's GPU. With a GLES context Flutter
reported:

```
No provider of glBlitFramebuffer found.  Requires one of:
    Desktop OpenGL 3.0
    GL_ARB_framebuffer_object
    OpenGL ES 3.0
    GL_EXT_framebuffer_blit
    GL_NV_framebuffer_blit
```

And the hardware, per `eglinfo`:

```
renderer: VC4 V3D 2.1
OpenGL ES profile version: OpenGL ES 2.0
shading language version: OpenGL ES GLSL ES 1.0.16
```

VideoCore IV offers GLES 2.0 and desktop GL 2.1, and none of those extensions —
a property of the chip, so no display server changes it. The Flutter build
therefore ran under X11 with `LIBGL_ALWAYS_SOFTWARE=1`, rasterising the whole
interface through llvmpipe on a 1.2 GHz quad Cortex-A53, with GTK and X in the
path as well. That is the lag this port exists to remove: Slint's software
renderer skips the GL emulation layer entirely and repaints only the regions
that changed, and the three data screens change once per poll.

## What is still expensive

CAPTURE. The card emits 148 KB per frame at 1024x600, and the app decodes every
one of them on the CPU on top of drawing the scene. Watch `fps` and `dropped`
on the line beside `mode`; if frames are being dropped, lower `CAPTURE_FPS` in
`/etc/rackglass/config.env` and restart.
