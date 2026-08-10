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
/// Every asynchronous operation is tied to a capture generation. Restarting,
/// stopping, or changing the device invalidates that generation before the old
/// process is torn down, so late process exits, JPEG decodes and signal checks
/// cannot mutate the next session.
class CaptureController extends ChangeNotifier {
  CaptureController({
    this.spawn = Process.start,
    List<CaptureDevice>? devices,
    this.retryDelay = AppConfig.captureRetry,
  }) : _fixedDevices = devices;

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

  /// Injectable so retry behavior can be regression-tested without sleeping
  /// for the production two-second backoff.
  final Duration retryDelay;

  static const defaultMode = CaptureMode(
    AppConfig.captureWidth,
    AppConfig.captureHeight,
    AppConfig.captureFps,
  );

  CaptureState _state = CaptureState.idle;
  String? _error;
  ui.Image? _frame;
  CaptureMode _mode = defaultMode;
  CaptureDevice? _device;
  List<CaptureDevice> _devices = const [];
  bool _devicePinned = false;

  /// Nodes already rejected during the current attempt cycle.
  final Set<String> _nodesTried = {};

  Process? _proc;
  StreamSubscription<List<int>>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Timer? _statsTimer;
  Timer? _retryTimer;
  bool _wantRunning = false;
  bool _disposed = false;

  /// Monotonically increasing token for the currently valid capture session.
  int _generation = 0;

  /// Thumbnail the signal check averages the frame down to.
  static const _thumbW = 64;
  static const _thumbH = 36;

  Uint8List _buf = Uint8List(0);
  (int, Uint8List)? _queued;
  bool _decoding = false;
  bool _signalCheckInFlight = false;

  final List<DateTime> _frameTimes = [];
  int _framesTotal = 0;
  int _framesDropped = 0;
  int _decodeErrors = 0;
  int _bytesTotal = 0;
  final List<String> _stderrTail = [];
  DateTime? _startedAt;
  DateTime? _lastSignalCheck;

