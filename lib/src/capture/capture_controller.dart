import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../config.dart';

enum CaptureState {
  /// Not asked to run.
  idle,

  /// ffmpeg spawned, no frame decoded yet.
  starting,

  /// Frames arriving and decoding.
  streaming,

  /// Frames arriving, but the picture is flat black — a capture stick with
  /// nothing on its input streams happily and shows you nothing.
  noSignal,

  /// ffmpeg refused to run, the device is missing, or it is held by something
  /// else. [CaptureController.error] says which.
  failed,
}

/// One selectable capture mode.
class CaptureMode {
  const CaptureMode(this.width, this.height, this.fps);

  final int width;
  final int height;
  final int fps;

  String get label => '${width}x$height@$fps';

  @override
  bool operator ==(Object other) =>
      other is CaptureMode &&
      other.width == width &&
      other.height == height &&
      other.fps == fps;

  @override
  int get hashCode => Object.hash(width, height, fps);
}

/// A V4L2 node the app could capture from.
class CaptureDevice {
  const CaptureDevice(this.path, this.name);

  final String path;
  final String name;

  String get short => path.replaceFirst('/dev/', '');
}

/// Reads Motion-JPEG straight off a V4L2 capture device and hands the newest
/// decoded frame to the UI.
///
/// The device on this desk (MACROSILICON 345f:2109) exposes MJPG natively, so
/// ffmpeg runs as a stream copy: no decode, no scale, no re-encode in the
/// child process. Everything it emits is a JPEG that Skia decodes directly.
class CaptureController extends ChangeNotifier {
  CaptureController({this.spawn = Process.start, List<CaptureDevice>? devices})
    : _fixedDevices = devices;

  /// Injected in tests.
  final Future<Process> Function(
    String executable,
    List<String> arguments, {
    bool runInShell,
    ProcessStartMode mode,
  })
  spawn;

  /// When set, [discover] reports these instead of scanning `/dev`, so a test
  /// does not depend on what happens to be plugged into the build machine.
  final List<CaptureDevice>? _fixedDevices;

  static const modes = <CaptureMode>[
    CaptureMode(1280, 720, 30),
    CaptureMode(1920, 1080, 30),
    CaptureMode(1024, 768, 30),
    CaptureMode(720, 480, 30),
  ];

  CaptureState _state = CaptureState.idle;
  String? _error;
  ui.Image? _frame;
  CaptureMode _mode = modes.first;
  CaptureDevice? _device;
  List<CaptureDevice> _devices = const [];

  Process? _proc;
  StreamSubscription<List<int>>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Timer? _statsTimer;
  Timer? _retryTimer;
  bool _wantRunning = false;
  bool _disposed = false;

  Uint8List _buf = Uint8List(0);
  Uint8List? _queued;
  bool _decoding = false;

  final List<DateTime> _frameTimes = [];
  int _framesTotal = 0;
  int _framesDropped = 0;
  int _decodeErrors = 0;
  int _bytesTotal = 0;
  final List<String> _stderrTail = [];
  DateTime? _startedAt;
  DateTime? _lastSignalCheck;

  CaptureState get state => _state;
  String? get error => _error;
  ui.Image? get frame => _frame;
  CaptureMode get mode => _mode;
  CaptureDevice? get device => _device;
  List<CaptureDevice> get devices => _devices;
  int get framesTotal => _framesTotal;
  int get framesDropped => _framesDropped;
  int get decodeErrors => _decodeErrors;
  int get bytesTotal => _bytesTotal;
  bool get running => _wantRunning;

  /// Frames actually decoded per second, over a two second window.
  double get fps {
    if (_frameTimes.length < 2) return 0;
    final span = _frameTimes.last.difference(_frameTimes.first).inMilliseconds;
    if (span <= 0) return 0;
    return (_frameTimes.length - 1) * 1000 / span;
  }

  Duration? get uptime =>
      _startedAt == null ? null : DateTime.now().difference(_startedAt!);

  String get sourceLabel =>
      _device == null ? 'no device' : '${_device!.short} · ${_device!.name}';

