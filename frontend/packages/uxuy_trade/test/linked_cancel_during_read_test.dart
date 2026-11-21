import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

class GatedFakeBackend extends FakeBackend {
  final pendingRead = Completer<void>();
  final allowRead = Completer<void>();

  @override
  http.Client client() {
    final original = super.client();
    return MockClient((request) async {
      if (request.url.path.endsWith('/wallets/state') &&
          !pendingRead.isCompleted) {
        pendingRead.complete();
        await allowRead.future;
      }
      if (request.method == 'GET')
        return original.get(request.url, headers: request.headers);
      return original.post(
        request.url,
        body: request.body,
        headers: request.headers,
      );
    });
  }
}

void main() {
  test('stop during the account read cancels funding before signing', () async {
    final backend = GatedFakeBackend();
    TradeWallet testWallet(int i) => TradeWallet.import(
      'sample',
      '0x${i.toRadixString(16).padLeft(64, '0')}',
    );
    final seller = testWallet(71),
        buyer = testWallet(72),
        relay = testWallet(73);
    final cash = BigInt.from(10).pow(18);
    final buyback = cash ~/ BigInt.from(10);
    for (final w in [seller, buyer, relay]) {
      backend.wallets[w.address.toLowerCase()] = {
        'native': w == seller ? '$cash' : '0',
        'nonce': 1,
        'tokenBalance': '0',
        'routerAllowance': '0',
      };
    }
    final linked = LinkedTrader(
      backend.api(),
      ExecutionLog(),
      sleep: (_) async {},
    );
    linked.progress = LinkedProgress()
      ..phase = 'buy'
      ..started = true
      ..received = buyback
      ..roundReceived = buyback
      ..buyRemaining = buyback;
    final run = linked.run(
      LinkedPlan(
        token: token,
        market: null,
        sellers: [seller],
        buyers: [buyer],
        transits: [relay],
        sizing: LinkedSizing.percent(5000),
        loop: false,
      ),
    );
    await backend.pendingRead.future.timeout(const Duration(seconds: 3));
    expect(backend.signatures, isEmpty);
    expect(backend.bundles, isEmpty);
    linked.cancel();
    backend.allowRead.complete();
    final result = await run.timeout(const Duration(seconds: 5));
    expect(result.stopped, isTrue);
    expect(backend.bundles, isEmpty);
    expect(backend.signatures, isEmpty);
    linked.dispose();
  });

  for (final buy in [false, true]) {
    test(
      'stop before wallet read completes cancels a ${buy ? "buyback" : "sale"}',
      () async {
        final backend = GatedFakeBackend();
        TradeWallet testWallet(int n) => TradeWallet.import(
          'sample',
          '0x${n.toRadixString(16).padLeft(64, '0')}',
        );
        final seller = testWallet(90), buyer = testWallet(91);
        final cash = BigInt.from(10).pow(18);
        final budget = cash ~/ BigInt.from(10);
        for (final w in [seller, buyer]) {
          backend.wallets[w.address.toLowerCase()] = {
            'native': '$cash',
            'nonce': 1,
            'tokenBalance': w == seller ? '500' : '0',
            'routerAllowance': '1000',
          };
        }
        final owner = buy ? buyer : seller;
        backend.onBundle = (_) {
          backend.wallets[owner.address.toLowerCase()]!['native'] =
              '${cash + (buy ? -budget : budget)}';
          backend.wallets[owner.address.toLowerCase()]!['tokenBalance'] = buy
              ? '100'
              : '400';
        };
        final linked = LinkedTrader(
          backend.api(),
          ExecutionLog(),
          sleep: (_) async {},
        );
        linked.progress = LinkedProgress()
          ..phase = buy ? 'buy' : 'sell'
          ..started = true
          ..sellRemaining = buy ? BigInt.zero : BigInt.from(100)
          ..tranche = BigInt.from(100)
          ..roundReceived = buy ? budget : BigInt.zero
          ..buyRemaining = buy ? budget : BigInt.zero;
        final run = linked.run(
          LinkedPlan(
            token: token,
            market: null,
            sellers: [seller],
            buyers: [buyer],
            sizing: LinkedSizing.percent(5000),
            loop: false,
          ),
        );
        await backend.pendingRead.future.timeout(const Duration(seconds: 3));
        expect(backend.bundles, isEmpty);
        linked.cancel();
        backend.allowRead.complete();
        final out = await run.timeout(const Duration(seconds: 6));
        expect(out.stopped, isTrue);
        expect(backend.bundles, isEmpty);
        expect(backend.signatures, isEmpty);
        linked.dispose();
      },
    );
  }
}