  /// Consecutive sampled frames that came back black. Reset by any picture.
  int _blackStreak = 0;

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
      _devicePinned = false;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_wantRunning || _disposed) return;
    _wantRunning = true;
    _retryTimer?.cancel();
    // Pressing START is an explicit fresh attempt: every node is fair game
    // again, whatever failed last time.
    _nodesTried.clear();
    await _restartSession();
  }

  Future<void> stop() async {
    if (_disposed) return;
    _wantRunning = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    // Invalidate every callback before killing the process. Process.exitCode can
    // complete synchronously from a fake process and on some real teardown paths.
    _generation++;
    await _teardownResources();
    _setState(CaptureState.idle);
  }

  Future<void> setMode(CaptureMode m) async {
    if (m == _mode) return;
    _mode = m;
    if (_wantRunning) {
      await _restartSession();
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> setDevice(CaptureDevice d) async {
    if (d.path == _device?.path) {
      _devicePinned = true;
      return;
    }
    _device = d;
    _devicePinned = true;
    if (_wantRunning) {
      await _restartSession();
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  bool _isActive(int generation) =>
      !_disposed && _wantRunning && generation == _generation;

  Future<void> _restartSession() async {
    if (_disposed || !_wantRunning) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    final generation = ++_generation;
    await _teardownResources();
    if (!_isActive(generation)) return;
    await discover();
    if (!_isActive(generation)) return;
    await _spawn(generation);
  }

  Future<void> _spawn(int generation) async {
    if (!_isActive(generation)) return;
    final dev = _device;
    if (dev == null) {
      _failFor(generation, 'no /dev/video* node found');
      _scheduleRetry(generation);
      return;
    }

    _setStateFor(generation, CaptureState.starting);
    _buf = Uint8List(0);
    _queued = null;
    _stderrTail.clear();
    _framesTotal = 0;
    _framesDropped = 0;
    _decodeErrors = 0;
    _bytesTotal = 0;
    _frameTimes.clear();
    _blackStreak = 0;
    _lastSignalCheck = null;
    _signalCheckInFlight = false;
    _startedAt = DateTime.now();

    final mode = _mode;
    final args = <String>[
      '-hide_banner',
      '-loglevel', 'error',
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-f', 'v4l2',
      '-input_format', 'mjpeg',
      '-video_size', '${mode.width}x${mode.height}',
      '-framerate', '${mode.fps}',
      '-i', dev.path,
      '-f', 'mjpeg',
      '-c:v', 'copy',
      '-',
    ];

    Process proc;
    try {
      proc = await spawn(AppConfig.ffmpeg, args);
    } catch (e) {
      if (!_isActive(generation)) return;
      _failFor(generation, 'cannot run ${AppConfig.ffmpeg}: $e');
      _scheduleRetry(generation);
      return;
    }

    if (!_isActive(generation)) {
      proc.kill(ProcessSignal.sigterm);
      return;
    }
    _proc = proc;

    _stdout = proc.stdout.listen(
      (chunk) => _onBytes(generation, chunk),
      onError: (Object e) {
        if (!_isActive(generation) || !identical(_proc, proc)) return;
        _failFor(generation, 'stdout: $e');
        _scheduleRetry(generation);
      },
    );
    _stderr = proc.stderr.listen((d) {
      if (!_isActive(generation) || !identical(_proc, proc)) return;
      final text = String.fromCharCodes(d).trim();
      if (text.isEmpty) return;
      _stderrTail.addAll(text.split('\n'));
      while (_stderrTail.length > 4) {
        _stderrTail.removeAt(0);
      }
    });

    unawaited(
      proc.exitCode.then((code) {
        if (!_isActive(generation) || !identical(_proc, proc)) return;
        final message = _stderrTail.isEmpty
            ? 'ffmpeg exited with code $code'
            : _stderrTail.last;
        final diagnostic = _stderrTail.isEmpty ? message : _stderrTail.join('\n');
        if (_tryNextVideoNode(generation, diagnostic)) return;
        _failFor(generation, message);
        _scheduleRetry(generation);
      }),
    );

    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isActive(generation)) return;
      _pruneFrameTimes();
      notifyListeners();
    });
    if (_isActive(generation)) notifyListeners();
  }

  void _scheduleRetry(int generation) {
    if (!_isActive(generation)) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      // A new cycle reconsiders every node, including ones that failed a
      // moment ago: whatever was holding the device may have let go by now.
      // The pointer goes back to the head of the list too, or the search would
      // resume from wherever the last cycle gave up and never return to the
      // node that is actually the capture one.
      _nodesTried.clear();
      if (!_devicePinned && _devices.isNotEmpty) _device = _devices.first;
      if (_isActive(generation)) unawaited(_restartSession());
    });
  }

  /// Some UVC devices expose a capture node and a metadata/control node next
  /// to each other. If the automatically selected node is explicitly rejected
  /// as non-capture by V4L2/ffmpeg, try another discovered node immediately.
  /// A device chosen by the user is never silently replaced.
  ///
  /// The search walks nodes not yet tried in this cycle rather than only ever
  /// moving forward. Walking forward alone strands the controller on the last
  /// node once the real capture node fails even briefly — say it was still
  /// held by the previous ffmpeg — and no amount of retrying ever goes back to
  /// it. [_nodesTried] is cleared whenever a fresh attempt cycle begins, so a
  /// node that failed once is reconsidered on the next retry.
  bool _tryNextVideoNode(int generation, String message) {
    if (!_isActive(generation) || _devicePinned || _devices.length < 2) {
      return false;
    }
    final lower = message.toLowerCase();
    final wrongNode =
        lower.contains('not a video capture') ||
        lower.contains('not a capture device') ||
        lower.contains('inappropriate ioctl') ||
        lower.contains('not a video4linux2 device');
    if (!wrongNode) return false;

    if (_device != null) _nodesTried.add(_device!.path);
    CaptureDevice? next;
    for (final d in _devices) {
      if (!_nodesTried.contains(d.path)) {
        next = d;
        break;
      }
    }
    if (next == null) return false;
    _device = next;
    unawaited(_restartSession());
    return true;
  }

  Future<void> _teardownResources() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    final proc = _proc;
    _proc = null;
    proc?.kill(ProcessSignal.sigterm);
    _buf = Uint8List(0);
    _queued = null;
    _blackStreak = 0;
    _lastSignalCheck = null;
    _signalCheckInFlight = false;
    _frame?.dispose();
    _frame = null;
    _frameTimes.clear();
    _startedAt = null;
  }

  void _onBytes(int generation, List<int> chunk) {
    if (!_isActive(generation)) return;
    _bytesTotal += chunk.length;
    final merged = Uint8List(_buf.length + chunk.length);
    merged.setAll(0, _buf);
    merged.setAll(_buf.length, chunk);
    _buf = merged;

    var start = _indexOfSoi(_buf, 0);
    if (start < 0) {
      if (_buf.length > AppConfig.captureBufferLimit) _buf = Uint8List(0);
      return;
    }
    while (true) {
      final next = _indexOfSoi(_buf, start + 3);
      if (next < 0) break;
      _submit(generation, Uint8List.sublistView(_buf, start, next));
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

  /// Newest frame wins. Queue entries retain the generation they came from so
  /// a decoder finishing after a restart cannot consume a new session's frame.
  void _submit(int generation, Uint8List jpeg) {
    if (!_isActive(generation)) return;
    if (_queued != null) _framesDropped++;
    _queued = (generation, jpeg);
    if (!_decoding) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (!_disposed) {
        final queued = _queued;
        if (queued == null) break;
        _queued = null;
        final generation = queued.$1;
        final data = queued.$2;
        if (!_isActive(generation)) continue;

        try {
          final codec = await ui.instantiateImageCodec(data);
          final decoded = await codec.getNextFrame();
          codec.dispose();
          if (!_isActive(generation)) {
            decoded.image.dispose();
            continue;
          }

          _frame?.dispose();
          _frame = decoded.image;
          _framesTotal++;
          _frameTimes.add(DateTime.now());
          _pruneFrameTimes();
          if (_state != CaptureState.noSignal) {
            _setStateFor(generation, CaptureState.streaming);
          } else {
            notifyListeners();
          }
          unawaited(_maybeCheckSignal(generation, decoded.image));
        } catch (_) {
          if (_isActive(generation)) _decodeErrors++;
        }
      }
    } finally {
      _decoding = false;
      if (_queued != null && !_disposed) unawaited(_drain());
    }
  }

  void _pruneFrameTimes() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 2));
    while (_frameTimes.isNotEmpty && _frameTimes.first.isBefore(cutoff)) {
      _frameTimes.removeAt(0);
    }
  }

  Future<void> _maybeCheckSignal(int generation, ui.Image img) async {
    if (!_isActive(generation) || _signalCheckInFlight) return;
    final now = DateTime.now();
    if (_lastSignalCheck != null &&
        now.difference(_lastSignalCheck!) < AppConfig.captureSignalCheck) {
      return;
    }
    _lastSignalCheck = now;
    _signalCheckInFlight = true;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      // Medium quality means mipmaps, which is what makes a 16x minification
      // an average rather than a handful of taps. With `low` the thumbnail was
      // effectively point-sampled: on a console it landed between the glyphs
      // and reported a picture several shades darker than the real one.
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, _thumbW.toDouble(), _thumbH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final small = await picture.toImage(_thumbW, _thumbH);
      picture.dispose();
      final bytes = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      small.dispose();
      if (bytes == null || !_isActive(generation)) return;

      var sum = 0;
      var peak = 0;
      final d = bytes.buffer.asUint8List();
      for (var i = 0; i < d.length; i += 4) {
        final lum = d[i] + d[i + 1] + d[i + 2];
        sum += lum;
        if (lum > peak) peak = lum;
      }
      final mean = sum / (d.length / 4 * 3);
      if (!_isActive(generation)) return;

      // A lost input is uniformly black: nothing in the frame is bright. A
      // console is also mostly black, but its text is not, so the brightest
      // patch separates the two where average brightness cannot — this app
      // points at terminals, where a dark average is the normal case.
      if (peak / 3 >= AppConfig.capturePeakLevel ||
          mean >= AppConfig.captureBlackLevel) {
        _blackStreak = 0;
        if (_state == CaptureState.noSignal) {
          _setStateFor(generation, CaptureState.streaming);
        }
        return;
      }
      _blackStreak++;
      if (_state != CaptureState.noSignal &&
          _blackStreak >= AppConfig.captureBlackStreak) {
        _setStateFor(generation, CaptureState.noSignal);
      }
    } catch (_) {
      // Sampling is diagnostics; never let it take the stream down.
    } finally {
      if (generation == _generation) _signalCheckInFlight = false;
    }
  }

  void _failFor(int generation, String message) {
    if (!_isActive(generation)) return;
    _error = message;
    _setStateFor(generation, CaptureState.failed);
  }

  void _setStateFor(int generation, CaptureState s) {
    if (!_isActive(generation)) return;
    _setState(s);
  }

  void _setState(CaptureState s) {
    _state = s;
    if (s != CaptureState.failed) _error = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wantRunning = false;
    _generation++;
    _retryTimer?.cancel();
    _statsTimer?.cancel();
    _stdout?.cancel();
    _stderr?.cancel();
    _proc?.kill(ProcessSignal.sigterm);
    _proc = null;
    _queued = null;
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }
}
