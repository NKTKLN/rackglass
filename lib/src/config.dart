/// Static configuration, resolved at build time.
///
/// Every value here comes from a compile-time define, either passed directly
/// with `--dart-define=KEY=value` or collected from a file with
/// `--dart-define-from-file=config.env`. The file is the usual way: the
/// endpoint of somebody's cluster is not something to keep in source control,
/// and a define that has to be retyped on every build eventually gets it
/// wrong. See `config.env.example`.
class AppConfig {
  /// Base URL of the Prometheus server (no trailing slash).
  ///
  /// The default points at localhost deliberately: an unconfigured build
  /// should fail to connect in an obvious way rather than quietly querying
  /// whatever happens to answer at somebody else's address.
  static const promUrl = String.fromEnvironment(
    'PROM_URL',
    defaultValue: 'http://localhost:9090',
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

  /// Utilisation thresholds, shared by the bar colours and by the per-target
  /// health glyph on NODES. One definition, so a red bar and a red glyph
  /// always mean the same thing.
  static const loadWarn = 75.0;
  static const loadCritical = 90.0;

  /// Snapshot values older than this are visibly marked stale. A transient
  /// failed poll may keep the last good values on screen, but never indefinitely
  /// as if they were current.
  static const snapshotStaleAfter = Duration(seconds: 15);

  /// Range charts are refreshed while their screen is visible.
  static const rangeRefresh = Duration(minutes: 1);

  /// Historical DCGM fallback scans up to seven days of TSDB data. While an
  /// exporter is down, refresh that cache slowly instead of rerunning the
  /// expensive scans on every five-second node poll.
  static const gpuFallbackRefresh = Duration(minutes: 1);

  /// Virtual Linux interfaces are excluded from aggregate throughput so the
  /// same bridged packet is not counted on a physical NIC, bridge and tap/veth.
  /// Override for unusual network topologies at build time.
  static const netDeviceExclude = String.fromEnvironment(
    'NET_DEVICE_EXCLUDE',
    defaultValue: r'^(lo|veth.*|tap.*|fwbr.*|fwln.*|fwpr.*|vmbr.*|docker.*|br-.*|virbr.*)$',
  );

  /// The node_exporter instance that is the hypervisor itself; everything else
  /// discovered under job="node" is treated as a guest VM.
  static const hypervisor = 'pve-host';

  /// A GPU reading older than this is rendered as stale rather than current.
  static const gpuStaleAfter = Duration(minutes: 2);

  // ---- USB capture ---------------------------------------------------------

  /// Capture geometry, fixed. The card is flashed to offer 1024x600, which is
  /// the panel's own resolution: the source arrives at exactly the size the
  /// screen can show, so nothing is captured that would only be thrown away
  /// again on the way to the display. 720p cost a third more bandwidth and
  /// decode for pixels this panel has nowhere to put.
  /// Override at build time if the source ever changes.
  static const captureWidth = int.fromEnvironment('CAPTURE_W', defaultValue: 1024);
  static const captureHeight = int.fromEnvironment('CAPTURE_H', defaultValue: 600);
  static const captureFps = int.fromEnvironment('CAPTURE_FPS', defaultValue: 30);

  /// The V4L2 node to capture from, named outright rather than guessed.
  ///
  /// A UVC stick exposes a capture node and a metadata node side by side, and
  /// which index each gets is up to the order the kernel probed them — a
  /// reboot can swap them. On a panel with nobody in front of it, picking the
  /// node by hand is not an option, so the deployment states which one it is.
  /// Set this empty to fall back to scanning `/dev/video*` and stepping past
  /// nodes that turn out not to capture.
  static const captureDevice = String.fromEnvironment(
    'CAPTURE_DEVICE',
    defaultValue: '/dev/video0',
  );

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
  ///
  /// Thirty samples at [captureSignalCheck] is about three seconds of black.
  /// Slow on purpose: a source that really went away stays away, so nothing is
  /// lost by waiting, while a banner raised during a dark scene or a stutter is
  /// a lie you then have to un-see.
  static const captureBlackStreak = 30;

  /// Mean channel value below which a frame counts as no signal. The stick on
  /// this desk reports a luma average of 7 with nothing on its input.
  ///
  /// This alone is the wrong question for what the card is usually pointed at.
  /// Measured on the live input, a Linux console at a login prompt averages
  /// 20.6 — barely above the threshold — and any screen with fewer lines on it
  /// falls under, which is a lost signal reported for a picture that is there.
  static const captureBlackLevel = 12.0;

  /// Brightest patch, averaged into the signal-check thumbnail, above which
  /// there is definitely a picture. A lost input is uniformly black and peaks
  /// at 0; the same console peaks at 86. Sitting between the two, this decides
  /// the normal case, and [captureBlackLevel] only catches a picture that is
  /// dim everywhere without being black.
  static const capturePeakLevel = 24.0;
}
