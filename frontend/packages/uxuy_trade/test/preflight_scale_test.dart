import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  test('aggregate preview uses one quote at 1, 30 and 100 wallets; a warm ledger avoids another balance request', () async {
    final wallets = List.generate(
      100,
      (i) => TradeWallet.import(
        'Test',
        (i + 1).toRadixString(16).padLeft(64, '0'),
      ),
    );
    for (final count in [1, 30, 100]) {
      final backend = FakeBackend();
      final api = backend.api();
      await api.config();
      final group = wallets.take(count).toList();
      for (final w in group) {
        backend.wallets[w.address.toLowerCase()] = {
          'native': '1000000000000000000',
          'nonce': 0,
          'tokenBalance': '0',
          'routerAllowance': '0',
        };
      }
      final trader = BatchTrader(api, ExecutionLog());
      final plan = TradePlan(
        token: token,
        buy: true,
        wallets: group,
        mode: SendMode.bundle,
        amount: AmountRule(
          ratio: false,
          min: BigInt.from(1000),
          max: BigInt.from(1000),
        ),
      );
      final elapsed = <int>[];
      for (var pass = 0; pass < 2; pass++) {
        final clock = Stopwatch()..start();
        final preview = await trader.prepare(plan);
        elapsed.add(clock.elapsedMilliseconds);
        expect(preview.amounts.length, count);
        expect(preview.inputTotal, BigInt.from(count * 1000));
      }
      debugPrint(
        'PREVIEW wallets=$count coldMs=${elapsed.first} warmMs=${elapsed.last} balanceRequests=${backend.calls.where((p) => p == "wallets/state").length} routeRequests=${backend.routeBodies.length}',
      );
      expect(backend.calls.where((c) => c == 'wallets/state'), hasLength(1));
      expect(backend.routeBodies, hasLength(2));
      expect(backend.bundles, isEmpty);
      trader.dispose();
    }
  });
}
