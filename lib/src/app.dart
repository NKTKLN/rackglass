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
import 'widgets/crt.dart';

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
  const PromTermApp({super.key});

  @override
  State<PromTermApp> createState() => _PromTermAppState();
}

class _PromTermAppState extends State<PromTermApp> {
  final MetricsStore _store = MetricsStore();
  final FocusNode _focus = FocusNode();

  AppMode _mode = AppMode.dash;
  bool _crt = true;
  bool _booted = false;

  // The GRAPHS screen owns expensive range queries, so it is kept alive across
  // tab switches instead of being rebuilt from scratch each time.
  late final Widget _graphs = GraphsScreen(store: _store);

  @override
  void initState() {
    super.initState();
    _store.start();
  }

  @override
  void dispose() {
    _store.dispose();
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
    } else if (k == LogicalKeyboardKey.keyC) {
      setState(() => _crt = !_crt);
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
                Positioned.fill(child: CrtOverlay(enabled: _crt)),
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
          _HeaderBar(store: _store),
          _TabBar(
            mode: _mode,
            crt: _crt,
            onPick: (m) => setState(() => _mode = m),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
              child: _body(),
            ),
          ),
          _StatusBar(store: _store, mode: _mode),
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

class _HeaderBar extends StatefulWidget {
  const _HeaderBar({required this.store});

  final MetricsStore store;

  @override
  State<_HeaderBar> createState() => _HeaderBarState();
}

class _HeaderBarState extends State<_HeaderBar> {
  late final Timer _clock = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _clock; // start it
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final ok = s.healthy;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.border)),
      ),
      child: Row(
        children: [
          Text(
            'PROMTERM',
            style: ts(
              size: 15,
              color: TC.fg,
              weight: FontWeight.w700,
              letterSpacing: 3,
              glow: 9,
            ),
          ),
          const SizedBox(width: 10),
          Text('│', style: ts(size: 13, color: TC.border)),
          const SizedBox(width: 10),
          Text(
            s.endpoint.replaceFirst(RegExp(r'^https?://'), ''),
            style: ts(size: 11, color: TC.mid),
          ),
          const Spacer(),
          Text(
            ok ? '● ONLINE' : '● ${(s.error ?? "OFFLINE").toUpperCase()}',
            style: ts(
              size: 11,
              color: ok ? TC.fg : TC.red,
              weight: FontWeight.w700,
              glow: 6,
            ),
          ),
          const SizedBox(width: 12),
          Text('│', style: ts(size: 13, color: TC.border)),
          const SizedBox(width: 12),
          Text(
            fmtDate(DateTime.now()),
            style: ts(size: 12, color: TC.bright),
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.mode, required this.crt, required this.onPick});

  final AppMode mode;
  final bool crt;
  final ValueChanged<AppMode> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TC.border)),
      ),
      child: Row(
        children: [
          for (final m in AppMode.values)
            _Tab(mode: m, selected: m == mode, onTap: () => onPick(m)),
          const Spacer(),
          Text(
            crt ? 'CRT ON  [c]' : 'CRT OFF [c]',
            style: ts(size: 10, color: crt ? TC.mid : TC.dim),
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
        constraints: const BoxConstraints(minWidth: 132),
        margin: const EdgeInsets.only(right: 4, top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? TC.fg.withValues(alpha: 0.13) : null,
          border: Border.all(color: selected ? TC.borderLit : TC.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              mode.key,
              style: ts(size: 9, color: selected ? TC.fg : TC.dim),
            ),
            const SizedBox(width: 6),
            Text(
              mode.label,
              style: ts(
                size: 13,
                color: selected ? TC.bright : TC.mid,
                weight: selected ? FontWeight.w700 : FontWeight.w400,
                letterSpacing: 1.6,
                glow: selected ? 7 : 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.store, required this.mode});

  final MetricsStore store;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final snap = store.snapshot;
    final err = store.error;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TC.border)),
      ),
      child: Row(
        children: [
          const BlinkCursor(size: 11),
          const SizedBox(width: 6),
          if (err != null)
            Text(
              'SCRAPE FAILED ($err) · ${store.consecutiveErrors} in a row'
              '${store.lastSuccess != null ? " · last ok ${fmtClock(store.lastSuccess!)}" : ""}',
              style: ts(size: 10, color: TC.red),
            )
          else if (snap != null)
            Text(
              '${snap.nodes.length} node targets · ${snap.targetsDown} down · '
              '${snap.gpus.length} gpu · poll ${snap.fetchMillis}ms · '
              'updated ${fmtClock(snap.at)}',
              style: ts(size: 10, color: TC.mid),
            )
          else
            Text('waiting for first scrape…', style: ts(size: 10, color: TC.dim)),
          const Spacer(),
          Text(
            '1-4/F1-F4 mode  ·  ←→ cycle  ·  r refresh  ·  c crt  ·  q quit',
            style: ts(size: 10, color: TC.dim),
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
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'PROMTERM',
              style: ts(
                size: 46,
                color: TC.fg,
                weight: FontWeight.w700,
                letterSpacing: 14,
                glow: 18,
              ),
            ),
            const SizedBox(height: 6),
            Container(width: 520, height: 1, color: TC.border),
            const SizedBox(height: 16),
            for (var i = 0; i < _shown; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Text('>', style: ts(size: 13, color: TC.dim)),
                    const SizedBox(width: 8),
                    Text(
                      _script[i],
                      style: ts(
                        size: 13,
                        color: i == _script.length - 1 ? TC.bright : TC.mid,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const BlinkCursor(size: 14),
            const Spacer(),
            Text('tap to skip', style: ts(size: 10, color: TC.gridLine)),
          ],
        ),
      ),
    );
  }
}
