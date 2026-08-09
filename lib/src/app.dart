import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'capture/capture_controller.dart';
import 'config.dart';
import 'screens/capture_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/graphs_screen.dart';
import 'screens/nodes_screen.dart';
import 'state/metrics_store.dart';
import 'theme.dart';
import 'util.dart';
import 'widgets/blink_cursor.dart';

enum AppMode {
  dash('DASH'),
  graphs('GRAPHS'),
  nodes('NODES'),
  capture('CAPTURE');

  const AppMode(this.label);

  final String label;
}

class PromTermApp extends StatefulWidget {
  const PromTermApp({
    super.key,
    this.store,
    this.capture,
    this.showBootSplash = true,
  });

  /// Injected in tests; production builds let the app own these.
  final MetricsStore? store;
  final CaptureController? capture;
  final bool showBootSplash;

  @override
  State<PromTermApp> createState() => _PromTermAppState();
}

class _PromTermAppState extends State<PromTermApp> {
  late final MetricsStore _store = widget.store ?? MetricsStore();
  late final CaptureController _capture = widget.capture ?? CaptureController();
  final FocusNode _focus = FocusNode();

  AppMode _mode = AppMode.dash;
  late bool _booted = !widget.showBootSplash;

  /// Capture running with the app chrome hidden. On a 600px panel the bars
  /// cost 15% of the height, which is worth reclaiming for video.
  bool _videoFull = false;

  @override
  void initState() {
    super.initState();
    // An injected store is driven by whoever supplied it, so only a store we
    // own gets put on the polling timer.
    if (widget.store == null) _store.start();
  }

