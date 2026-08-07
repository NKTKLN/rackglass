import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promterm/src/app.dart';
import 'package:promterm/src/prom/prom_client.dart';
import 'package:promterm/src/state/metrics_store.dart';

import 'fake_capture.dart';
import 'fake_prometheus.dart';

/// The real panel. Every layout assertion runs at exactly this size.
const _panel = Size(1024, 600);

void main() {
  // flutter_test's stand-in font makes every glyph one em wide, which would
  // report overflows the real 0.6em monospace never hits. Load the shipped
  // font so the layout assertions measure what the panel actually shows.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('JetBrainsMono');
    for (final f in [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-Bold.ttf',
    ]) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  });

  // A RenderFlex overflow throws in these tests rather than painting a red
  // stripe, which is the point: the 7" panel has no room to spare.
  Future<MetricsStore> pumpApp(
    WidgetTester tester, {
    bool gpuUp = false,
    bool failEverything = false,
  }) async {
    tester.view.physicalSize = _panel;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakePrometheus(gpuUp: gpuUp, failEverything: failEverything);
    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: fake.client(),
      ),
    );
    addTearDown(store.dispose);
    // A real ffmpeg would be spawned the moment CAPTURE is selected.
    final capture = FakeCapture().controller;
    addTearDown(capture.dispose);
    // Unmount before the test ends so the header clock and the blinking cursor
    // are disposed; otherwise they trip the pending-timer/ticker check.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      PromTermApp(store: store, capture: capture, showBootSplash: false),
    );
    await store.refresh();
    // The status-bar cursor blinks forever, so pumpAndSettle would never
    // return; pump a couple of frames explicitly instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return store;
  }

  testWidgets('dashboard renders the live cluster within 1024x600', (
    tester,
  ) async {
    await pumpApp(tester);

    // Top bar is mode buttons only; link state and clock sit in the status
    // line at the bottom with the rest of the diagnostics.
    expect(find.text('online'), findsOneWidget);
    expect(find.text('DASH'), findsOneWidget);
    expect(find.text('GRAPHS'), findsOneWidget);
    expect(find.text('NODES'), findsOneWidget);
    expect(find.text('CAPTURE'), findsOneWidget);

    // Every guest has a row, including the down one.
    for (final name in [
      'vm-node-1',
      'vm-ops-node',
      'vm-vpn',
      'vm-amnezia-proxy',
      'vm-gpu-worker-1',
    ]) {
      expect(find.text(name), findsOneWidget, reason: 'row for $name');
    }
    // The hypervisor is the top row of panels, not a table row.
    expect(find.text('pve-host'), findsNothing);
    expect(find.text('[ 1 DOWN ]'), findsOneWidget);
    // The down target has no series behind it: those cells must read `--`,
    // never a fabricated 0.
    expect(find.text('--'), findsWidgets);
    // Role and core count moved to NODES; the table is one live line per node.
    expect(find.text('ROLE'), findsNothing);
    expect(find.text('CORES'), findsNothing);
    expect(find.text('ROOT'), findsOneWidget);

    // CPU package temperature is picked out of hwmon by label, not sensor id.
    expect(find.text('43.4'), findsOneWidget);
    expect(find.text('Tctl'), findsWidgets);

    // Host memory: (33572134912 - 17745612800) B = 14.7 GiB used of 31.3 GiB.
    expect(find.text('14.7G'), findsOneWidget);
    expect(find.textContaining('/ 31.3G'), findsOneWidget);
  });

  testWidgets('a down GPU exporter shows stale values, never a live zero', (
    tester,
  ) async {
    await pumpApp(tester, gpuUp: false);

    expect(find.text('[ DOWN ]'), findsOneWidget);
    expect(find.text('[ LIVE ]'), findsNothing);
    // 166055s of staleness must be stated in the panel.
    expect(find.textContaining('LAST SEEN'), findsOneWidget);
    expect(find.textContaining('1d 22h'), findsOneWidget);
    expect(
      find.textContaining('vm-gpu-worker-1 exporter unreachable'),
      findsOneWidget,
    );
  });

  testWidgets('table cells line up under their headers and never overlap', (
    tester,
  ) async {
    await pumpApp(tester);

    // A column header and the cell beneath it must share an edge, or the table
    // reads as scrambled even though nothing overflows.
    void sharesLeft(Finder header, Finder cell, String what) {
      expect(
        tester.getTopLeft(header).dx,
        moreOrLessEquals(tester.getTopLeft(cell).dx, epsilon: 0.5),
        reason: '$what is not left-aligned with its header',
      );
    }

    sharesLeft(find.text('INSTANCE'), find.text('vm-node-1'), 'instance');
    // 'MEMORY' is also the memory panel's title; the table header is the later
    // of the two in tree order, and like CPU it sits right-aligned over its
    // percent.
    expect(
      tester.getTopRight(find.text('MEMORY').last).dx,
      moreOrLessEquals(tester.getTopRight(find.text('64%')).dx, epsilon: 0.5),
      reason: 'MEMORY is not right-aligned with its percent',
    );

    // Right-aligned columns share their right edge instead. 'CPU' also labels
    // a strip in the host panel, so take the later one.
    expect(
      tester.getTopRight(find.text('CPU').last).dx,
      moreOrLessEquals(
        tester.getTopRight(find.text('10.6%')).dx,
        epsilon: 0.5,
      ),
      reason: 'CPU% is not right-aligned with its header',
    );

    sharesLeft(find.text('ROOT'), find.text('13.3G/61.0G'), 'root');

    // Nothing in a row may sit on top of anything else in that row.
    final cells = <String, Rect>{
      'name': tester.getRect(find.text('vm-node-1')),
      'cpu': tester.getRect(find.text('10.6%')),
      'mem': tester.getRect(find.text('4.9G/7.7G')),
      'memPct': tester.getRect(find.text('64%')),
      'root': tester.getRect(find.text('13.3G/61.0G')),
    };
    for (final a in cells.entries) {
      for (final b in cells.entries) {
        if (a.key == b.key) continue;
        expect(
          a.value.overlaps(b.value),
          isFalse,
          reason: '${a.key} overlaps ${b.key}',
        );
      }
    }
  });

  testWidgets('a live GPU exporter shows current values', (tester) async {
    await pumpApp(tester, gpuUp: true);

    // A healthy GPU carries no badge at all; only the bad state is labelled.
    expect(find.text('[ LIVE ]'), findsNothing);
    expect(find.text('[ DOWN ]'), findsNothing);
    // 9216 MiB used of 9216+7154 MiB total.
    expect(find.textContaining('9.0G of 16.0G'), findsOneWidget);
    expect(find.textContaining('212 W'), findsOneWidget);
  });

  testWidgets('every mode lays out without overflow', (tester) async {
    await pumpApp(tester);

    for (final label in ['GRAPHS', 'NODES', 'CAPTURE', 'DASH']) {
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '$label mode');
    }
  });

  testWidgets('graphs mode issues range queries and draws them', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('GRAPHS'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('UTILISATION %'), findsOneWidget);
    expect(find.text('TEMPERATURE °C'), findsOneWidget);
    expect(find.text('MEMORY USED %'), findsOneWidget);
    expect(find.text('NETWORK RX · KB/S'), findsOneWidget);
    expect(find.text('NO DATA IN RANGE'), findsNothing);

    // Switching the window re-queries at a coarser step.
    await tester.tap(find.text('6h'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('step 1m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nodes mode switches detail when a target is picked', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('NODES'));
    await tester.pump(const Duration(milliseconds: 50));

    // Hypervisor is selected by default.
    expect(find.text('PVE-HOST · HYPERVISOR'), findsOneWidget);

    await tester.tap(find.text('vm-node-1'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('VM-NODE-1 · NODES'), findsOneWidget);
    expect(find.text('HWMON SENSORS'), findsOneWidget);
    // Guests export no hwmon sensors; say so rather than showing an empty gap.
    expect(find.text('none exported by this target'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dead Prometheus surfaces the error instead of blank panels', (
    tester,
  ) async {
    final store = await pumpApp(tester, failEverything: true);

    expect(store.snapshot, isNull);
    expect(store.error, isNotNull);
    expect(find.text('offline'), findsOneWidget);
    // The tag says something is wrong; the line beside it says what.
    // Twice: the status line, and the dashboard's own empty state.
    expect(find.textContaining('HTTP 503'), findsNWidgets(2));
    expect(find.textContaining('NO DATA'), findsOneWidget);
  });

  testWidgets('keyboard shortcuts move between modes', (tester) async {
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('PVE-HOST · HYPERVISOR'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('CAPTURE · '), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ROOT'), findsOneWidget);
  });
}
