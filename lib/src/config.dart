/// Static configuration. Override at build time, e.g.
/// `flutter run --dart-define=PROM_URL=http://10.0.0.5:9090`.
class AppConfig {
  /// Base URL of the Prometheus server (no trailing slash).
  static const promUrl = String.fromEnvironment(
    'PROM_URL',
    defaultValue: 'http://192.168.1.13:9090',
  );

  /// The design canvas. Everything is laid out against these exact pixels and
  /// then scaled to whatever the real window is, so the 7" 1024x600 panel is
  /// pixel-perfect and larger screens just get a bigger copy of it.
  static const designWidth = 1024.0;
  static const designHeight = 600.0;

  /// How often the instant queries are re-issued.
  static const pollInterval = Duration(seconds: 5);

  /// HTTP timeout for a single query batch.
  static const requestTimeout = Duration(seconds: 6);

  /// Number of polled samples kept in memory for the inline sparklines.
  static const historyDepth = 120;

  /// The node_exporter instance that is the hypervisor itself; everything else
  /// discovered under job="node" is treated as a guest VM.
  static const hypervisor = 'pve-host';

  /// A GPU reading older than this is rendered as stale rather than current.
  static const gpuStaleAfter = Duration(minutes: 2);

  // ---- USB capture ---------------------------------------------------------

  /// Capture geometry, fixed. 1280x720 is the deliberate choice for this
  /// panel: 16:9 letterboxes into 1024x576, so 720 lands just above what the
  /// screen can show and downscales cleanly, while 1080p would cost three
  /// times the bandwidth and decode for detail the panel cannot display.
  /// Override at build time if the source ever changes.
  static const captureWidth = int.fromEnvironment('CAPTURE_W', defaultValue: 1280);
  static const captureHeight = int.fromEnvironment('CAPTURE_H', defaultValue: 720);
  static const captureFps = int.fromEnvironment('CAPTURE_FPS', defaultValue: 30);

  /// Binary used to pull frames off the V4L2 device.
  static const ffmpeg = String.fromEnvironment(
    'FFMPEG',
    defaultValue: 'ffmpeg',
  );

  /// How long to wait before respawning a capture that died.
  static const captureRetry = Duration(seconds: 2);

  /// Discard the JPEG reassembly buffer past this, so a desynced stream cannot
  /// grow without bound.
  static const captureBufferLimit = 8 << 20;

  /// How often the frame is sampled to tell a black picture from a live one.
  static const captureSignalCheck = Duration(milliseconds: 100);

  /// How many sampled frames in a row must be black before the app says the
  /// signal is gone.
  ///
  /// Counted in samples rather than elapsed time on purpose: a wall clock says
  /// "black for a second" even when only one frame was ever looked at and the
  /// stream then stalled, so a single dark or corrupt frame was enough to raise
  /// the banner. A streak only advances on evidence, so a stall freezes it
  /// instead of running it up.
  static const captureBlackStreak = 10;

  /// Mean channel value below which a frame counts as no signal. The stick on
  /// this desk reports a luma average of 7 with nothing on its input.
  static const captureBlackLevel = 12.0;
}