  @override
  void dispose() {
    // Only tear down a store we created; an injected one belongs to the caller.
    if (widget.store == null) _store.dispose();
    if (widget.capture == null) _capture.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final k = e.logicalKey;
    void go(AppMode m) => setState(() {
      _mode = m;
      // Leaving CAPTURE always brings the chrome back; the child cannot ask
      // for this itself without calling setState during its own update.
      if (m != AppMode.capture) _videoFull = false;
    });

    if (k == LogicalKeyboardKey.f1 || k == LogicalKeyboardKey.digit1) {
      go(AppMode.dash);
    } else if (k == LogicalKeyboardKey.f2 || k == LogicalKeyboardKey.digit2) {
      go(AppMode.graphs);
    } else if (k == LogicalKeyboardKey.f3 || k == LogicalKeyboardKey.digit3) {
      go(AppMode.nodes);
    } else if (k == LogicalKeyboardKey.f4 || k == LogicalKeyboardKey.digit4) {
      go(AppMode.capture);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.tab) {
      go(AppMode.values[(_mode.index + 1) % AppMode.values.length]);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      go(AppMode
          .values[(_mode.index - 1 + AppMode.values.length) %
              AppMode.values.length]);
    } else if (k == LogicalKeyboardKey.keyR) {
      _store.refresh();
    } else if (k == LogicalKeyboardKey.escape && _videoFull) {
      // Escape only ever leaves fullscreen. It does not quit: on a kiosk panel
      // the app is meant to stay up, and a stray Escape closing the whole
      // dashboard is not a recoverable mistake from the front of the box.
      setState(() => _videoFull = false);
    } else if (k == LogicalKeyboardKey.keyQ) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'promterm',
      color: TC.bg,
      debugShowCheckedModeBanner: false,
      builder: (context, _) => _root(),
    );
  }

  Widget _root() {
    return Container(
      color: TC.bg,
      alignment: Alignment.center,
      // Lay everything out against the exact 1024x600 panel, then scale that
      // canvas to whatever window we actually got. Nothing can overflow.
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: AppConfig.designWidth,
          height: AppConfig.designHeight,
          child: KeyboardListener(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _handleKey,
            child: Stack(
              children: [
                Positioned.fill(child: _screen()),
                if (!_booted)
                  Positioned.fill(
                    child: BootSplash(
                      endpoint: _store.endpoint,
                      onDone: () => setState(() => _booted = true),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _screen() {
    final videoFull = _videoFull && _mode == AppMode.capture;
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) => Stack(
        children: [
          // Keep this exact subtree mounted while fullscreen changes. Moving
          // CAPTURE between two unrelated parent trees used to dispose/start
          // it on every fullscreen toggle, racing the ffmpeg lifecycle.
          Positioned(
            left: videoFull ? 0 : 6,
            right: videoFull ? 0 : 6,
            top: videoFull ? 0 : Chrome.top + 6,
            bottom: videoFull ? 0 : Chrome.status + 4,
            child: _body(),
          ),
          if (!videoFull)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: Chrome.top,
              child: _TopBar(
                mode: _mode,
                onPick: (m) => setState(() {
                  _mode = m;
                  if (m != AppMode.capture) _videoFull = false;
                }),
              ),
            ),
          if (!videoFull)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: Chrome.status,
              child: _StatusBar(store: _store),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    // IndexedStack keeps screen state alive, while each history screen receives
    // an explicit active flag so expensive range queries only run when visible.
    return IndexedStack(
      index: _mode.index,
      sizing: StackFit.expand,
      children: [
        DashboardScreen(store: _store),
        GraphsScreen(store: _store, active: _mode == AppMode.graphs),
        NodesScreen(store: _store, active: _mode == AppMode.nodes),
        CaptureScreen(
          controller: _capture,
          active: _mode == AppMode.capture,
          fullscreen: _videoFull,
          onFullscreen: (v) => setState(() => _videoFull = v),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Fixed heights for the frame around the content, in design pixels.
abstract final class Chrome {
  static const top = 52.0;
  static const status = 26.0;
}

/// Mode buttons, and nothing else. Link state and the clock live in the
/// status line at the bottom, where the rest of the diagnostics already are.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.mode, required this.onPick});

  final AppMode mode;
  final ValueChanged<AppMode> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: Chrome.top,
      // Bottom padding keeps the buttons clear of the divider rule; without it
      // the two rectangles read as one smudged line.
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
      child: Row(
        children: [
          for (final m in AppMode.values)
            _Tab(mode: m, selected: m == mode, onTap: () => onPick(m)),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.mode, required this.selected, required this.onTap});

  final AppMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // Wide enough to be a comfortable touch target on a 7" panel.
        constraints: const BoxConstraints(minWidth: 150),
        margin: const EdgeInsets.only(right: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          // Selected tab is inverted, the way a console highlight looks.
          color: selected ? TC.bright : null,
          border: Border.all(color: selected ? TC.bright : TC.border),
        ),
        child: Center(
          child: Text(
            mode.label,
            style: ts(
              size: TZ.large,
              color: selected ? TC.bg : TC.mid,
              weight: selected ? FontWeight.w700 : FontWeight.w400,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Link state, wall clock and the key map. Ticks once a second on its own, so
/// the clock keeps moving between scrapes.
class _StatusBar extends StatefulWidget {
  const _StatusBar({required this.store});

  final MetricsStore store;

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final ok = s.healthy;
    final stale = s.stale;
    final snap = s.snapshot;
    final now = DateTime.now();
    return Container(
      height: Chrome.status,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const BlinkCursor(size: TZ.small),
          const SizedBox(width: 8),
          _Field(
            label: 'status',
            child: Text(
              !ok ? 'offline' : (stale ? 'stale' : 'online'),
              style: ts(
                size: TZ.small,
                color: !ok ? TC.red : (stale ? TC.amber : TC.green),
                weight: FontWeight.w700,
              ),
            ),
          ),
          const _Dot(),
          _Field(
            label: 'time',
            child: Text(fmtClock(now), style: ts(size: TZ.small)),
          ),
          const _Dot(),
          _Field(
            label: 'last request',
            child: Text(
              snap == null
                  ? '--'
                  : '${fmtClock(snap.at)} · ${snap.fetchMillis}ms',
              style: ts(size: TZ.small),
            ),
          ),
          // A failure still has to say what it was; hiding it behind the tag
          // would leave a red word and no reason.
          if (!ok) ...[
            const _Dot(),
            Expanded(
              child: Text(
                s.error ?? 'scrape failed',
                style: ts(size: TZ.caption, color: TC.red),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(width: 10),
          Text(
            '1-4 mode · ←→ cycle · r refresh · q quit',
            style: ts(size: TZ.caption, color: TC.dim),
            maxLines: 1,
            softWrap: false,
          ),
        ],
      ),
    );
  }
}

/// `label: value` pair in the status line.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ', style: ts(size: TZ.caption, color: TC.dim)),
        child,
      ],
    );
  }
}

/// Separator between status fields.
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text('·', style: ts(size: TZ.small, color: TC.dim)),
    );
  }
}

// ---------------------------------------------------------------------------

/// Short typed-out boot sequence. Purely cosmetic; tap anywhere to skip.
class BootSplash extends StatefulWidget {
  const BootSplash({super.key, required this.endpoint, required this.onDone});

  final String endpoint;
  final VoidCallback onDone;

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> {
  late final List<String> _script = [
    'promterm 1.0.0  ·  prometheus terminal',
    'panel     1024x600 @ 7"',
    'endpoint  ${widget.endpoint}',
    'probing scrape targets ......... ok',
    'loading node_exporter series ... ok',
    'loading dcgm series ............ ok',
    'ready.',
  ];

  int _shown = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 170), (t) {
      if (!mounted) return;
      if (_shown >= _script.length) {
        t.cancel();
        Timer(const Duration(milliseconds: 350), () {
          if (mounted) widget.onDone();
        });
        return;
      }
      setState(() => _shown++);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onDone,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: TC.bg,
        padding: const EdgeInsets.all(30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'PROMTERM',
              style: ts(
                size: 48,
                color: TC.bright,
                weight: FontWeight.w700,
                letterSpacing: 12,
              ),
            ),
            const SizedBox(height: 8),
            Container(width: 560, height: 1, color: TC.border),
            const SizedBox(height: 18),
            for (var i = 0; i < _shown; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Text('>', style: ts(color: TC.dim)),
                    const SizedBox(width: 8),
                    Text(
                      _script[i],
                      style: ts(
                        color: i == _script.length - 1 ? TC.bright : TC.mid,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const BlinkCursor(size: TZ.large),
            const Spacer(),
            Text('tap to skip', style: ts(size: TZ.caption, color: TC.dim)),
          ],
        ),
      ),
    );
  }
}
