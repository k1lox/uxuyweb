import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_business_sdk/uxuy_business_sdk.dart';
import 'package:uxuy_trade/src/api/scoped_client.dart';

class _Scope implements BusinessScope {
  final closed = Completer<void>();
  @override
  bool get isActive => !closed.isCompleted;
  @override
  Future<void> get revoked => closed.future;
  @override
  void ensureActive() {
    if (!isActive) {
      throw const BusinessException(BusinessErrorCode.scopeRevoked);
    }
  }
}

Matcher get _revoked => isA<BusinessException>().having(
  (e) => e.code,
  'code',
  BusinessErrorCode.scopeRevoked,
);

void main() {
  final url = Uri.parse('https://backend.test/api/v1/config');

  test(
    'an active scope passes the request and the full answer through',
    () async {
      final client = ScopedClient(
        _Scope(),
        MockClient((req) async => http.Response('{"ok":true}', 200)),
      );
      final r = await client.get(url);
      expect(r.statusCode, 200);
      expect(r.body, '{"ok":true}');
    },
  );

  test('nothing is sent once the scope is revoked', () async {
    var sent = 0;
    final scope = _Scope()..closed.complete();
    final client = ScopedClient(
      scope,
      MockClient((req) async {
        sent++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(client.get(url), throwsA(_revoked));
    expect(sent, 0);
  });

  test('an answer arriving after revocation is discarded', () async {
    final scope = _Scope();
    final answer = Completer<void>();
    final client = ScopedClient(
      scope,
      MockClient((req) async {
        await answer.future;
        return http.Response('{"ok":true}', 200);
      }),
    );
    final pending = client.get(url);
    scope.closed.complete(); // the user left the module while waiting
    answer.complete();
    await expectLater(pending, throwsA(_revoked));
  });
}
