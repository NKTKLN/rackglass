import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promterm/src/app.dart';
import 'package:promterm/src/prom/prom_client.dart';
import 'package:promterm/src/state/metrics_store.dart';

import 'fake_prometheus.dart';

/// Sweeps every visible `Text` on a screen and fails if any two of them share
/// pixels.
///
/// This is the failure mode that never trips a `RenderFlex` overflow: a widget
/// positioned over a border, a label with no room to ellipsize, a stack whose
/// children happen to land on each other. It looks broken on the panel and is
/// invisible to every other check in this suite.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('JetBrainsMono');
    for (final f in [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-Bold.ttf',
    ]) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
    }
    await loader.load();
  });

  Future<void> check(
    WidgetTester tester,
    String mode, {
    bool gpuUp = false,
  }) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: FakePrometheus(gpuUp: gpuUp).client(),
      ),
    );
    addTearDown(store.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(PromTermApp(store: store, showBootSplash: false));
    await store.refresh();
    await tester.pump();
    if (mode != 'DASH') {
      await tester.tap(find.text(mode));
      await tester.pump(const Duration(milliseconds: 400));
    }

    final boxes = <(String, Rect)>[];
    for (final el in find.byType(Text).evaluate()) {
      final widget = el.widget as Text;
      final render = el.renderObject as RenderBox;
      if (!render.attached || !render.hasSize) continue;
      final label = widget.data ?? widget.textSpan?.toPlainText() ?? '?';
      if (label.trim().isEmpty) continue;
      boxes.add((
        label.replaceAll('\n', ' '),
        render.localToGlobal(Offset.zero) & render.size,
      ));
    }

    final clashes = <String>[];
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final o = boxes[i].$2.intersect(boxes[j].$2);
        // Touching edges are fine; shared area is not.
        if (o.width > 0.5 && o.height > 0.5) {
          clashes.add(
            '"${boxes[i].$1}" ${boxes[i].$2}  <>  '
            '"${boxes[j].$1}" ${boxes[j].$2}',
          );
        }
      }
    }
    expect(
      clashes,
      isEmpty,
      reason: '$mode has overlapping text:\n${clashes.join("\n")}',
    );
  }

  testWidgets('DASH has no overlapping text', (t) => check(t, 'DASH'));
  testWidgets(
    'DASH with a live GPU has no overlapping text',
    (t) => check(t, 'DASH', gpuUp: true),
  );
  testWidgets('GRAPHS has no overlapping text', (t) => check(t, 'GRAPHS'));
  testWidgets('NODES has no overlapping text', (t) => check(t, 'NODES'));
  testWidgets('CAPTURE has no overlapping text', (t) => check(t, 'CAPTURE'));
}
