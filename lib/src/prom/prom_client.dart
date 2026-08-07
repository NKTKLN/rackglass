import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// One instant-query result row.
class PromSample {
  const PromSample(this.labels, this.value, this.at);

  final Map<String, String> labels;
  final double value;
  final DateTime at;

  String? get instance => labels['instance'];
  String? get name => labels['__name__'];

  @override
  String toString() => '$labels = $value';
}

class PromPoint {
  const PromPoint(this.t, this.v);

  /// Unix seconds.
  final double t;
  final double v;
}

/// One range-query result row.
class PromSeries {
  const PromSeries(this.labels, this.points);

  final Map<String, String> labels;
  final List<PromPoint> points;

  String? get instance => labels['instance'];

  /// Best available human name for a legend entry.
  String get legend =>
      labels['label'] ?? labels['instance'] ?? labels['gpu'] ?? '?';
}

class PromException implements Exception {
  PromException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thin Prometheus HTTP API v1 client. Only the two endpoints the UI needs.
class PromClient {
  PromClient({String? baseUrl, http.Client? client})
    : baseUrl = (baseUrl ?? AppConfig.promUrl).replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  void close() => _client.close();

  Future<List<PromSample>> instant(String query, {DateTime? at}) async {
    final body = await _get('/api/v1/query', {
      'query': query,
      if (at != null) 'time': _unix(at),
    });
    final result = (body['data']?['result'] as List?) ?? const [];
    final out = <PromSample>[];
    for (final row in result) {
      final m = row as Map<String, dynamic>;
      final pair = m['value'] as List?;
      if (pair == null || pair.length < 2) continue;
      final v = _parseValue(pair[1]);
      if (v == null) continue;
      out.add(
        PromSample(
          _labels(m['metric']),
          v,
          DateTime.fromMillisecondsSinceEpoch(
            ((pair[0] as num).toDouble() * 1000).round(),
          ),
        ),
      );
    }
    return out;
  }

  Future<List<PromSeries>> range(
    String query, {
    required DateTime start,
    required DateTime end,
    required Duration step,
  }) async {
    final body = await _get('/api/v1/query_range', {
      'query': query,
      'start': _unix(start),
      'end': _unix(end),
      'step': '${step.inSeconds}s',
    });
    final result = (body['data']?['result'] as List?) ?? const [];
    final out = <PromSeries>[];
    for (final row in result) {
      final m = row as Map<String, dynamic>;
      final points = <PromPoint>[];
      for (final p in (m['values'] as List? ?? const [])) {
        final pair = p as List;
        final v = _parseValue(pair[1]);
        if (v == null) continue;
        points.add(PromPoint((pair[0] as num).toDouble(), v));
      }
      if (points.isNotEmpty) out.add(PromSeries(_labels(m['metric']), points));
    }
    return out;
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> q) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: q);
    final http.Response res;
    try {
      res = await _client.get(uri).timeout(AppConfig.requestTimeout);
    } catch (e) {
      throw PromException(_shortError(e));
    }
    if (res.statusCode != 200) {
      // Prometheus puts a useful message in the body even on 4xx.
      final msg = _errorFromBody(res.body) ?? 'HTTP ${res.statusCode}';
      throw PromException(msg);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['status'] != 'success') {
      throw PromException(
        (body['error'] as String?) ?? 'query status=${body['status']}',
      );
    }
    return body;
  }

  static String? _errorFromBody(String body) {
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      return m['error'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Exception text trimmed to something that fits a one-line status bar.
  static String _shortError(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException')) return 'timeout';
    if (s.contains('Connection refused')) return 'connection refused';
    if (s.contains('No route to host')) return 'no route to host';
    if (s.contains('Network is unreachable')) return 'network unreachable';
    if (s.contains('Failed host lookup')) return 'dns lookup failed';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  static Map<String, String> _labels(Object? metric) {
    if (metric is! Map) return const {};
    return metric.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// Prometheus encodes sample values as strings, including `NaN`/`+Inf`.
  static double? _parseValue(Object? raw) {
    final v = double.tryParse(raw.toString());
    if (v == null || v.isNaN || v.isInfinite) return null;
    return v;
  }

  static String _unix(DateTime t) =>
      (t.millisecondsSinceEpoch / 1000).toStringAsFixed(3);
}
