import 'package:flutter/widgets.dart';

import '../theme.dart';

/// A bordered box with its title cut into the top rule, the way a TUI frame
/// looks. The title sits over the border with background behind it so the line
/// appears to break around the text.
class TermPanel extends StatelessWidget {
  const TermPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.accent = TC.border,
    this.titleColor = TC.mid,
    this.padding = const EdgeInsets.fromLTRB(10, 14, 10, 8),
  });

  final String title;
  final Widget child;

  /// Optional right-aligned tag in the top rule, e.g. a `[ DOWN ]` badge.
  final Widget? trailing;
  final Color accent;
  final Color titleColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: TC.panelBg,
              border: Border.all(color: accent),
            ),
          ),
        ),
        Positioned.fill(child: Padding(padding: padding, child: child)),
        Positioned(
          left: 10,
          top: -1,
          child: Container(
            color: TC.bg,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              title.toUpperCase(),
              style: ts(
                size: TZ.caption,
                color: titleColor,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
        if (trailing != null)
          Positioned(
            right: 10,
            top: -1,
            child: Container(
              color: TC.bg,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: trailing,
            ),
          ),
      ],
    );
  }
}

/// Horizontal rule used inside panels to separate stanzas.
class TermRule extends StatelessWidget {
  const TermRule({super.key, this.color = TC.gridLine, this.height = 10});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(child: Container(height: 1, color: color)),
    );
  }
}

/// `[ TEXT ]` tag, used for status badges.
class TermTag extends StatelessWidget {
  const TermTag(this.text, {super.key, this.color = TC.fg, this.size = TZ.caption});

  final String text;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      '[ $text ]',
      style: ts(size: size, color: color, weight: FontWeight.w700),
    );
  }
}
