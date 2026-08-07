import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Scanlines plus a vignette, painted over everything. Static — no animation —
/// so it costs one cached layer per frame and stays cheap on a Pi-class GPU.
class CrtOverlay extends StatelessWidget {
  const CrtOverlay({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _CrtPainter(), size: Size.infinite),
      ),
    );
  }
}

class _CrtPainter extends CustomPainter {
  static const _pitch = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final scan = Paint()..color = const Color(0xFF000000).withValues(alpha: 0.22);
    for (var y = 0.0; y < size.height; y += _pitch) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), scan);
    }

    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.85,
          colors: [
            const Color(0x00000000),
            const Color(0x00000000),
            const Color(0x66000000),
          ],
          stops: const [0.0, 0.62, 1.0],
        ).createShader(rect),
    );

    // Faint phosphor wash so the black is never quite black.
    canvas.drawRect(rect, Paint()..color = TC.fg.withValues(alpha: 0.012));
  }

  @override
  bool shouldRepaint(_CrtPainter oldDelegate) => false;
}

/// The blinking block cursor in the status bar.
class BlinkCursor extends StatefulWidget {
  const BlinkCursor({super.key, this.color = TC.fg, this.size = 12});

  final Color color;
  final double size;

  @override
  State<BlinkCursor> createState() => _BlinkCursorState();
}

class _BlinkCursorState extends State<BlinkCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Opacity(
        opacity: _c.value < 0.5 ? 1 : 0,
        child: Text(
          '▊',
          style: ts(size: widget.size, color: widget.color, glow: 6),
        ),
      ),
    );
  }
}
