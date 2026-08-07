import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
  dash('DASH', 'F1'),
  graphs('GRAPHS', 'F2'),
  nodes('NODES', 'F3'),
  capture('CAPTURE', 'F4');

  const AppMode(this.label, this.key);

  final String label;
  final String key;
}

class PromTermApp extends StatefulWidget {
  const PromTermApp({super.key, this.store, this.showBootSplash = true});

  /// Injected in tests; production builds let the app own its store.
  final MetricsStore? store;
  final bool showBootSplash;

  @override
  State<PromTermApp> createState() => _PromTermAppState();
}

class _PromTermAppState extends State<PromTermApp> {
  late final MetricsStore _store = widget.store ?? MetricsStore();
  final FocusNode _focus = FocusNode();

  AppMode _mode = AppMode.dash;
  late bool _booted = !widget.showBootSplash;

  // The GRAPHS screen owns expensive range queries, so it is kept alive across
  // tab switches instead of being rebuilt from scratch each time.
  late final Widget _graphs = GraphsScreen(store: _store);

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
    _focus.dispose();
    super.dispose();
  }

  void _handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final k = e.logicalKey;
    void go(AppMode m) => setState(() => _mode = m);

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
    } else if (k == LogicalKeyboardKey.keyQ ||
        k == LogicalKeyboardKey.escape) {
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
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) => Column(
        children: [
          _TopBar(
            store: _store,
            mode: _mode,
            onPick: (m) => setState(() => _mode = m),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
              child: _body(),
            ),
          ),
          _StatusBar(store: _store),
        ],
      ),
    );
  }

  Widget _body() {
    // IndexedStack rather than a switch: keeps each screen's state (selected
    // node, loaded range data) alive while you flip between modes.
    return IndexedStack(
      index: _mode.index,
      sizing: StackFit.expand,
      children: [
        DashboardScreen(store: _store),
        _graphs,
        NodesScreen(store: _store),
        const CaptureScreen(),
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

/// Mode buttons, link state and the clock on one line. There is no separate
/// title bar: the app name and the endpoint told you nothing you could act on,
/// and the row they cost is worth more to the data.
class _TopBar extends StatefulWidget {
  const _TopBar({
    required this.store,
    required this.mode,
    required this.onPick,
  });

  final MetricsStore store;
  final AppMode mode;
  final ValueChanged<AppMode> onPick;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
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
    final ok = widget.store.healthy;
    return Container(
      height: Chrome.top,
      // Bottom padding keeps the buttons clear of the divider rule; without it
      // the two rectangles read as one smudged line.
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.border)),
      ),
      child: Row(
        children: [
          for (final m in AppMode.values)
            _Tab(
              mode: m,
              selected: m == widget.mode,
              onTap: () => widget.onPick(m),
            ),
          const Spacer(),
          Text(
            ok ? '● ONLINE' : '● ${(widget.store.error ?? "OFFLINE").toUpperCase()}',
            style: ts(
              color: ok ? TC.green : TC.red,
              weight: FontWeight.w700,
            ),
            maxLines: 1,
            softWrap: false,
          ),
          const SizedBox(width: 14),
          Text(
            fmtDate(DateTime.now()),
            style: ts(size: TZ.large, color: TC.bright),
          ),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              mode.key,
              style: ts(size: TZ.caption, color: selected ? TC.bg : TC.dim),
            ),
            const SizedBox(width: 6),
            Text(
              mode.label,
              style: ts(
                size: TZ.large,
                color: selected ? TC.bg : TC.mid,
                weight: selected ? FontWeight.w700 : FontWeight.w400,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.store});

  final MetricsStore store;

  @override
  Widget build(BuildContext context) {
    final snap = store.snapshot;
    final err = store.error;
    return Container(
      height: Chrome.status,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TC.border)),
      ),
      child: Row(
        children: [
          const BlinkCursor(size: TZ.small),
          const SizedBox(width: 6),
          Expanded(
            child: err != null
                ? Text(
                    'SCRAPE FAILED ($err) · ${store.consecutiveErrors} in a row'
                    '${store.lastSuccess != null ? " · last ok ${fmtClock(store.lastSuccess!)}" : ""}',
                    style: ts(size: TZ.caption, color: TC.red),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : snap != null
                ? Text(
                    '${store.endpoint.replaceFirst(RegExp(r"^https?://"), "")} · '
                    '${snap.nodes.length} node targets · ${snap.targetsDown} down · '
                    '${snap.gpus.length} gpu · poll ${snap.fetchMillis}ms · '
                    'updated ${fmtClock(snap.at)}',
                    style: ts(size: TZ.caption, color: TC.mid),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    'waiting for first scrape…',
                    style: ts(size: TZ.caption, color: TC.dim),
                  ),
          ),
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
    'promterm 0.1.0  ·  prometheus terminal',
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
