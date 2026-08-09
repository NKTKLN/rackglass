@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rackglass/src/config.dart';
import 'package:rackglass/src/prom/prom_client.dart';
import 'package:rackglass/src/prom/queries.dart';
import 'package:rackglass/src/state/metrics_store.dart';

/// Hits the real Prometheus and checks that every expression the UI issues
/// still parses and returns what the models expect. Not part of the default
/// suite — it needs the server reachable.
///
///   flutter test test/live_smoke_test.dart --dart-define=RACKGLASS_LIVE=1
void main() {
  const live = bool.fromEnvironment('RACKGLASS_LIVE');

  test('every instant query the UI issues returns usable data', () async {
    final client = PromClient();
    addTearDown(client.close);

    final optional = <InstantQuery>{
      InstantQuery.gpuTemp,
      InstantQuery.gpuUtil,
      InstantQuery.gpuFbUsed,
      InstantQuery.gpuFbFree,
      InstantQuery.gpuPower,
      InstantQuery.gpuSmClock,
      InstantQuery.gpuMemClock,
      InstantQuery.gpuMemTemp,
      InstantQuery.gpuAgeFresh,
    };

    for (final e in Q.instantPollQueries.entries) {
      final r = await client.instant(e.value);
      if (!optional.contains(e.key)) {
        expect(r, isNotEmpty, reason: '${e.key.name} returned nothing');
      }
      stdout.writeln('${e.key.name.padRight(14)} ${r.length} series');
    }
  }, skip: live ? false : 'set --dart-define=RACKGLASS_LIVE=1');

  test('historical GPU fallback expressions still parse', () async {
    final client = PromClient();
    addTearDown(client.close);

    for (final e in Q.gpuFallbackQueries.entries) {
      final r = await client.instant(e.value);
      final label = 'fallback.${e.key.name}'.padRight(22);
      stdout.writeln('$label ${r.length} series');
    }
  }, skip: live ? false : 'set --dart-define=RACKGLASS_LIVE=1');

  test('a full poll builds a coherent snapshot', () async {
    final store = MetricsStore();
    addTearDown(store.dispose);

    await store.refresh();
    expect(store.error, isNull, reason: 'poll failed: ${store.error}');

    final snap = store.snapshot!;
    expect(snap.nodes, isNotEmpty);
    expect(snap.host, isNotNull, reason: 'no ${AppConfig.hypervisor} target');
    expect(snap.host!.cores, greaterThan(0));
    expect(snap.host!.memTotal, greaterThan(0));
    expect(snap.cpuPackageTemp, isNotNull, reason: 'no labelled CPU sensor');

    stdout.writeln(
      'host ${snap.host!.instance}: '
      '${snap.host!.cores!.toStringAsFixed(0)} cores, '
      '${snap.cpuPackageTemp!.label} ${snap.cpuPackageTemp!.celsius}°C, '
      '${snap.vms.length} guests, poll ${snap.fetchMillis}ms',
    );
    for (final g in snap.gpus) {
      stdout.writeln(
        'gpu${g.gpu} ${g.model}: ${g.temp}°C '
        '${g.stale ? "STALE ${g.age}" : "live"}',
      );
    }
  }, skip: live ? false : 'set --dart-define=RACKGLASS_LIVE=1');

  test('every range query used by the graphs screen returns a matrix', () async {
    final store = MetricsStore();
    addTearDown(store.dispose);

    const window = Duration(hours: 1);
    final expressions = <String, String>{
      'cpu': Q.rangeCpu,
      'memory': Q.rangeMemPct,
      'cpuTemperature': Q.rangeTempCpu,
      'gpuTemperature': Q.rangeTempGpu,
      'gpuUtil': Q.rangeGpuUtil,
      'networkRx': Q.rangeNetRx,
    };
    final end = DateTime.now();
    for (final e in expressions.entries) {
      final series = await store.loadRange(e.value, window, end: end);
      expect(series, isNotEmpty, reason: '${e.key} returned nothing');
      expect(
        series.first.points.length,
        greaterThan(10),
        reason: '${e.key} returned too few points',
      );
      stdout.writeln(
        '${e.key.padRight(14)} ${series.length} series x '
        '${series.first.points.length} points '
        '@ step ${MetricsStore.stepFor(window).inSeconds}s',
      );
    }
  }, skip: live ? false : 'set --dart-define=RACKGLASS_LIVE=1');
}
