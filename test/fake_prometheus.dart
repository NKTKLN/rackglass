import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in Prometheus built from real responses captured off the live server
/// (Proxmox host + 4 guests, a Tesla V100 whose dcgm-exporter is down).
///
/// [gpuUp] flips the GPU exporter between live and long-dead so both branches of
/// the GPU panel can be rendered in tests.
class FakePrometheus {
  FakePrometheus({this.gpuUp = false, this.failEverything = false});

  final bool gpuUp;
  final bool failEverything;

  int instantCalls = 0;
  int rangeCalls = 0;
  final List<String> queries = [];

  static const _nodes = <String, String>{
    'pve-host': 'hypervisor',
    'vm-node-1': 'nodes',
    'vm-ops-node': 'operations',
    'vm-vpn': 'vpn',
    'vm-amnezia-proxy': 'proxy',
  };

  static const _cpu = {
    'pve-host': 9.19,
    'vm-node-1': 10.60,
    'vm-ops-node': 0.67,
    'vm-vpn': 0.33,
    'vm-amnezia-proxy': 0.38,
  };
  static const _cores = {
    'pve-host': 12.0,
    'vm-node-1': 2.0,
    'vm-ops-node': 2.0,
    'vm-vpn': 1.0,
    'vm-amnezia-proxy': 1.0,
  };
  static const _memTotal = {
    'pve-host': 33572134912.0,
    'vm-node-1': 8257101824.0,
    'vm-ops-node': 2978578432.0,
    'vm-vpn': 937627648.0,
    'vm-amnezia-proxy': 937627648.0,
  };
  static const _memAvail = {
    'pve-host': 17745612800.0,
    'vm-node-1': 2990116864.0,
    'vm-ops-node': 2232578048.0,
    'vm-vpn': 517435392.0,
    'vm-amnezia-proxy': 509181952.0,
  };
  static const _fsSize = {
    'pve-host': 100861726720.0,
    'vm-node-1': 65445814272.0,
    'vm-ops-node': 65445814272.0,
    'vm-vpn': 9283444736.0,
    'vm-amnezia-proxy': 15523123200.0,
  };
  static const _fsAvail = {
    'pve-host': 63221596160.0,
    'vm-node-1': 51153305600.0,
    'vm-ops-node': 53294276608.0,
    'vm-vpn': 5926871040.0,
    'vm-amnezia-proxy': 12062707712.0,
  };

  http.Client client() => MockClient((req) async {
    if (failEverything) {
      return http.Response('connection refused', 503);
    }
    final q = req.url.queryParameters['query'] ?? '';
    queries.add(q);
    if (req.url.path.endsWith('query_range')) {
      rangeCalls++;
      return _json(_rangeFor(q));
    }
    instantCalls++;
    return _json({'resultType': 'vector', 'result': _instantFor(q)});
  });

  http.Response _json(Map<String, dynamic> data) => http.Response(
    jsonEncode({'status': 'success', 'data': data}),
    200,
    headers: {'content-type': 'application/json'},
  );

  double get _now => DateTime.now().millisecondsSinceEpoch / 1000;

  List<Map<String, dynamic>> _vector(
    Map<String, double> byInstance, {
    String name = 'x',
    Map<String, String> extra = const {},
  }) => [
    for (final e in byInstance.entries)
      {
        'metric': {
          '__name__': name,
          'instance': e.key,
          'job': 'node',
          'role': _nodes[e.key] ?? '-',
          ...extra,
        },
        'value': [_now, e.value.toString()],
      },
  ];

  List<Map<String, dynamic>> _gpuVector(String name, double? value) {
    if (value == null) return const [];
    return [
      {
        'metric': {
          '__name__': name,
          'instance': 'vm-gpu-worker-1',
          'job': 'dcgm',
          'role': 'gpu',
          'gpu': '0',
          'device': 'nvidia0',
          'modelName': 'Tesla V100-SXM2-16GB',
          'UUID': 'GPU-0f5424e3-7915-abf0-4445-c5206f1ed148',
        },
        'value': [_now, value.toString()],
      },
    ];
  }

