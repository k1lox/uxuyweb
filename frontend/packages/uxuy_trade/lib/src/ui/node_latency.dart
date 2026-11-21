import 'dart:async';

import 'package:flutter/material.dart';

import '../api/backend_client.dart';
import 'widgets.dart' show muted;

class NodeLatency extends StatefulWidget {
  const NodeLatency({super.key, required this.api});
  final BackendClient api;

  @override
  State<NodeLatency> createState() => _NodeLatencyState();
}

class _NodeLatencyState extends State<NodeLatency> {
  Timer? timer;
  String value = '—';

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    var next = '—';
    try {
      final sample = await widget.api.nodeLatency();
      if (sample.limited) {
        next = '限流';
      } else if (sample.ms != null) {
        next = '${sample.ms} ms';
      }
    } catch (_) {
      // A failed probe replaces the previous measurement.
    }
    if (!mounted) return;
    if (next != value) setState(() => value = next);
    timer = Timer(const Duration(seconds: 5), refresh);
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'BSC 节点查询区块高度的延迟',
    child: Text('RPC $value', style: muted),
  );
}
