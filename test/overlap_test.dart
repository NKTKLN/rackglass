import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promterm/src/app.dart';
import 'package:promterm/src/prom/prom_client.dart';
import 'package:promterm/src/state/metrics_store.dart';
import 'package:promterm/src/widgets/gauges.dart';

import 'fake_capture.dart';
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
    // A real ffmpeg would be spawned the moment CAPTURE is selected.
    final capture = FakeCapture().controller;
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    addTearDown(capture.dispose);

    await tester.pumpWidget(PromTermApp(store: store, capture: capture, showBootSplash: false));
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

  /// Bars and sparklines put the newest sample at the right-hand end, so a cell
  /// that does not fit is not cosmetic — it drops the most recent reading and
  /// leaves an older one looking current. They carry no ellipsis to reveal it.
  Future<void> checkGauges(WidgetTester tester, String mode) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: FakePrometheus(gpuUp: true).client(),
      ),
    );
    addTearDown(store.dispose);
    final capture = FakeCapture().controller;
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    addTearDown(capture.dispose);

    await tester.pumpWidget(PromTermApp(store: store, capture: capture, showBootSplash: false));
    // Several polls so the history rings hold a real shape, not the dotted
    // placeholder that fits anything.
    for (var i = 0; i < 6; i++) {
      await store.refresh();
      await tester.pump();
    }
    if (mode != 'DASH') {
      await tester.tap(find.text(mode));
      await tester.pump(const Duration(milliseconds: 400));
    }

    final clipped = <String>[];
    final degenerate = <String>[];
    var inspected = 0;
    for (final el in find.byType(Text).evaluate()) {
      // Identify gauges by what drew them, not by their glyphs: the blinking
      // cursor is a block character too, and matching on the alphabet picked
      // it up as a one-cell gauge.
      final isGauge = el.findAncestorWidgetOfExactType<BarGauge>() != null ||
          el.findAncestorWidgetOfExactType<SparkText>() != null;
      if (!isGauge) continue;
      final widget = el.widget as Text;
      final label = widget.data ?? widget.textSpan?.toPlainText() ?? '';
      final render = el.renderObject as RenderParagraph;
      if (!render.hasSize) continue;
      inspected++;
      final wants = render.getMaxIntrinsicWidth(double.infinity);
      if (wants > render.size.width + 0.5) {
        clipped.add(
          '"$label" wants ${wants.toStringAsFixed(1)}px '
          'in ${render.size.width.toStringAsFixed(1)}px',
        );
      }
      // A gauge that collapsed to a couple of cells carries no reading. It
      // happens when a sibling Expanded eats the row, and it looks like a
      // stray block rather than like a bug.
      if (label.trim().length < 4) {
        degenerate.add('"$label" rendered only ${label.trim().length} cells');
      }
    }
    // Without this the check passes by finding nothing — a glyph added to the
    // bar alphabet, or a mode that stopped drawing gauges, would go unnoticed.
    expect(
      inspected,
      greaterThan(4),
      reason: '$mode: the gauge sweep matched almost nothing, so it proves '
          'nothing — check the glyph set',
    );
    expect(
      clipped,
      isEmpty,
      reason: '$mode clips a gauge:\n${clipped.join("\n")}',
    );
    expect(
      degenerate,
      isEmpty,
      reason: '$mode collapses a gauge:\n${degenerate.join("\n")}',
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

  testWidgets('DASH never clips a bar or sparkline', (t) => checkGauges(t, 'DASH'));
  testWidgets('NODES never clips a bar or sparkline', (t) => checkGauges(t, 'NODES'));
}
