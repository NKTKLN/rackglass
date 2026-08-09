@Tags(['preview'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/app.dart';
import 'package:rackglass/src/prom/prom_client.dart';
import 'package:rackglass/src/state/metrics_store.dart';

import 'fake_capture.dart';
import 'fake_prometheus.dart';

/// Renders each mode to `test/preview/*.png` at the exact panel resolution, so
/// the design can be reviewed without a GTK toolchain.
///
///   flutter test test/preview_test.dart \
///     --dart-define=RACKGLASS_PREVIEW=true --update-goldens
void main() {
  // Off in a plain `flutter test` run: these write files rather than assert.
  const skip = !bool.fromEnvironment('RACKGLASS_PREVIEW');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('JetBrainsMono');
    for (final f in [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-Bold.ttf',
    ]) {
      loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await loader.load();
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    bool gpuUp = false,
    bool boot = false,
    String? tapMode,
    List<String> thenTap = const [],
  }) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://192.168.1.13:9090',
        client: FakePrometheus(gpuUp: gpuUp).client(),
      ),
    );
    addTearDown(store.dispose);
    // A real ffmpeg would be spawned the moment CAPTURE is selected.
    final capture = FakeCapture().controller;
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    addTearDown(capture.dispose);

    await tester.pumpWidget(RackglassApp(store: store, capture: capture, showBootSplash: boot));
    await store.refresh();
    await tester.pump();
    // Two polls so the sparkline history has something in it.
    await store.refresh();
    await tester.pump(const Duration(milliseconds: 120));

    if (tapMode != null) {
      await tester.tap(find.text(tapMode));
      await tester.pump(const Duration(milliseconds: 400));
    }
    for (final t in thenTap) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 400));
    }

    await expectLater(
      find.byType(RackglassApp),
      matchesGoldenFile('preview/$name.png'),
    );
  }

  testWidgets('dash · gpu exporter down', (t) => shoot(t, '01-dash-gpu-down'), skip: skip);

  testWidgets(
    'dash · gpu exporter live',
    (t) => shoot(t, '02-dash-gpu-live', gpuUp: true),
    skip: skip,
  );

  testWidgets(
    'graphs',
    (t) => shoot(t, '03-graphs', gpuUp: true, tapMode: 'GRAPHS'),
    skip: skip,
  );

  testWidgets(
    'nodes · hypervisor',
    (t) => shoot(t, '04-nodes-host', tapMode: 'NODES'),
    skip: skip,
  );

  testWidgets(
    'nodes · guest',
    (t) => shoot(t, '05-nodes-guest', tapMode: 'NODES', thenTap: ['vm-node-1']),
    skip: skip,
  );

  testWidgets('capture stub', (t) => shoot(t, '06-capture', tapMode: 'CAPTURE'), skip: skip);

  testWidgets('boot splash', (t) => shoot(t, '07-boot', boot: true), skip: skip);
}