  List<Map<String, dynamic>> _instantFor(String q) {
    if (q == 'up') {
      return [
        ..._vector({for (final k in _nodes.keys) k: 1}, name: 'up'),
        {
          'metric': {
            '__name__': 'up',
            'instance': 'vm-gpu-worker-1',
            'job': 'dcgm',
            'role': 'gpu',
          },
          'value': [_now, gpuUp ? '1' : '0'],
        },
        {
          'metric': {
            '__name__': 'up',
            'instance': 'localhost:9090',
            'job': 'prometheus',
          },
          'value': [_now, '1'],
        },
      ];
    }
    if (q.contains('node_hwmon_sensor_label')) {
      return [
        _temp('Tctl', 'temp1', 43.375),
        _temp('Tccd1', 'temp3', 46.5),
      ];
    }
    if (q.startsWith('100 - ')) return _vector(_cpu);
    if (q.contains('mode="iowait"')) {
      return _vector({for (final k in _nodes.keys) k: 0.12});
    }
    if (q.startsWith('count by')) return _vector(_cores);
    if (q == 'node_memory_MemTotal_bytes') return _vector(_memTotal);
    if (q == 'node_memory_MemAvailable_bytes') return _vector(_memAvail);
    if (q == 'node_memory_SwapTotal_bytes') {
      return _vector({for (final k in _nodes.keys) k: k == 'pve-host' ? 8589930496.0 : 0.0});
    }
    if (q == 'node_memory_SwapFree_bytes') {
      return _vector({for (final k in _nodes.keys) k: k == 'pve-host' ? 8589930496.0 : 0.0});
    }
    if (q == 'node_load1') return _vector({for (final k in _nodes.keys) k: 0.66});
    if (q == 'node_load5') return _vector({for (final k in _nodes.keys) k: 0.71});
    if (q == 'node_load15') return _vector({for (final k in _nodes.keys) k: 0.60});
    if (q == 'node_boot_time_seconds') {
      return _vector({for (final k in _nodes.keys) k: _now - 180000});
    }
    if (q.startsWith('node_filesystem_size')) return _vector(_fsSize);
    if (q.startsWith('node_filesystem_avail')) return _vector(_fsAvail);
    if (q.contains('receive_bytes')) {
      return _vector({for (final k in _nodes.keys) k: 5574.87});
    }
    if (q.contains('transmit_bytes')) {
      return _vector({for (final k in _nodes.keys) k: 1103.31});
    }

    // GPU. Values come back through last_over_time even while the target is
    // down, which is exactly the case the UI has to handle.
    if (q.contains('DCGM_FI_DEV_GPU_TEMP')) {
      if (q.startsWith('time()')) {
        return _gpuVector('gpu_age', gpuUp ? 12.0 : 166055.5);
      }
      return _gpuVector('DCGM_FI_DEV_GPU_TEMP', 40);
    }
    if (q.contains('DCGM_FI_DEV_GPU_UTIL')) {
      return _gpuVector('DCGM_FI_DEV_GPU_UTIL', gpuUp ? 73 : 0);
    }
    if (q.contains('DCGM_FI_DEV_MEMORY_TEMP')) {
      return _gpuVector('DCGM_FI_DEV_MEMORY_TEMP', 38);
    }
    if (q.contains('DCGM_FI_DEV_FB_USED')) {
      return _gpuVector('DCGM_FI_DEV_FB_USED', gpuUp ? 9216 : 0);
    }
    if (q.contains('DCGM_FI_DEV_FB_FREE')) {
      return _gpuVector('DCGM_FI_DEV_FB_FREE', gpuUp ? 7154 : 16370);
    }
    if (q.contains('DCGM_FI_DEV_POWER_USAGE')) {
      return _gpuVector('DCGM_FI_DEV_POWER_USAGE', gpuUp ? 212.4 : 24.9);
    }
    if (q.contains('DCGM_FI_DEV_SM_CLOCK')) {
      return _gpuVector('DCGM_FI_DEV_SM_CLOCK', gpuUp ? 1380 : 135);
    }
    if (q.contains('DCGM_FI_DEV_MEM_CLOCK')) {
      return _gpuVector('DCGM_FI_DEV_MEM_CLOCK', 877);
    }
    if (q.contains('DCGM_FI_DEV_MEM_COPY_UTIL')) {
      return _gpuVector('DCGM_FI_DEV_MEM_COPY_UTIL', gpuUp ? 41 : 0);
    }
    return const [];
  }

  Map<String, dynamic> _rangeFor(String q) {
    final end = _now;
    List<List<Object>> pts(double base) => [
      for (var i = 60; i >= 0; i--)
        [end - i * 60, (base + (i % 7) - 3).toStringAsFixed(2)],
    ];
    if (q.contains('DCGM')) {
      return {
        'resultType': 'matrix',
        'result': [
          {
            'metric': {
              'instance': 'vm-gpu-worker-1',
              'gpu': '0',
              'modelName': 'Tesla V100-SXM2-16GB',
            },
            'values': pts(65),
          },
        ],
      };
    }
    if (q.contains('node_hwmon')) {
      return {
        'resultType': 'matrix',
        'result': [
          {
            'metric': {'instance': 'pve-host', 'label': 'Tctl', 'sensor': 'temp1'},
            'values': pts(44),
          },
        ],
      };
    }
    return {
      'resultType': 'matrix',
      'result': [
        for (final e in _nodes.entries)
          {
            'metric': {'instance': e.key, 'role': e.value},
            'values': pts(_cpu[e.key]! + 10),
          },
      ],
    };
  }

  Map<String, dynamic> _temp(String label, String sensor, double c) => {
    'metric': {
      '__name__': 'node_hwmon_temp_celsius',
      'instance': 'pve-host',
      'job': 'node',
      'role': 'hypervisor',
      'chip': 'pci0000:00_0000:00:18_3',
      'sensor': sensor,
      'label': label,
    },
    'value': [_now, c.toString()],
  };
}
