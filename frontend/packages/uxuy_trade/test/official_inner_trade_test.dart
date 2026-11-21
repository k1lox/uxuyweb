import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/inner_route.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';
import 'support/inner_quote.dart';

void main() {
  final wallet = TradeWallet.import('Synthetic', '411'.padLeft(64, '0'));
  const config = ModuleConfig(
    router: router,
    approvalSpender: router,
    routeEnabled: true,
    maxImpact: 50,
  );

  for (final platform in ['four', 'flap', 'genius']) {
    for (final buy in [true, false]) {
      for (final collateral in [zeroAddress, wbnb]) {
        test(
          '$platform ${buy ? "buy" : "sell"} pays or receives BNB with $collateral collateral',
          () async {
            final market = innerMarket(platform, collateral: collateral);
            final node = FakeBackend()
              ..innerQuote = (r) => innerQuote(market, r);
            final amount = buy
                ? BigInt.from(500)
                : BigInt.from(5) * BigInt.from(10).pow(18);
            node.wallets[wallet.address.toLowerCase()] = {
              'native': '1000000000000000000',
              'nonce': 3,
              'tokenBalance': '$amount',
              'routerAllowance': '$amount',
            };
            final trader = BatchTrader(
              node.api(),
              ExecutionLog(),
              sleep: (_) async {},
            );
            final result = await trader.run(
              TradePlan(
                token: token,
                buy: buy,
                wallets: [wallet],
                market: market,
                mode: SendMode.interval,
                amount: AmountRule(ratio: false, min: amount, max: amount),
              ),
            );
            expect(
              result.confirmed,
              1,
              reason: trader.log.entries.map((x) => x.text).join('\n'),
            );
            expect(result.tradeHashes, hasLength(1));
            final signed = node.signatures.values.map((s) => s.$3).toList();
            final target = market.innerTarget!.toLowerCase(),
                wrap = wbnb.toLowerCase();
            final destinations = collateral == zeroAddress
                ? [target]
                : (buy ? [wrap, target] : [target, wrap]);
            expect(signed.map((s) => s.to!.toLowerCase()), destinations);
            expect(signed.map((s) => s.nonce), [
              for (var i = 0; i < destinations.length; i++) 3 + i,
            ]);
            expect(node.bundles.single.length, signed.length);
            expect(result.sent, hasLength(signed.length));
          },
        );
      }
    }
  }

  test('rejects changes to inner calldata, spender, asset, minimum or sequence before signing', () async {
    final market = innerMarket('genius', collateral: wbnb);
    for (final mutation in [
      'amount',
      'spender',
      'destination',
      'data',
      'recipient',
      'price',
      'order',
      'gas',
    ]) {
      final node = FakeBackend()
        ..innerQuote = (r) {
          final p = innerQuote(market, r);
          if (r['forecastOnly'] == true) return p;
          final legs = p['legs'] as List;
          switch (mutation) {
            case 'amount':
              legs[1]['amountIn'] = '501';
            case 'spender':
              (p['approvals'] as List).first['spender'] = router;
            case 'destination':
              legs[1]['to'] = router;
            case 'data':
              legs[1]['data'] = '0x1234';
            case 'recipient':
              legs[1]['recipient'] = pool;
            case 'price':
              legs[1]['minOut'] = '1';
            case 'order':
              p['legs'] = legs.reversed.toList();
            case 'gas':
              legs[0]['gasLimit'] = 30000;
          }
          return p;
        };
      node.wallets[wallet.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': 0,
        'tokenBalance': '0',
        'routerAllowance': '0',
      };
      final trader = BatchTrader(node.api(), ExecutionLog());
      final result = await trader.run(
        TradePlan(
          token: token,
          buy: true,
          wallets: [wallet],
          market: market,
          mode: SendMode.interval,
          amount: AmountRule(
            ratio: false,
            min: BigInt.from(500),
            max: BigInt.from(500),
          ),
        ),
      );
      expect(result.confirmed, 0, reason: mutation);
      expect(node.signatures, isEmpty, reason: mutation);
      expect(node.bundles, isEmpty, reason: mutation);
    }
  });

  for (final name in [
    'inner-wallet-route-flap.json',
    'inner-wallet-route-genius-bncb.json',
  ]) {
    test(
      'validates the execution ABI from $name',
      () {
        final sample = jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map;
        final q = sample['request'] as Map;
        final req = RouteRequestData(
          buy: q['side'] == 'buy',
          token: q['token'],
          amount: BigInt.parse(q['amount']),
          market: Market(Map<String, dynamic>.from(sample['market'])),
          wallet: q['wallet'],
          settlementToken: q['settlementToken'],
        );
        final plan = RoutePlan.fromJson(
          Map<String, dynamic>.from(sample['response']['plan']),
        );
        const ux = '0x7B458DBE4E7a693BE2e691DEdDff4607104f1266';
        validateInnerRoute(
          req,
          plan,
          ModuleConfig(
            router: ux,
            approvalSpender: ux,
            routeEnabled: true,
            maxImpact: config.maxImpact,
          ),
          forecast: false,
        );
      },
    );
  }
}