  /// Scans `/dev/video*`, naming each through sysfs. Nodes that cannot capture
  /// (a UVC stick also exposes a metadata node) are filtered out by ffmpeg
  /// failing on them, not here — the kernel name alone does not say.
  Future<void> discover() async {
    if (_fixedDevices != null) {
      _devices = _fixedDevices;
      _device ??= _fixedDevices.isEmpty ? null : _fixedDevices.first;
      if (!_disposed) notifyListeners();
      return;
    }
    final found = <CaptureDevice>[];
    final dir = Directory('/dev');
    if (dir.existsSync()) {
      final nodes =
          dir
              .listSync()
              .map((e) => e.path)
              .where((p) => RegExp(r'^/dev/video\d+$').hasMatch(p))
              .toList()
            ..sort();
      for (final p in nodes) {
        final name = File(
          '/sys/class/video4linux/${p.split('/').last}/name',
        );
        found.add(
          CaptureDevice(
            p,
            name.existsSync() ? name.readAsStringSync().trim() : 'v4l2 device',
          ),
        );
      }
    }
    _devices = found;
    if (_device == null || !found.any((d) => d.path == _device!.path)) {
      _device = found.isEmpty ? null : found.first;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_wantRunning) return;
    _wantRunning = true;
    if (_devices.isEmpty) await discover();
    await _spawn();
  }

  Future<void> stop() async {
    _wantRunning = false;
    _retryTimer?.cancel();
    await _teardown();
    _setState(CaptureState.idle);
  }

  Future<void> setMode(CaptureMode m) async {
    if (m == _mode) return;
    _mode = m;
    if (_wantRunning) {
      await _teardown();
      await _spawn();
    } else {
      notifyListeners();
    }
  }

  Future<void> setDevice(CaptureDevice d) async {
    if (d.path == _device?.path) return;
    _device = d;
    if (_wantRunning) {
      await _teardown();
      await _spawn();
    } else {
      notifyListeners();
    }
  }

  Future<void> _spawn() async {
    final dev = _device;
    if (dev == null) {
      _fail('no /dev/video* node found');
      return;
    }
    _setState(CaptureState.starting);
    _buf = Uint8List(0);
    _stderrTail.clear();
    _framesTotal = 0;
    _framesDropped = 0;
    _decodeErrors = 0;
    _bytesTotal = 0;
    _frameTimes.clear();
    _startedAt = DateTime.now();

    final args = <String>[
      '-hide_banner',
      '-loglevel', 'error',
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-f', 'v4l2',
      '-input_format', 'mjpeg',
      '-video_size', '${_mode.width}x${_mode.height}',
      '-framerate', '${_mode.fps}',
      '-i', dev.path,
      '-f', 'mjpeg',
      // Stream copy: the device already emits JPEG, so nothing is re-encoded.
      '-c:v', 'copy',
      '-',
    ];

    try {
      _proc = await spawn(AppConfig.ffmpeg, args);
    } catch (e) {
      _fail('cannot run ${AppConfig.ffmpeg}: $e');
      return;
    }

    _stdout = _proc!.stdout.listen(
      _onBytes,
      onError: (Object e) => _fail('stdout: $e'),
    );
    _stderr = _proc!.stderr.listen((d) {
      final text = String.fromCharCodes(d).trim();
      if (text.isEmpty) return;
      _stderrTail.addAll(text.split('\n'));
      while (_stderrTail.length > 4) {
        _stderrTail.removeAt(0);
      }
    });

    unawaited(
      _proc!.exitCode.then((code) {
        if (_disposed || !_wantRunning) return;
        // ffmpeg exiting while we still want frames means the device went
        // away, is busy, or refused the mode. Surface its own words.
        _fail(
          _stderrTail.isEmpty
              ? 'ffmpeg exited with code $code'
              : _stderrTail.last,
        );
        _retryTimer?.cancel();
        _retryTimer = Timer(AppConfig.captureRetry, () {
          if (_wantRunning && !_disposed) _spawn();
        });
      }),
    );

    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _pruneFrameTimes();
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    _proc?.kill(ProcessSignal.sigterm);
    _proc = null;
    _buf = Uint8List(0);
    _queued = null;
    _frame?.dispose();
    _frame = null;
    _frameTimes.clear();
    _startedAt = null;
  }

