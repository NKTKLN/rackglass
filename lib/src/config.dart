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
}
