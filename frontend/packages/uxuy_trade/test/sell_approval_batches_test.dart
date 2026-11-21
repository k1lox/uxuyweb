import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  late FakeBackend fake;
  late BatchTrader trader;
  late List<TradeWallet> wallets;
  setUp(() {
    fake = FakeBackend();
    trader = BatchTrader(fake.api(), ExecutionLog(), sleep: (_) async {});
    wallets = [];
  });
  void add(int count, {int allowance = 0}) {
    for (var i = 1; i <= count; i++) {
      final w = TradeWallet.import(
        'fixture-$i',
        i.toRadixString(16).padLeft(64, '0'),
      );
      wallets.add(w);
      fake.wallets[w.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': 0,
        'tokenBalance': '0',
        'routerAllowance': '$allowance',
      };
    }
  }

  Future<void> check({bool Function()? active}) => trader.prepareSellApprovals(
    token: token,
    wallets: wallets,
    amounts: {
      for (final w in wallets) w.address.toLowerCase(): BigInt.from(17),
    },
    active: active,
  );

  test('160 empty wallets with known future sell amounts authorize 100 + 60 and never sign swaps', () async {
    add(160);
    await check();
    expect(fake.bundles.map((b) => b.length), [100, 60]);
    for (final raw in fake.submitted) {
      expect(
        fake.signatures[raw]!.$3.data,
        erc20Approve(router, BigInt.from(17)),
      );
    }
    await check();
    expect(fake.bundles, hasLength(2));
  });
  test(
    'a reset and the new finite amount stay together under half-block gas',
    () async {
      add(3, allowance: 1);
      fake.blockGasLimit = 600000;
      await check();
      expect(fake.bundles.map((b) => b.length), [2, 2, 2]);
      for (final batch in fake.bundles) {
        expect(fake.signatures[batch[0]]!.$2, fake.signatures[batch[1]]!.$2);
        expect(
          fake.signatures[batch[0]]!.$3.data,
          erc20Approve(router, BigInt.zero),
        );
        expect(
          fake.signatures[batch[1]]!.$3.data,
          erc20Approve(router, BigInt.from(17)),
        );
      }
    },
  );
  test('a sale confirmation stops without signing when its prior allowance has been revoked', () async {
    add(1);
    await expectLater(
      trader.prepareSellApprovals(
        token: token,
        wallets: wallets,
        amounts: {wallets.single.address.toLowerCase(): BigInt.from(17)},
        allowSubmit: false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('重新检查授权'),
        ),
      ),
    );
    expect(fake.signatures, isEmpty);
    expect(fake.bundles, isEmpty);
  });
  test(
    'a confirmed approval without the on-chain allowance fails the check',
    () async {
      add(1);
      fake.applyApproval = false;
      await expectLater(check(), throwsStateError);
      expect(fake.bundles, hasLength(1));
    },
  );
  test('cancellation after one batch cannot submit the next batch', () async {
    add(3);
    fake.blockGasLimit = 300000;
    await expectLater(
      check(active: () => fake.bundles.isEmpty),
      throwsStateError,
    );
    expect(fake.bundles, hasLength(1));
  });
}
