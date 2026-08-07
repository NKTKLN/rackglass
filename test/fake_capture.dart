import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:promterm/src/capture/capture_controller.dart';

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
  FakeCapture({this.stderrText = ''});

  final String stderrText;
  final List<FakeProcess> spawned = [];
  final List<List<String>> commands = [];

  late final CaptureController controller = CaptureController(
    devices: const [CaptureDevice('/dev/video0', 'UVC Camera (345f:2109)')],
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
