import 'package:flutter/widgets.dart';

import '../theme.dart';

/// The blinking block cursor in the status bar — the one piece of console
/// theatre that survives; everything else is drawn flat.
class BlinkCursor extends StatefulWidget {
  const BlinkCursor({super.key, this.color = TC.fg, this.size = TZ.body});

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
          style: ts(size: widget.size, color: widget.color, height: 1.0),
        ),
      ),
    );
  }
}
