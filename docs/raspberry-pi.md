# 🍓 Running on a Raspberry Pi

Notes from putting Rackglass on a Raspberry Pi 3B driving the 7" panel. Most of
this is about two things that are not obvious until you hit them: Flutter will
not cross-build for arm64, and a Pi 3B cannot give Flutter the OpenGL it wants.

Everything below was measured on the hardware, not inferred.

## The short version

| | |
| --- | --- |
| Build | Not on the Pi, and not cross-compiled — inside an emulated arm64 container |
| Display | X11, **not** Wayland |
| Rendering | `LIBGL_ALWAYS_SOFTWARE=1` — llvmpipe, on the CPU |
| Why | VideoCore IV tops out at OpenGL ES 2.0; Flutter needs 3.0 |

A Pi 4 or 5 has V3D with GLES 3.1 and needs none of the software-rendering
workaround. The bundle built here runs on those unchanged.

## Building

`flutter build linux --target-platform=linux-arm64` exists, and so does
`--target-sysroot`, but on an x64 host the tool answers:

```
Cross-build from Linux x64 host to Linux arm64 target is not currently supported.
```

There is also no arm64 Linux SDK archive — the releases manifest lists x64
only. What *does* exist is the arm64 engine: `dart-sdk-linux-arm64.zip` and
`linux-arm64-release/linux-arm64-flutter-gtk.zip` are published like any other
artifact. So the tool runs on an arm64 host if you clone it from git, and the
way to get an arm64 host on an x64 desktop is emulation:

```sh
tools/arm64/build.sh config.pi.env
```

The first run builds the image — Debian bookworm, GTK dev packages, a shallow
Flutter clone — and takes the better part of an hour under qemu. Later runs
reuse it and take minutes. Output lands in `build/arm64-out/rackglass-arm64.tar.gz`,
about 9 MB packed and 22 MB unpacked.

Two things bite inside the container, both handled in `build.sh`:

* Flutter unpacks artifacts with `tar` as root, which restores ownership from
  the archive. Those uids are unmapped in podman's user namespace, the `chown`
  fails and takes the whole extraction with it. `TAR_OPTIONS=--no-same-owner`
  fixes every tar Flutter runs.
* `bash -lc` sources `/etc/profile`, which resets `PATH` and loses the one the
  image set — `flutter: command not found`. Use `bash -c`.

Verify what came out before copying it anywhere:

```sh
tar -xzf build/arm64-out/rackglass-arm64.tar.gz -C /tmp
file /tmp/bundle/rackglass          # ELF 64-bit … ARM aarch64
```

The binary needs glibc 2.34; Raspberry Pi OS bookworm has 2.36.

## Installing on the Pi

```sh
sudo mkdir -p /opt/rackglass
sudo tar -xzf rackglass-arm64.tar.gz -C /opt/rackglass

sudo apt install -y xserver-xorg xinit x11-xserver-utils \
                    libgtk-3-0 libgl1-mesa-dri ffmpeg
sudo usermod -aG video "$USER"        # takes effect on next login
```

`libgl1-mesa-dri` is not optional here: llvmpipe lives in it, and llvmpipe is
what draws the whole app. The `video` group is what makes `/dev/video0`
openable — without it capture fails on permissions and reports it as a device
error.

Starting X from a service or over SSH needs:

```sh
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' | sudo tee /etc/X11/Xwrapper.config
```

### The capture node

A Pi puts its own V4L2 nodes at high indices — `bcm2835-codec` at 10–12, 18, 31
and `bcm2835-isp` at 13–16, 20–23 — so a USB stick still lands on `video0` and
`video1`, exactly as on a desktop. Confirm rather than assume:

```sh
v4l2-ctl --list-devices
```

and set `CAPTURE_DEVICE` in the build config to whichever node the stick got.
It is baked in at build time, so getting it wrong means another build.

## Running it

```sh
LIBGL_ALWAYS_SOFTWARE=1 RACKGLASS_FULLSCREEN=1 \
  xinit /bin/sh -c '
    xset s off
    xset -dpms
    xset s noblank
    exec /opt/rackglass/bundle/rackglass
  ' -- :0 vt1 -nolisten tcp -nocursor
```

`-nocursor` is an X server option, so it goes after the `--`. It removes the
pointer entirely, which is what a touch panel wants; `unclutter` only hides it
until the next movement.

The three `xset` calls stop the screen blanking. A dashboard that turns itself
off after ten minutes is not a dashboard, and nothing here ever touches the
keyboard to wake it. Note the absolute path to `sh`: `xinit` only treats its
first argument as the client program if it begins with a slash or a dot, and
otherwise hands it to `xterm`.

As a service, so the panel comes up on power and can be driven over SSH:

```ini
[Unit]
Description=Rackglass panel
After=systemd-user-sessions.service network-online.target

[Service]
User=nktkln
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=RACKGLASS_FULLSCREEN=1
ExecStart=/usr/bin/xinit /bin/sh -c 'xset s off; xset -dpms; xset s noblank; exec /opt/rackglass/bundle/rackglass' -- :0 vt1 -nolisten tcp -nocursor
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload && sudo systemctl enable --now rackglass
journalctl -u rackglass -f
```

`Restart=always` earns its place: the GL path is driver-sensitive and has been
seen to crash inside Mesa on entirely different hardware.

## Why not Wayland, and why software rendering

The blocker is one function. With a GLES context Flutter reports:

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

VideoCore IV offers GLES 2.0 and desktop GL 2.1, and none of those extensions.
That is a property of the chip, so no display server changes it — GLX fails the
same way EGL does. Which leaves llvmpipe, and llvmpipe is why X11:
`LIBGL_ALWAYS_SOFTWARE=1` is a GLX variable. Under Wayland the app selects a
device through EGL and Mesa refuses:

```
libEGL warning: Not allowed to force software rendering when API explicitly
selects a hardware device.
```

`cage` itself works fine — it only needs GLES 2.0 — and running it over SSH is
possible with `seatd` (`seatd -g video`, plus membership of `video`), because a
network session holds no seat and logind will not hand out DRM. None of that is
needed once you settle on X11.

## What software rendering costs

The whole interface is drawn by a 1.2 GHz quad Cortex-A53. The three data
screens are text, rules and block-character bars refreshed every five seconds,
which is undemanding. CAPTURE is the open question: the card emits 148 KB per
frame at 1024x600, and the app decodes every one of them on the CPU on top of
drawing the scene.

Watch `fps` and `dropped` on the line beside `mode`. If frames are being
dropped, lower `CAPTURE_FPS` in the build config and rebuild — with the image
cached that is a couple of minutes.
