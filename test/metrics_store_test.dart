import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/prom/prom_client.dart';
import 'package:rackglass/src/prom/queries.dart';
import 'package:rackglass/src/state/metrics_store.dart';

import 'fake_prometheus.dart';

void main() {
  test(
    'failed polls append gaps instead of joining samples across an outage',
    () async {
      final prometheus = FakePrometheus();
      final store = MetricsStore(
        client: PromClient(
          baseUrl: 'http://fake:9090',
          client: prometheus.client(),
        ),
      );
      addTearDown(store.dispose);

      await store.refresh();
      expect(
        prometheus.instantCalls,
        Q.instantPollQueries.length + Q.gpuFallbackQueries.length,
      );
      expect(store.cpuHistory('pve-host').last, isNotNull);
      expect(store.gpuTempHistory.last, isNull); // dcgm is down in this fixture.

      // The expensive seven-day fallback must be cached while the same exporter
      // remains down; a normal five-second refresh only runs the live batch.
      final callsAfterFirstPoll = prometheus.instantCalls;
      await store.refresh();
      expect(
        prometheus.instantCalls - callsAfterFirstPoll,
        Q.instantPollQueries.length,
      );
      // A down exporter still has to produce readings, from history.
      expect(store.snapshot!.gpus, isNotEmpty);
      expect(store.snapshot!.gpus.first.stale, isTrue);

      prometheus.failEverything = true;
      await store.refresh();

      expect(store.error, isNotNull);
      expect(store.cpuHistory('pve-host').last, isNull);
      expect(store.memHistory('pve-host').last, isNull);
      expect(store.hostTempHistory.last, isNull);
    },
  );

  test('healthy dcgm polls never execute historical fallback scans', () async {
    final prometheus = FakePrometheus(gpuUp: true);
    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: prometheus.client(),
      ),
    );
    addTearDown(store.dispose);

    await store.refresh();

    expect(prometheus.instantCalls, Q.instantPollQueries.length);
    expect(store.snapshot!.gpus, isNotEmpty);
    expect(store.snapshot!.gpus.first.stale, isFalse);
  });

  test('unlabelled hwmon channels survive the label merge', () async {
    final prometheus = FakePrometheus();
    final store = MetricsStore(
      client: PromClient(
        baseUrl: 'http://fake:9090',
        client: prometheus.client(),
      ),
    );
    addTearDown(store.dispose);

    await store.refresh();

    final temps = store.snapshot!.temps;
    expect(temps.any((t) => t.sensor == 'temp7' && t.label == 'temp7'), isTrue);
    expect(store.snapshot!.cpuPackageTemp?.label, 'Tctl');
  });
}
