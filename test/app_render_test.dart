import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/app.dart';
import 'package:rackglass/src/prom/prom_client.dart';
import 'package:rackglass/src/state/metrics_store.dart';
import 'package:rackglass/src/widgets/term_panel.dart';

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
    FakePrometheus? prometheus,
    FakeCapture? fakeCapture,
  }) async {
    tester.view.physicalSize = _panel;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake =
        prometheus ??
        FakePrometheus(gpuUp: gpuUp, failEverything: failEverything);
    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: fake.client(),
      ),
    );
    addTearDown(store.dispose);
    // A real ffmpeg would be spawned the moment CAPTURE is selected.
    final capture = (fakeCapture ?? FakeCapture()).controller;
    addTearDown(capture.dispose);
    // Unmount before the test ends so the header clock and the blinking cursor
    // are disposed; otherwise they trip the pending-timer/ticker check.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      RackglassApp(store: store, capture: capture, showBootSplash: false),
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

  testWidgets('every header spans exactly the columns it names', (
    tester,
  ) async {
    await pumpApp(tester);

    // Header and cell are keyed in pairs, so this compares the boxes rather
    // than whatever text happens to be inside them — a value can be flushed
    // right inside its cell and still belong to a heading centred over it.
    //
    // A heading that names several columns is pinned to the first and the last
    // of them: `CPU` covers the number and its bar, `MEMORY` the percentage,
    // its bar and the used/total pair. The header row computes its own
    // geometry, so this is what keeps it in step with the rows.
    const spans = <String, (String, String)>{
      'name': ('name', 'name'),
      'cpu': ('cpu', 'cpuBar'),
      'mem': ('mem', 'memText'),
      'root': ('root', 'root'),
      'uptime': ('uptime', 'uptime'),
    };

    spans.forEach((id, span) {
      final head = find.byKey(ValueKey('head-$id'));
      final first = find.byKey(ValueKey('cell-${span.$1}-vm-node-1'));
      final last = find.byKey(ValueKey('cell-${span.$2}-vm-node-1'));
      expect(head, findsOneWidget, reason: 'header $id');
      expect(first, findsOneWidget, reason: 'cell ${span.$1}');
      expect(last, findsOneWidget, reason: 'cell ${span.$2}');
      expect(
        tester.getTopLeft(head).dx,
        moreOrLessEquals(tester.getTopLeft(first).dx, epsilon: 0.5),
        reason: '$id header does not start at its column',
      );
      expect(
        tester.getTopRight(head).dx,
        moreOrLessEquals(tester.getTopRight(last).dx, epsilon: 0.5),
        reason: '$id header does not end at its column',
      );
    });
  });

  testWidgets('the last column keeps clear of the panel frame', (
    tester,
  ) async {
    await pumpApp(tester);

    // A right-flushed number carries no padding of its own, so without a
    // trailing margin it reads as jammed against the border.
    final cell = find.byKey(const ValueKey('cell-uptime-vm-node-1'));
    final panel = find.ancestor(of: cell, matching: find.byType(TermPanel));
    expect(panel, findsOneWidget);
    expect(
      tester.getRect(panel).right - tester.getRect(cell).right,
      greaterThanOrEqualTo(16.0),
      reason: 'uptime is crowding the panel edge',
    );
  });

  testWidgets('nothing in a row overlaps anything else', (tester) async {
    await pumpApp(tester);

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

  testWidgets('graphs mode loads history lazily and draws it', (
    tester,
  ) async {
    final prometheus = FakePrometheus();
    await pumpApp(tester, prometheus: prometheus);

    // IndexedStack keeps the screen alive, but an unopened GRAPHS tab must not
    // issue six expensive range queries during app startup.
    expect(prometheus.rangeCalls, 0);

    await tester.tap(find.text('GRAPHS'));
    // One frame activates the screen and issues the queries; the next one
    // paints what came back.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(prometheus.rangeCalls, greaterThanOrEqualTo(6));
    expect(find.text('UTILISATION %'), findsOneWidget);
    expect(find.text('TEMPERATURE °C'), findsOneWidget);
    expect(find.text('MEMORY USED %'), findsOneWidget);
    expect(find.text('SPEEDTEST DOWN · MBIT/S'), findsOneWidget);
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
    // temp7 has no node_hwmon_sensor_label in the fake response. Raw hwmon
    // channels must still be visible rather than being lost in the label join.
    expect(find.text('temp7'), findsOneWidget);
    expect(find.text('HWMON SENSORS'), findsOneWidget);

    await tester.tap(find.text('vm-node-1'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('VM-NODE-1 · NODES'), findsOneWidget);
    // A guest exports no hwmon chip. The section is dropped rather than kept
    // as a heading over an apology.
    expect(find.text('HWMON SENSORS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nodes mode handles an empty node target set', (tester) async {
    final prometheus = FakePrometheus(noNodeTargets: true);
    await pumpApp(tester, prometheus: prometheus);

    await tester.tap(find.text('NODES'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('NO NODE TARGETS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen does not respawn the capture process', (tester) async {
    final capture = FakeCapture();
    await pumpApp(tester, fakeCapture: capture);

    await tester.tap(find.text('CAPTURE'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(capture.spawned, hasLength(1));

    await tester.tap(find.text('FULLSCREEN'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(capture.spawned, hasLength(1));

    await tester.tap(find.text('EXIT FULL'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(capture.spawned, hasLength(1));
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
