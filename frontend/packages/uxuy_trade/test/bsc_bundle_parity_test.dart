import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  late FakeBackend backend;
  late BatchTrader trader;
  final wallets = [
    for (var i = 1; i <= 160; i++)
      TradeWallet.import('fixture $i', i.toRadixString(16).padLeft(64, '0')),
  ];
  setUp(() {
    backend = FakeBackend();
    trader = BatchTrader(backend.api(), ExecutionLog(), sleep: (_) async {});
    for (final wallet in wallets) {
      backend.wallets[wallet.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'tokenBalance': '1000',
        'routerAllowance': '1000',
        'nonce': 0,
      };
    }
  });
  tearDown(() => trader.dispose());
  TradePlan plan(int count, {bool sell = false, BundleTip? tip}) => TradePlan(
    token: token,
    buy: !sell,
    wallets: wallets.take(count).toList(),
    mode: SendMode.bundle,
    amount: AmountRule(
      ratio: false,
      min: BigInt.from(100),
      max: BigInt.from(100),
    ),
    tip: tip,
  );
  test('160 BSC sellers need exact checks of 100+60 before separate swaps in batches of 103+57', () async {
    for (final row in backend.wallets.values) {
      row['routerAllowance'] = '0';
    }
    final sell = plan(160, sell: true), preview = await trader.prepare(sell);
    expect(preview.amounts, hasLength(160));
    await trader.prepareSellApprovals(
      token: token,
      wallets: wallets,
      amounts: preview.amounts,
    );
    expect(backend.bundles.map((b) => b.length), [100, 60]);
    expect(
      backend.wallets.values.every((w) => w['routerAllowance'] == '100'),
      isTrue,
    );
    final outcome = await trader.run(sell);
    expect(
      outcome.confirmed,
      160,
      reason: trader.log.entries.take(4).map((e) => e.text).join('\n'),
    );
    expect(backend.bundles.map((b) => b.length), [100, 60, 103, 57]);
    expect(outcome.confirmedWallets, hasLength(160));
    expect(outcome.sent, hasLength(160));
    expect(outcome.tradeHashes.toSet(), hasLength(160));
  });
  test(
    'block gas limit includes the actual signed tip gas limit on every block',
    () async {
      backend.blockGasLimit = 550000;
      final outcome = await trader.run(
        plan(5, tip: BundleTip(wallets.first, BigInt.one)),
      );
      expect(
        outcome.confirmed,
        5,
        reason: trader.log.entries.map((e) => e.text).join('\n'),
      );
      expect(backend.bundles.map((b) => b.length), [3, 3, 2]);
      final nonces = backend.bundles.map(
        (b) => backend.signatures[b.last]!.$3.nonce,
      );
      expect(nonces, [1, 2, 3]);
    },
  );
  for (final problem in ['wrong block', 'reversed']) {
    test(
      'a $problem in a trade or tip stops later chunks and excludes submitted wallets from resume',
      () async {
        backend.blockGasLimit = 550000;
        backend.onBundle = (raws) {
          scheduleMicrotask(() {
            final tip =
                backend.chainReceipts[backend.signatures[raws.last]!.$1]!;
            if (problem == 'wrong block') {
              tip['blockHash'] = '0x${'ff' * 32}';
            } else {
              tip['transactionIndex'] = '0x0';
            }
          });
        };
        final out = await trader.run(
          plan(5, tip: BundleTip(wallets.first, BigInt.one)),
        );
        expect(out.stopped, isTrue);
        expect(out.confirmed, 2);
        expect(
          out.remaining.keys,
          wallets.skip(2).take(3).map((w) => w.address.toLowerCase()),
        );
        expect(backend.bundles, hasLength(1));
      },
    );
  }
  test('missing tip receipt placement holds the entire bundle until query verifies original hashes without resending', () async {
    String? block, hash;
    backend.onBundle = (raws) {
      scheduleMicrotask(() {
        hash = backend.signatures[raws.last]!.$1;
        block = backend.chainReceipts[hash]!.remove('blockHash') as String;
      });
    };
    final out = await trader.run(
      plan(2, tip: BundleTip(wallets.first, BigInt.one)),
    );
    expect(out.confirmed, 0);
    expect(trader.unresolved, hasLength(3));
    backend.chainReceipts[hash]!['blockHash'] = block!;
    await trader.query();
    expect(
      out.confirmed,
      2,
      reason: trader.log.entries.map((e) => e.text).join('\n'),
    );
    expect(trader.unresolved, isEmpty);
    expect(backend.bundles, hasLength(1));
  });
  test('confirmed sales distinguish expected and actual proceeds and can re-read missing receipts without signing', () async {
    Object? trace;
    backend.onBundle = (raws) {
      final row = backend.wallets[wallets.first.address.toLowerCase()]!;
      row['native'] = (BigInt.parse(row['native'] as String) + BigInt.from(750))
          .toString();
      row['tokenBalance'] = '900';
      scheduleMicrotask(
        () => trace = backend.traces.remove(backend.signatures[raws.first]!.$1),
      );
    };
    final out = await trader.run(plan(1, sell: true));
    expect(out.confirmed, 1);
    expect(out.confirmedQuote, BigInt.from(1000));
    expect(trader.hasPendingSaleTotals, isTrue);
    expect(out.unverifiedSettlement, contains(out.tradeHashes.single));
    backend.traces[out.tradeHashes.single] = (trace! as Map)
        .cast<String, Object?>();
    await trader.query();
    expect(out.nativeReceived, BigInt.from(750));
    expect(out.networkFees, BigInt.from(21000) * gasPrice);
    expect(trader.hasPendingSaleTotals, isFalse);
    expect(out.unverifiedSettlement, isEmpty);
    await trader.query();
    expect(out.nativeReceived, BigInt.from(750));
    expect(backend.bundles, hasLength(1));
  });
  test(
    'a reverted sale has zero proceeds and still records its paid network fee',
    () async {
      backend.receipt = 'reverted';
      final out = await trader.run(plan(1, sell: true));
      expect(out.failed, 1);
      expect(out.confirmed, 0);
      expect(out.confirmedQuote, BigInt.zero);
      expect(out.nativeReceived, BigInt.zero);
      expect(out.networkFees, BigInt.from(21000) * gasPrice);
      expect(out.swapStatuses.values, ['reverted']);
    },
  );
}
