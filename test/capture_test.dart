import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/capture/capture_controller.dart';

import 'fake_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Frames arrive back to back with no length prefix; the reassembly has to
  /// find the boundaries itself.
  List<int> stream(List<int> frame, int count) => [
    for (var i = 0; i < count; i++) ...frame,
  ];

  test('ffmpeg is asked to stream-copy MJPEG off the device', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);

    await fake.controller.start();

    final cmd = fake.commands.single;
    expect(cmd.first, 'ffmpeg');
    expect(cmd, containsAllInOrder(['-f', 'v4l2']));
    expect(cmd, containsAllInOrder(['-input_format', 'mjpeg']));
    expect(cmd, containsAllInOrder(['-i', '/dev/video0']));
    // The device already emits JPEG. Re-encoding it would burn CPU to produce
    // a worse picture.
    expect(cmd, containsAllInOrder(['-c:v', 'copy']));
    expect(cmd.last, '-');
    expect(fake.controller.state, CaptureState.starting);
  });

  test('concatenated JPEGs are split and decoded into frames', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    fake.latest.emit(stream(litFrame(), 4));
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // The last frame has no following SOI to close it, so three of four are
    // complete. Decoding is slower than the pipe, so some are dropped by
    // design — what matters is that all three were parsed out.
    expect(
      fake.controller.framesTotal + fake.controller.framesDropped,
      3,
    );
    expect(fake.controller.framesTotal, greaterThanOrEqualTo(1));
    expect(fake.controller.decodeErrors, 0);
    expect(fake.controller.frame, isNotNull);
    expect(fake.controller.frame!.width, 16);
    expect(fake.controller.state, CaptureState.streaming);
  });

  /// Keeps frames flowing for [ms], the way a real 30 fps stream would.
  Future<void> feed(FakeCapture fake, List<int> frame, int ms) async {
    final deadline = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(deadline)) {
      fake.latest.emit(stream(frame, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('a brief dark patch does not raise the no-signal banner', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    await feed(fake, litFrame(), 400);
    // A fade to black, a mode change, one dark scene — shorter than the hold.
    await feed(fake, darkFrame(), 500);

    expect(fake.controller.state, CaptureState.streaming);
  });

  test('a console is a picture, however dark it averages', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    // Black background, a little bright text: mean 4.3, under the black level,
    // which is exactly what a terminal looks like and exactly what this card
    // spends its life pointed at. Judged on average brightness alone this
    // raises NO SIGNAL over a picture that is plainly there.
    await feed(fake, consoleFrame(), 5000);

    expect(fake.controller.state, CaptureState.streaming);
    expect(fake.controller.frame, isNotNull);
  });

  test('dark frames either side of a stall do not raise the banner', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    // One burst, spaced clear of the sampler's rate limit so it is actually
    // looked at. Bursts closer together than that are skipped, which would
    // make this test pass while proving nothing.
    Future<void> darkSample() async {
      fake.latest.emit(stream(darkFrame(), 2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    await feed(fake, litFrame(), 300);
    await darkSample();
    await darkSample();
    // Nothing at all for a while — a stalled stream, not a lost signal.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await darkSample();
    await darkSample();

    // A hold measured on the wall clock called this "black for over a second"
    // and raised the banner off a handful of frames. A streak counts evidence,
    // so a stall freezes it instead of running it up.
    expect(fake.controller.state, isNot(CaptureState.noSignal));
  });

  test('a black picture is reported as no signal once it persists', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    await feed(fake, darkFrame(), 4000);

    // Frames are arriving and decoding fine — the picture is simply black,
    // which is what an unplugged HDMI input looks like.
    expect(fake.controller.framesTotal, greaterThanOrEqualTo(1));
    expect(fake.controller.decodeErrors, 0);
    expect(fake.controller.state, CaptureState.noSignal);
  });

  test('a returning picture clears the banner without waiting', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    await feed(fake, darkFrame(), 4000);
    expect(fake.controller.state, CaptureState.noSignal);

    // No hold on the way back: the source returning is good news.
    await feed(fake, litFrame(), 400);
    expect(fake.controller.state, CaptureState.streaming);
  });

  test('ffmpeg dying while we want frames surfaces its own message', () async {
    final fake = FakeCapture(stderrText: '/dev/video0: Device or resource busy');
    addTearDown(fake.controller.dispose);
    await fake.controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    fake.latest.exitWith(1);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fake.controller.state, CaptureState.failed);
    expect(fake.controller.error, contains('Device or resource busy'));
  });

  test('stopping kills the child and drops the frame', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();
    fake.latest.emit(stream(litFrame(), 3));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fake.controller.frame, isNotNull);

    await fake.controller.stop();

    expect(fake.latest.killed, isTrue);
    expect(fake.controller.state, CaptureState.idle);
    expect(fake.controller.frame, isNull);
    expect(fake.controller.running, isFalse);
  });

  test('changing mode restarts the capture with the new geometry', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    await fake.controller.setMode(const CaptureMode(1920, 1080, 30));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fake.spawned.length, 2);
    expect(fake.spawned.first.killed, isTrue);
    expect(fake.commands.last, containsAllInOrder(['-video_size', '1920x1080']));
  });

  test('automatic discovery skips a non-capture video node', () async {
    final fake = FakeCapture(
      stderrText: '/dev/video0: Not a video capture device',
      retryDelay: const Duration(milliseconds: 30),
      devices: const [
        CaptureDevice('/dev/video0', 'UVC metadata'),
        CaptureDevice('/dev/video1', 'UVC capture'),
      ],
    );
    addTearDown(fake.controller.dispose);
    await fake.controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    fake.spawned.first.exitWith(1);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(fake.spawned, hasLength(2));
    expect(fake.controller.device?.path, '/dev/video1');
    expect(fake.commands.last, contains('/dev/video1'));
  });

  test('a node that failed once is reconsidered on the next attempt', () async {
    final fake = FakeCapture(
      stderrText: '/dev/video0: Not a video capture device',
      retryDelay: const Duration(milliseconds: 30),
      devices: const [
        CaptureDevice('/dev/video0', 'UVC capture'),
        CaptureDevice('/dev/video1', 'UVC metadata'),
      ],
    );
    addTearDown(fake.controller.dispose);
    await fake.controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // video0 is the real capture node but was busy this once, so the search
    // moves to video1; video1 is not a capture node either.
    fake.spawned[0].exitWith(1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(fake.controller.device?.path, '/dev/video1');
    fake.spawned[1].exitWith(1);

    // Walking forward only would leave it parked on video1 for good. The next
    // retry cycle has to come back round to video0.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.controller.device?.path, '/dev/video0');
  });

  test('planned restart cannot schedule a retry from the old ffmpeg', () async {
    final fake = FakeCapture(retryDelay: const Duration(milliseconds: 30));
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    await fake.controller.setMode(const CaptureMode(1920, 1080, 30));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // One original process + one deliberate replacement. The exit callback of
    // the killed process must not create a third process after retryDelay.
    expect(fake.spawned.length, 2);
    expect(fake.controller.state, CaptureState.starting);
  });

  test('spawn failures are retried while capture is still requested', () async {
    var attempts = 0;
    final spawned = <FakeProcess>[];
    final controller = CaptureController(
      devices: const [CaptureDevice('/dev/video0', 'test camera')],
      retryDelay: const Duration(milliseconds: 30),
      spawn:
          (
            String executable,
            List<String> arguments, {
            bool runInShell = false,
            ProcessStartMode mode = ProcessStartMode.normal,
          }) async {
            attempts++;
            if (attempts == 1) throw ProcessException(executable, arguments, 'boom');
            final p = FakeProcess();
            spawned.add(p);
            return p;
          },
    );
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.state, CaptureState.failed);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(attempts, 2);
    expect(spawned, hasLength(1));
    expect(controller.state, CaptureState.starting);
  });

  test('a decode completing after stop cannot resurrect the stream', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    // This starts asynchronous image decoding; stop immediately while work may
    // still be in flight. A stale decode used to publish its frame afterwards.
    fake.latest.emit(stream(litFrame(), 4));
    await fake.controller.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(fake.controller.state, CaptureState.idle);
    expect(fake.controller.running, isFalse);
    expect(fake.controller.frame, isNull);
  });

  test('garbage on the pipe is counted, not fatal', () async {
    final fake = FakeCapture();
    addTearDown(fake.controller.dispose);
    await fake.controller.start();

    // Two frame boundaries around bytes that are not a JPEG.
    fake.latest.emit([
      0xFF, 0xD8, 0xFF, 1, 2, 3, 4, 5,
      0xFF, 0xD8, 0xFF, 6, 7, 8, 9,
      0xFF, 0xD8, 0xFF,
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(fake.controller.decodeErrors, greaterThan(0));
    expect(fake.controller.framesTotal, 0);
    expect(fake.controller.state, isNot(CaptureState.failed));
  });
}
