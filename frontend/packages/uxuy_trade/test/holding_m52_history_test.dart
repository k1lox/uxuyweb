import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/holding_ratio.dart';

void main() {
  final rpc = Platform.environment['UXUY_HOLDING_ARCHIVE_RPC'];
  test(
    'GFACTORY m5.2 registration accounts for all supply at block 134696064',
    () async {
      const block = 134696064;
      const token = '0x970a662fb7edb8796ca4405edbabd8ae16186666';
      const curve = '0x49043b9ff8b5fd0ef119adfdb9896f4cab8f378c';
      final tag = '0x${block.toRadixString(16)}';
      final client = http.Client();
      addTearDown(client.close);
      final transport = MockClient((req) async {
        final calls = jsonDecode(req.body) as List;
        if (calls.every((q) => q['method'] == 'eth_blockNumber')) {
          return http.Response(
            jsonEncode([
              for (final q in calls)
                {'jsonrpc': '2.0', 'id': q['id'], 'result': tag},
            ]),
            200,
          );
        }
        for (final q in calls) {
          expect(q['method'], 'eth_call');
          expect(q['params'].last, tag);
        }
        return client.post(
          Uri.parse(rpc!),
          headers: {'content-type': 'application/json'},
          body: req.body,
        );
      });
      addTearDown(transport.close);
      final result = await readHoldingRatio(
        BackendClient(Uri.parse('http://fixture.local'), transport),
        token,
        '0x000000000000000000000000000000000000dead',
        '',
      );
      final pool = result.pools.singleWhere(
        (p) => p.address.toLowerCase() == curve,
      );
      expect(pool.label, 'Genius m5.2 内盘');
      expect(pool.balance, BigInt.parse('999525583469577397148844143'));
      expect(result.circulating, BigInt.zero);
      expect(result.percent, isNull);
    },
    skip: rpc == null
        ? 'Set UXUY_HOLDING_ARCHIVE_RPC to a BSC archive RPC.'
        : false,
  );
}
