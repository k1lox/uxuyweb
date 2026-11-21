import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  final wallet = TradeWallet.import('fixture', '0x${'11'.padLeft(64, '0')}');
  final request = RouteRequestData(
    buy: true,
    token: token,
    wallet: wallet.address,
    amount: BigInt.from(100),
  );
  final valid = {
    'chainId': 56,
    'source': 'uxuy',
    'quoteScope': 'wallet',
    'wallet': wallet.address,
    'token': token,
    'amount': '100',
    'side': 'buy',
    'to': router,
    'spender': router,
    'data': uxuyCall(wallet.address, request.amount, true),
    'value': '100',
    'pools': [pool],
    'dexes': ['test'],
    'fee': '0',
    'quoteOut': '1200',
    'minOut': '1194',
    'deadline': 2000000000,
    'gasLimit': 260000,
    'slippagePpm': 5000,
    'simulation': 'uxuy',
    'executed': true,
    'adversePriceImpactPercent': 1.2,
  };
  test('only a complete BSC UXUY quote without project fees is accepted', () {
    expect(RoutePlan.fromJson(valid).minOut, BigInt.from(1194));
    for (final bad in [
      {...valid, 'source': 'okx'},
      {...valid, 'chainId': 1},
      {...valid, 'fee': '1'},
      {...valid, 'spender': 'invalid'},
      {...valid, 'quoteOut': '-7'},
      {...valid}..remove('executed'),
      {...valid}..remove('side'),
      {...valid}..remove('slippagePpm'),
    ]) {
      expect(
        () => RoutePlan.fromJson(bad),
        throwsA(isA<BackendException>()),
        reason: bad.toString(),
      );
    }
  });
  test('mismatched, expired or unverified swap data never reaches the private relay', () async {
    final fake = FakeBackend();
    fake.wallets[wallet.address.toLowerCase()] = {
      'native': '1000000000000000000',
      'tokenBalance': '0',
      'routerAllowance': '0',
      'nonce': 0,
    };
    Map<String, Object> tamper = {};
    final upstream = fake.client();
    final api = BackendClient(
      Uri.parse('http://fixture.test'),
      MockClient((req) async {
        if (req.url.path.endsWith('/routes')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'plan': {...valid, ...tamper},
            }),
            200,
          );
        }
        final copy = http.Request(req.method, req.url)
          ..headers.addAll(req.headers)
          ..bodyBytes = req.bodyBytes;
        return http.Response.fromStream(await upstream.send(copy));
      }),
    );
    final trader = BatchTrader(api, ExecutionLog());
    final plan = TradePlan(
      token: token,
      buy: true,
      wallets: [wallet],
      mode: SendMode.interval,
      amount: AmountRule(
        ratio: false,
        min: request.amount,
        max: request.amount,
      ),
    );
    for (final bad in <Map<String, Object>>[
      {'wallet': pool},
      {'to': pool},
      {'spender': token},
      {'token': pool},
      {'value': '99'},
      {'side': 'sell'},
      {'amount': '99'},
      {'minOut': '1100'},
      {'slippagePpm': 10000},
      {'deadline': 1},
      {'executed': false},
      {'simulation': 'approve_then_swap'},
      {'data': '0xa9059cbb'},
      {'quoteScope': 'bundle'},
      {'chainId': 1},
    ]) {
      tamper = bad;
      expect((await trader.run(plan)).stopped, isTrue, reason: bad.toString());
      expect(fake.bundles, isEmpty);
    }
  });

  for (final platform in ['four', 'flap', 'genius', 'external']) {
    test(
      '$platform external market uses the raw wallet-specific UXUY transaction',
      () async {
        final fake = FakeBackend();
        fake.wallets[wallet.address.toLowerCase()] = {
          'native': '1000000000000000000',
          'nonce': 0,
          'tokenBalance': '0',
          'routerAllowance': '0',
        };
        final trader = BatchTrader(fake.api(), ExecutionLog());
        final result = await trader.run(
          TradePlan(
            token: token,
            buy: true,
            wallets: [wallet],
            mode: SendMode.interval,
            amount: AmountRule(
              ratio: false,
              min: request.amount,
              max: request.amount,
            ),
            market: Market({'address':token,'platform': platform,'external':true}),
          ),
        );
        expect(result.confirmed, 1);
        expect(fake.calls.where((path) => path == 'routes'), hasLength(1));
        expect(fake.routeBodies.single['slippageBps'], 50);
        expect(fake.routeBodies.single.containsKey('innerPlatform'),isFalse);
      },
    );
  }
}
