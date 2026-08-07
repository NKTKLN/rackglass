@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:promterm/src/config.dart';
import 'package:promterm/src/prom/prom_client.dart';
import 'package:promterm/src/prom/queries.dart';
import 'package:promterm/src/state/metrics_store.dart';

/// Hits the real Prometheus and checks that every expression the UI issues
/// still parses and returns what the models expect. Not part of the default
/// suite — it needs the server reachable.
///
///   flutter test test/live_smoke_test.dart --dart-define=PROMTERM_LIVE=1
void main() {
  const live = bool.fromEnvironment('PROMTERM_LIVE');

  test('every instant query the UI issues returns usable data', () async {
    final client = PromClient();
    addTearDown(client.close);

    final expressions = <String, String>{
      'up': Q.up,
      'cpuBusy': Q.cpuBusy,
      'cores': Q.cores,
      'memTotal': Q.memTotal,
      'memAvailable': Q.memAvailable,
      'load1': Q.load1,
      'bootTime': Q.bootTime,
      'fsSize': Q.fsSize,
      'netRx': Q.netRx,
      'cpuTemp': Q.cpuTemp,
      'gpuTemp': Q.gpuTemp,
      'gpuAge': Q.gpuAge,
    };

    for (final e in expressions.entries) {
      final r = await client.instant(e.value);
      expect(r, isNotEmpty, reason: '${e.key} returned nothing');
      stdout.writeln('${e.key.padRight(14)} ${r.length} series');
    }
  }, skip: live ? false : 'set --dart-define=PROMTERM_LIVE=1');

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
  }, skip: live ? false : 'set --dart-define=PROMTERM_LIVE=1');

  test('range queries return matrices for the graphs screen', () async {
    final store = MetricsStore();
    addTearDown(store.dispose);

    const window = Duration(hours: 1);
    final cpu = await store.loadRange(Q.rangeCpu, window);
    expect(cpu, isNotEmpty);
    expect(cpu.first.points.length, greaterThan(10));
    stdout.writeln(
      'range cpu: ${cpu.length} series x ${cpu.first.points.length} points '
      '@ step ${MetricsStore.stepFor(window).inSeconds}s',
    );
  }, skip: live ? false : 'set --dart-define=PROMTERM_LIVE=1');
}
