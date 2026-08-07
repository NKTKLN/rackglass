import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../capture/capture_controller.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/term_panel.dart';

/// How the frame is mapped onto the panel.
enum ZoomMode {
  /// Whole frame, letterboxed. A 1080p source lands at roughly 0.46x here.
  fit('FIT'),

  /// One source pixel per panel pixel: a crop you can actually read.
  native('1:1'),

  /// Twice native, for small text on the source.
  double_('2:1');

  const ZoomMode(this.label);

  final String label;
}

/// Live view from the USB capture card.
///
/// The stream only runs while this mode is on screen: an idle HDMI grabber
/// pushing 30 fps into a decoder nobody is looking at is pure heat.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.controller,
    required this.active,
    required this.fullscreen,
    required this.onFullscreen,
  });

  final CaptureController controller;

  /// True while CAPTURE is the selected mode.
  final bool active;

  /// True when the app chrome is hidden and the video owns the panel.
  final bool fullscreen;
  final ValueChanged<bool> onFullscreen;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final TransformationController _view = TransformationController();
  ZoomMode _zoom = ZoomMode.fit;

  @override
  void initState() {
    super.initState();
    widget.controller.discover();
    if (widget.active) widget.controller.start();
  }

  @override
  void dispose() {
    // The screen going away means nobody is watching; leaving ffmpeg and the
    // stats timer running would outlive the widget that started them.
    widget.controller.stop();
    _view.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CaptureScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      widget.controller.start();
    } else if (!widget.active && old.active) {
      widget.controller.stop();
    }
  }

  /// Zooms about the middle of the viewport, so the thing you were looking at
  /// stays roughly where it was.
  void _apply(ZoomMode mode, Size viewport, Size displayed, ui.Image frame) {
    final scale = switch (mode) {
      ZoomMode.fit => 1.0,
      ZoomMode.native => frame.width / displayed.width,
      ZoomMode.double_ => 2 * frame.width / displayed.width,
    };
    final cx = viewport.width / 2;
    final cy = viewport.height / 2;
    setState(() {
      _zoom = mode;
      _view.value = Matrix4.identity()
        ..translateByDouble(-cx * (scale - 1), -cy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final viewport = _Viewport(
          controller: c,
          view: _view,
          zoom: _zoom,
          fullscreen: widget.fullscreen,
          onZoom: _apply,
          onExitFullscreen: () => widget.onFullscreen(false),
        );

        if (widget.fullscreen) return viewport;

        return Column(
          children: [
            _ControlBar(
              controller: c,
              zoom: _zoom,
              onZoom: (m) => setState(() => _zoom = m),
              onFullscreen: () => widget.onFullscreen(true),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TermPanel(
                title: 'capture · ${c.sourceLabel}',
                accent: switch (c.state) {
                  CaptureState.failed => TC.red,
                  CaptureState.noSignal => TC.amber,
                  _ => TC.border,
                },
                titleColor: switch (c.state) {
                  CaptureState.failed => TC.red,
                  CaptureState.noSignal => TC.amber,
                  _ => TC.mid,
                },
                trailing: _StateTag(c.state),
                padding: const EdgeInsets.fromLTRB(
                  4,
                  TermPanel.titleGutter,
                  4,
                  4,
                ),
                child: viewport,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StateTag extends StatelessWidget {
  const _StateTag(this.state);

  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      CaptureState.failed => const TermTag('ERROR', color: TC.red),
      CaptureState.noSignal => const TermTag('NO SIGNAL', color: TC.amber),
      CaptureState.starting => const TermTag('OPENING', color: TC.amber),
      CaptureState.idle => const TermTag('STOPPED', color: TC.dim),
      CaptureState.streaming => const TermTag('LIVE', color: TC.green),
    };
  }
}

/// The picture itself, or an explanation of why there is none.
class _Viewport extends StatelessWidget {
  const _Viewport({
    required this.controller,
    required this.view,
    required this.zoom,
    required this.fullscreen,
    required this.onZoom,
    required this.onExitFullscreen,
  });

  final CaptureController controller;
  final TransformationController view;
  final ZoomMode zoom;
  final bool fullscreen;
  final void Function(ZoomMode, Size, Size, ui.Image) onZoom;
  final VoidCallback onExitFullscreen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final frame = c.frame;

    if (c.state == CaptureState.failed) {
      return _Message(
        title: 'CAPTURE FAILED',
        color: TC.red,
        lines: [
          c.error ?? 'unknown error',
          if (c.devices.isEmpty)
            'no /dev/video* nodes — is the stick plugged in?'
          else
            'retrying every 2s',
        ],
      );
    }
    if (frame == null) {
      return _Message(
        title: c.state == CaptureState.idle ? 'STOPPED' : 'OPENING DEVICE…',
        color: TC.dim,
        lines: [
          if (c.state == CaptureState.idle)
            'press START to open ${c.device?.path ?? "the device"}'
          else
            '${c.device?.path ?? "?"} · ${c.mode.label} · mjpeg',
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final viewport = box.biggest;
        // Size the frame would take letterboxed into the viewport.
        final fitted = applyBoxFit(
          BoxFit.contain,
          Size(frame.width.toDouble(), frame.height.toDouble()),
          viewport,
        ).destination;
        final nativeScale = frame.width / fitted.width;

        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: InteractiveViewer(
                transformationController: view,
                minScale: 1,
                maxScale: 8,
                // Panning matters more than the pinch: at 1:1 on a 1080p
                // source only about half the picture is on the panel.
                panEnabled: true,
                scaleEnabled: true,
                child: Center(
                  child: SizedBox(
                    width: fitted.width,
                    height: fitted.height,
                    child: RawImage(
                      image: frame,
                      fit: BoxFit.fill,
                      // Nearest-neighbour above 1:1 keeps captured text crisp
                      // instead of smearing it.
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
              ),
            ),
            if (c.state == CaptureState.noSignal)
              const Center(
                child: _Message(
                  title: 'NO SIGNAL',
                  color: TC.amber,
                  lines: [
                    'the card is streaming, the picture is black',
                    'nothing connected to its HDMI input?',
                  ],
                ),
              ),
            Positioned(
              left: 6,
              bottom: 4,
              child: _Overlay(controller: controller, nativeScale: nativeScale),
            ),
            Positioned(
              right: 6,
              bottom: 4,
              child: _ZoomButtons(
                zoom: zoom,
                onPick: (m) => onZoom(m, viewport, fitted, frame),
              ),
            ),
            if (fullscreen)
              Positioned(
                right: 6,
                top: 6,
                child: _Button(
                  label: 'EXIT FULL',
                  selected: false,
                  onTap: onExitFullscreen,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.zoom, required this.onPick});

  final ZoomMode zoom;
  final ValueChanged<ZoomMode> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TC.bg.withValues(alpha: 0.72),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in ZoomMode.values) ...[
            _Button(
              label: m.label,
              selected: m == zoom,
              onTap: () => onPick(m),
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

/// Frame stats burned into the corner of the picture.
class _Overlay extends StatelessWidget {
  const _Overlay({required this.controller, required this.nativeScale});

  final CaptureController controller;
  final double nativeScale;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final f = c.frame;
    return Container(
      color: TC.bg.withValues(alpha: 0.72),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        '${f == null ? "--" : "${f.width}x${f.height}"} · '
        '${c.fps.toStringAsFixed(1)} fps · '
        'fit ${(100 / nativeScale).toStringAsFixed(0)}% · '
        '${fmtBytes(c.bytesTotal.toDouble(), digits: 0)} in'
        '${c.framesDropped > 0 ? " · ${c.framesDropped} dropped" : ""}'
        '${c.decodeErrors > 0 ? " · ${c.decodeErrors} bad" : ""}',
        style: ts(size: TZ.caption, color: TC.mid),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.color,
    required this.lines,
  });

  final String title;
  final Color color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          color: TC.bg.withValues(alpha: 0.86),
          border: Border.all(color: color),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: ts(
                size: 24,
                color: color,
                weight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 8),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(l, style: ts(size: TZ.small, color: TC.dim)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.controller,
    required this.zoom,
    required this.onZoom,
    required this.onFullscreen,
  });

  final CaptureController controller;
  final ZoomMode zoom;
  final ValueChanged<ZoomMode> onZoom;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          _Button(
            label: c.running ? 'STOP' : 'START',
            selected: c.running,
            onTap: () => c.running ? c.stop() : c.start(),
          ),
          const SizedBox(width: 8),
          _Button(label: 'FULLSCREEN', selected: false, onTap: onFullscreen),
          const SizedBox(width: 14),
          Text(
            'mode: ${c.mode.label} · mjpeg',
            style: ts(size: TZ.caption, color: TC.dim),
          ),
          if (c.devices.length > 1) ...[
            const SizedBox(width: 14),
            for (final d in c.devices) ...[
              _Button(
                label: d.short,
                selected: d.path == c.device?.path,
                onTap: () => c.setDevice(d),
              ),
              const SizedBox(width: 4),
            ],
          ],
          const Spacer(),
          Text(
            c.uptime == null ? '' : 'up ${fmtDuration(c.uptime)}',
            style: ts(size: TZ.caption, color: TC.dim),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? TC.bright : TC.border),
          color: selected ? TC.bright : null,
        ),
        child: Text(
          label,
          style: ts(
            size: TZ.small,
            color: selected ? TC.bg : TC.mid,
            weight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