  void _onBytes(List<int> chunk) {
    if (_disposed) return;
    _bytesTotal += chunk.length;
    final merged = Uint8List(_buf.length + chunk.length);
    merged.setAll(0, _buf);
    merged.setAll(_buf.length, chunk);
    _buf = merged;

    // Frames are concatenated JPEGs; the next SOI marker ends the current one.
    var start = _indexOfSoi(_buf, 0);
    if (start < 0) {
      // Nothing usable yet. Cap the buffer so a desynced stream cannot grow
      // without bound.
      if (_buf.length > AppConfig.captureBufferLimit) _buf = Uint8List(0);
      return;
    }
    while (true) {
      final next = _indexOfSoi(_buf, start + 3);
      if (next < 0) break;
      _submit(Uint8List.sublistView(_buf, start, next));
      start = next;
    }
    _buf = Uint8List.fromList(Uint8List.sublistView(_buf, start));
    if (_buf.length > AppConfig.captureBufferLimit) _buf = Uint8List(0);
  }

  static int _indexOfSoi(Uint8List data, int from) {
    for (var i = from; i + 2 < data.length; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF) {
        return i;
      }
    }
    return -1;
  }

  /// Newest frame wins. If decoding falls behind the device, the frames in
  /// between are dropped rather than queued — a growing queue would show
  /// progressively staler video.
  void _submit(Uint8List jpeg) {
    if (_queued != null) _framesDropped++;
    _queued = jpeg;
    if (!_decoding) unawaited(_drain());
  }

  Future<void> _drain() async {
    _decoding = true;
    while (_queued != null && !_disposed) {
      final data = _queued!;
      _queued = null;
      try {
        final codec = await ui.instantiateImageCodec(data);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (_disposed) {
          frame.image.dispose();
          break;
        }
        _frame?.dispose();
        _frame = frame.image;
        _framesTotal++;
        _frameTimes.add(DateTime.now());
        _pruneFrameTimes();
        if (_state != CaptureState.noSignal) {
          _setState(CaptureState.streaming);
        } else {
          notifyListeners();
        }
        unawaited(_maybeCheckSignal());
      } catch (_) {
        // A truncated or corrupt frame is normal at startup while syncing to
        // the stream; only a run of them means anything.
        _decodeErrors++;
      }
    }
    _decoding = false;
  }

  void _pruneFrameTimes() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 2));
    while (_frameTimes.isNotEmpty && _frameTimes.first.isBefore(cutoff)) {
      _frameTimes.removeAt(0);
    }
  }

  /// Downscales the current frame to a thumbnail and averages it. A capture
  /// stick with an unplugged input streams valid black frames forever, which
  /// is indistinguishable from a bug unless the app says so.
  Future<void> _maybeCheckSignal() async {
    final now = DateTime.now();
    // Signal coming back should be noticed quickly; signal being lost can take
    // its time, since a genuinely black scene should not flicker the badge.
    final interval = _state == CaptureState.noSignal
        ? AppConfig.captureSignalRecheck
        : AppConfig.captureSignalCheck;
    if (_lastSignalCheck != null &&
        now.difference(_lastSignalCheck!) < interval) {
      return;
    }
    _lastSignalCheck = now;
    final img = _frame;
    if (img == null) return;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        const ui.Rect.fromLTWH(0, 0, 32, 18),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      final picture = recorder.endRecording();
      final small = await picture.toImage(32, 18);
      picture.dispose();
      final bytes = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      small.dispose();
      if (bytes == null || _disposed) return;
      var sum = 0;
      final d = bytes.buffer.asUint8List();
      for (var i = 0; i < d.length; i += 4) {
        sum += d[i] + d[i + 1] + d[i + 2];
      }
      final mean = sum / (d.length / 4 * 3);
      final blank = mean < AppConfig.captureBlackLevel;
      final next = blank ? CaptureState.noSignal : CaptureState.streaming;
      if (_state != next && _state != CaptureState.idle) _setState(next);
    } catch (_) {
      // Sampling is diagnostics; never let it take the stream down.
    }
  }

  void _fail(String message) {
    _error = message;
    _setState(CaptureState.failed);
  }

  void _setState(CaptureState s) {
    _state = s;
    if (s != CaptureState.failed) _error = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantRunning = false;
    _retryTimer?.cancel();
    _statsTimer?.cancel();
    _stdout?.cancel();
    _stderr?.cancel();
    _proc?.kill(ProcessSignal.sigterm);
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }
}
