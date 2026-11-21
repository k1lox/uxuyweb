import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/ui/node_latency.dart';

void main() {
  testWidgets(
    'BSC status replaces the last successful reading on rate limit or a failed read',
    (tester) async {
      final responses = [
        http.Response(
          jsonEncode({'ok': true, 'ms': 21, 'limited': false}),
          200,
        ),
        http.Response(
          jsonEncode({'ok': true, 'ms': null, 'limited': true}),
          200,
        ),
        http.Response('unavailable', 503),
      ];
      final requests = <String>[];
      final api = BackendClient(
        Uri.parse('http://synthetic.invalid/'),
        MockClient((req) async {
          requests.add(req.url.path);
          return responses.removeAt(0);
        }),
      );
      await tester.pumpWidget(MaterialApp(home: NodeLatency(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('RPC 21 ms'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('RPC 限流'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('RPC —'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      expect(requests, List.filled(3, '/api/v1/rpc-latency'));
      api.http_.close();
    },
  );
}
