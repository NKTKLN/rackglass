import 'package:flutter/widgets.dart';

import '../theme.dart';
import '../widgets/term_panel.dart';

/// Placeholder for the USB capture-card feed. The tab and its plumbing exist so
/// the video source can be dropped in later without touching navigation.
class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key});

  static const _art = [
    r'      ┌────────────────────────────┐',
    r'      │                            │',
    r'      │      ▄▄▄▄▄▄▄▄▄▄▄▄▄▄        │',
    r'      │    ▄█░░░░░░░░░░░░░░█▄      │',
    r'      │    █░░  NO SIGNAL  ░░█     │',
    r'      │    ▀█░░░░░░░░░░░░░░█▀      │',
    r'      │      ▀▀▀▀▀▀▀▀▀▀▀▀▀▀        │',
    r'      │                            │',
    r'      └────────────────────────────┘',
  ];

  @override
  Widget build(BuildContext context) {
    return TermPanel(
      title: 'capture · usb',
      trailing: const TermTag('NOT IMPLEMENTED', color: TC.amber),
      accent: TC.amber.withValues(alpha: 0.35),
      titleColor: TC.amber,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final line in _art)
              Text(
                line,
                style: ts(
                  size: 13,
                  color: TC.dim,
                  height: 1.15,
                  letterSpacing: 0,
                ),
              ),
            const SizedBox(height: 22),
            Text(
              'USB CAPTURE CARD INPUT',
              style: ts(
                size: 15,
                color: TC.amber,
                weight: FontWeight.w700,
                letterSpacing: 3,
                glow: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'reserved · no device bound',
              style: ts(size: 11, color: TC.dim, letterSpacing: 1.2),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(border: Border.all(color: TC.border)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '\$ v4l2-ctl --list-devices',
                    style: ts(size: 11, color: TC.mid),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'capture pipeline not wired up yet',
                    style: ts(size: 11, color: TC.dim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
