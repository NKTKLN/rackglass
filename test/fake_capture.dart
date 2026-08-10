import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rackglass/src/capture/capture_controller.dart';

/// A 16x16 mid-grey JPEG, and the same frame in near-black. Real files, so the
/// tests exercise the actual JPEG path rather than a stand-in: framing, Skia
/// decode, and the black-frame check that tells no signal from a live picture.
const _litJpeg =
    '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMgD/2wBDAAgoKC8oLzc3Nzc3'
    'N0E8QUNDQ0FBQUFDQ0NISEhVVVVISEhDQ0hIUFBVVVxfXFdXVVdfX2RkZHh4c3OMjJGsrM//'
    'xABLAAEBAAAAAAAAAAAAAAAAAAAABQEBAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAA'
    'AAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIABAAEAMBIgACEQADEQD/2gAMAwEAAhEDEQA/'
    'ALQAP//Z';

const _darkJpeg =
    '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMgD/2wBDAAgoKC8oLzc3Nzc3'
    'N0E8QUNDQ0FBQUFDQ0NISEhVVVVISEhDQ0hIUFBVVVxfXFdXVVdfX2RkZHh4c3OMjJGsrM//'
    'xABLAAEBAAAAAAAAAAAAAAAAAAAABwEBAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAA'
    'AAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIABAAEAMBIgACEQADEQD/2gAMAwEAAhEDEQA/'
    'AIEAD//Z';

Uint8List litFrame() => base64Decode(_litJpeg);

/// A console: black nearly everywhere with a small bright patch, which is what
/// this card is normally pointed at. Mean channel value 4.3, well under
/// [AppConfig.captureBlackLevel], while the bright patch peaks at 255.
const _consoleJpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYI'
    'DAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkF'
    'BQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU'
    'FBQUFBT/wAARCAAgACADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQF'
    'BgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEI'
    'I0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNk'
    'ZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLD'
    'xMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEB'
    'AQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJB'
    'UQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZH'
    'SElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaan'
    'qKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oA'
    'DAMBAAIRAxEAPwD81Phb8LfE/wAafHemeDfBumf2z4k1Lzfsll9oig8zy4nlf55WVBhI'
    '3PLDOMDkgUfFL4W+J/gt471Pwb4y0z+xvEmm+V9rsvtEU/l+ZEkqfPEzIcpIh4Y4zg8g'
    'ij4W/FLxP8FvHemeMvBup/2N4k03zfsl79nin8vzInif5JVZDlJHHKnGcjkA0fFL4peJ'
    '/jT471Pxl4y1P+2fEmpeV9rvfs8UHmeXEkSfJEqoMJGg4UZxk8kmgDlaKKKACiiigAoo'
    'ooA//9k=';

Uint8List consoleFrame() => base64Decode(_consoleJpeg);

Uint8List darkFrame() => base64Decode(_darkJpeg);

/// Stands in for the ffmpeg child process.
class FakeProcess implements Process {
  FakeProcess({this.stderrText = ''});

  final String stderrText;
  final _out = StreamController<List<int>>();
  final _exit = Completer<int>();

  bool killed = false;

  /// Pushes raw bytes as if ffmpeg had written them, chunked, so the frame
  /// reassembly is exercised across chunk boundaries the way it is in life.
  void emit(List<int> bytes, {int chunk = 64}) {
    for (var i = 0; i < bytes.length; i += chunk) {
      _out.add(
        bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
      );
    }
  }

  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => stderrText.isEmpty
      ? const Stream<List<int>>.empty()
      : Stream<List<int>>.value(utf8.encode(stderrText));

  @override
  IOSink get stdin => throw UnsupportedError('stdin');

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exitWith(0);
    return true;
  }
}

/// A controller wired to [FakeProcess] with a fixed device list.
class FakeCapture {
  FakeCapture({
    this.stderrText = '',
    this.retryDelay = const Duration(seconds: 2),
    this.devices = const [
      CaptureDevice('/dev/video0', 'UVC Camera (345f:2109)'),
    ],
    this.configuredDevice = '',
  });

  final String stderrText;
  final Duration retryDelay;
  final List<CaptureDevice> devices;
  final String configuredDevice;
  final List<FakeProcess> spawned = [];
  final List<List<String>> commands = [];

  late final CaptureController controller = CaptureController(
    devices: devices,
    retryDelay: retryDelay,
    // Empty means "scan and pick", which is what the discovery tests exercise.
    // A test that wants the configured-node behaviour states a path itself.
    configuredDevice: configuredDevice,
    spawn:
        (
          String executable,
          List<String> arguments, {
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          commands.add([executable, ...arguments]);
          final p = FakeProcess(stderrText: stderrText);
          spawned.add(p);
          return p;
        },
  );

  FakeProcess get latest => spawned.last;
}
