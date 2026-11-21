import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';

import 'support/fake_backend.dart';

void main() {
  test('independent wallet routes are planned in chunks so one request stays short behind a proxy', () async {
    final fake = FakeBackend();
    final api = BackendClient(Uri.parse('http://backend.test/'), fake.client());
    final wallets = [
      for (var i = 1; i <= 95; i++) '0x${i.toRadixString(16).padLeft(40, '0')}',
    ];
    fake.refuse.add(wallets[57]);
    final reqs = [
      for (var i = 0; i < wallets.length; i++)
        RouteRequestData(
          buy: true,
          token: token,
          amount: BigInt.from(1000 + i),
          wallet: wallets[i],
        ),
    ];
    final results = await api.routes(reqs);
    expect(
      fake.calls.where((c) => c == 'routes/batch').length,
      5,
      reason: 'four batches of 20 and one of 15',
    );
    expect(results.length, 95);
    expect(fake.routeAmounts, [
      for (var i = 0; i < 95; i++) '${1000 + i}',
    ], reason: 'request order is kept');
    for (var i = 0; i < 95; i++) {
      expect(
        results[i].error != null,
        i == 57,
        reason: 'the refusal stays on its own wallet ($i)',
      );
    }
  });

  test(
    'a 95-wallet bundle is sent intact and preserves its aggregate preview and all wallet quotes',
    () async {
      final fake = FakeBackend();
      final api = fake.api();
      final requests = [
        for (var i = 1; i <= 95; i++)
          RouteRequestData(
            buy: false,
            token: token,
            amount: BigInt.from(i),
            wallet: '0x${i.toRadixString(16).padLeft(40, '0')}',
          ),
      ];
      final result = await api.bundleRoute(requests);
      expect(fake.calls, ['routes/bundle']);
      expect(fake.routeAmounts, ['4560']);
      expect(result.group.amount, BigInt.from(4560));
      expect(
        result.wallets.map((p) => p.amount),
        requests.map((r) => r.amount),
      );
    },
  );

  test(
    'a backend without group planning cannot fall back to individual routes',
    () async {
      final paths = <String>[];
      final api = BackendClient(
        Uri.parse('http://backend.test/'),
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('not found', 404);
        }),
      );
      final request = RouteRequestData(
        buy: false,
        token: token,
        amount: BigInt.one,
        wallet: router,
      );
      await expectLater(
        api.bundleRoute([request]),
        throwsA(isA<BackendException>()),
      );
      expect(paths, ['/api/v1/routes/bundle']);
    },
  );

  test(
    'Four gate errors keep the cooldown seconds and say what still works',
    () async {
      // Error envelopes exactly as backend/crates/integrations/src/four_gate.rs returns them (HTTP 503).
      Map<String, Object?> gate(String code, String message, int? wait) => {
        'ok': false,
        'code': code,
        'message': message,
        'retryable': false,
        'notSubmitted': false,
        'data': wait == null
            ? null
            : {'retryAfterSeconds': wait, 'service': 'four'},
      };
      final replies = {
        'config': gate('FOUR_API_CHALLENGED', 'Four 官方接口限制本服务器访问，发币暂不可用', 300),
        'nonce': gate('FOUR_API_TIMEOUT', 'Four 官方接口响应超时，发币暂不可用', 30),
        'login': gate('FOUR_API_BUSY', 'Four 请求正在处理，请稍后手动重试', null),
      };
      final api = BackendClient(
        Uri.parse('http://backend.test/'),
        MockClient((req) async {
          expect(req.url.path, '/api/fourmeme');
          final action = (jsonDecode(req.body) as Map)['action'];
          return http.Response(
            jsonEncode(replies[action]),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      Future<BackendException> failure(String action) async {
        try {
          await api.four(action);
        } on BackendException catch (e) {
          return e;
        }
        fail('$action should fail');
      }

      final blocked = await failure('config');
      expect(blocked.code, 'FOUR_API_CHALLENGED');
      expect(blocked.retryable, isFalse);
      expect(blocked.retryAfterSeconds, 300);
      expect('$blocked', 'Four 官方接口限制本服务器访问，发币暂不可用。Four 代币买卖不受影响，只有发币需要官方接口');

      final slow = await failure('nonce');
      expect(slow.retryAfterSeconds, 30);
      expect('$slow', 'Four 官方接口响应超时，发币暂不可用，约 30 秒后可再试');

      final busy = await failure('login');
      expect(busy.retryAfterSeconds, isNull);
      expect('$busy', 'Four 请求正在处理，请稍后手动重试');
    },
  );
}
