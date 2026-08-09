import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/util.dart';

/// Height of a sparkline glyph, 0 (▁) to 7 (█).
int level(String glyph) => '▁▂▃▄▅▆▇█'.indexOf(glyph);

int topLevel(String strip) => strip
    .split('')
    .where((c) => c != '·')
    .map(level)
    .fold(0, (a, b) => a > b ? a : b);

void main() {
  group('sparkline scale', () {
    test('a steady 12% reads low against a fixed 0-100 scale', () {
      final strip = sparkText(
        [11.8, 12.0, 12.3, 11.9, 12.1, 12.0],
        6,
        min: 0,
        max: 100,
      );
      expect(strip.contains('█'), isFalse);
      expect(topLevel(strip), lessThanOrEqualTo(1));
    });

    test('autoscaling pins the window maximum to the top whatever it is', () {
      // This is the trap: without an explicit max, the largest sample renders
      // at full height by construction, so an idle CPU draws a solid wall next
      // to a bar gauge reporting 12%.
      final strip = sparkText([11.8, 12.0, 12.3, 11.9, 12.1, 12.0], 6, min: 0);
      expect(strip.contains('█'), isTrue);
    });

    test('a fixed scale still shows shape when the load is real', () {
      final strip = sparkText([5.0, 30.0, 60.0, 95.0], 4, min: 0, max: 100);
      expect(topLevel(strip), 7);
      expect(level(strip[0]), lessThan(level(strip[3])));
    });

    test('values beyond the fixed scale clamp instead of rescaling it', () {
      final strip = sparkText([0.0, 50.0, 140.0], 3, min: 0, max: 100);
      expect(level(strip[2]), 7);
      expect(level(strip[1]), 4);
    });

    test('temperature uses its band, so sensor noise stays flat', () {
      final strip = sparkText(
        [43.2, 43.6, 43.4, 43.5, 43.3],
        5,
        min: 20,
        max: 100,
      );
      final levels = strip.split('').map(level).toSet();
      expect(levels.length, 1, reason: 'a 0.4 °C wobble must not draw relief');
    });

    test('under three samples the strip stays an empty track', () {
      expect(sparkText([12.0, 12.0], 6, min: 0, max: 100), '······');
    });

    test('missing samples remain visible as gaps', () {
      final strip = sparkText([10.0, 20.0, null, 30.0, 40.0], 5, min: 0, max: 100);
      expect(strip[2], '·');
      expect(strip.length, 5);
    });
  });
}
