import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

TradeWallet wallet(int i) => TradeWallet.import(
  'W$i',
  '0x${(i + 1).toRadixString(16).padLeft(64, '0')}',
);

void main() {
  late FakeBackend backend;
  late ExecutionLog log;
  late BatchTrader trader;
  Future<void> noSleep(Duration _) async {}

  setUp(() {
    backend = FakeBackend();
    log = ExecutionLog();
    trader = BatchTrader(
      backend.api(),
      log,
      sleep: noSleep,
    );
  });

  void fund(
    TradeWallet w, {
    String native = '1000000000000000000',
    int nonce = 5,
    String tokenBalance = '0',
    String allowance = '0',
  }) {
    backend.wallets[w.address.toLowerCase()] = {
      'native': native,
      'nonce': nonce,
      'tokenBalance': tokenBalance,
      'routerAllowance': allowance,
    };
  }

  String expectedTrade(TradeWallet w, int nonce, BigInt value, {BigInt? sold}) => w
      .sign(
        LegacyTx(
          nonce: nonce,
          gasPrice: gasPrice,
          gasLimit: 200000,
          to: checksumAddress(router),
          value: value,
          data: hexToBytes(uxuyCall(w.address, sold ?? value, sold == null)),
        ),
      )
      .raw;

  test('bundle buy signs every wallet locally and sends one bundle', () async {
    final ws = [wallet(1), wallet(2), wallet(3)];
    for (final w in ws) {
      fund(w);
    }
    final amt = parseUnits('0.01', 18);
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: ws,
        mode: SendMode.bundle,
        amount: AmountRule(ratio: false, min: amt, max: amt),
      ),
    );
    expect(backend.bundles, hasLength(1));
    expect(backend.bundles.single, [
      for (final w in ws) expectedTrade(w, 5, amt),
    ]);
    expect(
      backend.calls.where((c) => c == 'transactions/bsc'),
      isEmpty,
      reason: 'BSC never uses public single submission',
    );
    expect(out.confirmed, 3);
    expect(out.failed, 0);
  });

  test(
    'bundle is all-or-nothing when the planner refuses a wallet',
    () async {
      final ws = [wallet(1), wallet(2)];
      for (final w in ws) {
        fund(w);
      }
      backend.refuse.add(ws[1].address.toLowerCase());
      final out = await trader.run(
        TradePlan(
          token: token,
          buy: true,
          wallets: ws,
          mode: SendMode.bundle,
          amount: AmountRule(
            ratio: false,
            min: parseUnits('0.01', 18),
            max: parseUnits('0.01', 18),
          ),
        ),
      );
      expect(out.stopped, isTrue);
      expect(backend.bundles, isEmpty);
      expect(backend.submitted, isEmpty);
      expect(log.entries.any((e) => e.text.contains('流动性不足')), isTrue);
    },
  );

  test('interval sell confirms the approval-only bundle before quoting and sending the sell', () async {
    final w = wallet(1);
    // The allowance contract and the execution contract may differ.
    backend.activeSpender = pool;
    fund(w, tokenBalance: '1000', nonce: 7);
    await trader.prepareSellApprovals(token:token,wallets:[w],amounts:{w.address.toLowerCase():BigInt.from(500)});
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: false,
        wallets: [w],
        mode: SendMode.interval,
        amount: AmountRule(
          ratio: true,
          min: BigInt.from(5000),
          max: BigInt.from(5000),
        ),
      ),
    );
    expect(out.confirmed, 1);
    expect(
      backend.bundles,
      hasLength(2),
      reason: 'approval and sell are independent private bundles',
    );
    expect(backend.submitted, hasLength(2));
    final approve = w.sign(
      LegacyTx(
        nonce: 7,
        gasPrice: gasPrice,
        gasLimit: 150000,
        to: checksumAddress(token),
        value: BigInt.zero,
        data: erc20Approve(pool, BigInt.from(500)),
      ),
    );
    expect(backend.submitted[0], approve.raw);
    expect(backend.submitted[1], expectedTrade(w, 8, BigInt.zero, sold: BigInt.from(500)));
    expect(backend.bundles, [[approve.raw], [expectedTrade(w, 8, BigInt.zero, sold: BigInt.from(500))]]);
    expect(backend.calls.indexOf('approvals/check'), lessThan(backend.calls.indexOf('bundles')));
  });

  test('a new main router gets fresh allowances and an aggregate quote before selling', () async {
    final wallets = [wallet(1), wallet(2)];
    for (final w in wallets) {
      fund(w, tokenBalance: '1000', allowance: '1000', nonce: 7);
    }
    final plan = TradePlan(
      token: token,
      buy: false,
      wallets: wallets,
      mode: SendMode.bundle,
      amount: AmountRule(ratio: false, min: BigInt.one, max: BigInt.one),
    );
    await trader.prepare(plan);
    const updated = '0x0000000000000000000000000000000000000002';
    backend.activeRouter = updated;
    for (final w in wallets) {
      backend.wallets[w.address.toLowerCase()]!['routerAllowance'] = '0';
    }
    final stale=await trader.run(plan);
    expect(stale.stopped,isTrue);
    expect(backend.bundles,isEmpty);
    await trader.prepareSellApprovals(token:token,wallets:wallets,amounts:stale.remaining);
    expect((await trader.run(plan)).confirmed, 2);
    expect(backend.bundles.map((batch) => batch.length), [2, 2]);
    for (final raw in backend.bundles.first) {
      final tx = backend.signatures[raw]!.$3;
      expect(tx.to!.toLowerCase(), token.toLowerCase());
      expect(tx.data, erc20Approve(updated, BigInt.one));
    }
    for (final raw in backend.bundles.last) {
      expect(backend.signatures[raw]!.$3.to!.toLowerCase(), updated);
    }
    expect(backend.calls.where((c) => c == 'approvals/check'), hasLength(1));
    expect(backend.routeAmounts.where((a) => a == '2'), hasLength(2));
  });

  test('interval sell skips approval when allowance is enough', () async {
    final w = wallet(1);
    fund(w, tokenBalance: '1000', allowance: '1000', nonce: 2);
    await trader.run(
      TradePlan(
        token: token,
        buy: false,
        wallets: [w],
        mode: SendMode.interval,
        amount: AmountRule(
          ratio: true,
          min: BigInt.from(10000),
          max: BigInt.from(10000),
        ),
      ),
    );
    expect(backend.submitted, [expectedTrade(w, 2, BigInt.zero, sold: BigInt.from(1000))]);
  });

  test(
    'interval run stops at the first wallet refused for liquidity',
    () async {
      final ws = [wallet(1), wallet(2), wallet(3)];
      for (final w in ws) {
        fund(w);
      }
      backend.refuse.add(ws[1].address.toLowerCase());
      final out = await trader.run(
        TradePlan(
          token: token,
          buy: true,
          wallets: ws,
          mode: SendMode.interval,
          amount: AmountRule(
            ratio: false,
            min: parseUnits('0.01', 18),
            max: parseUnits('0.01', 18),
          ),
        ),
      );
      expect(out.confirmed, 1);
      expect(out.stopped, isTrue);
      expect(backend.submitted, hasLength(1));
    },
  );

  test('liquidity refusal keeps the unsent wallets; resume trades only them, with the same amounts', () async {
    final ws = [wallet(1), wallet(2), wallet(3)];
    for (final w in ws) {
      fund(w);
    }
    backend.refuse.add(ws[1].address.toLowerCase());
    final amt = parseUnits('0.01', 18);
    final plan = TradePlan(
      token: token,
      buy: true,
      wallets: ws,
      mode: SendMode.interval,
      amount: AmountRule(ratio: false, min: amt, max: amt),
    );
    final out = await trader.run(plan);
    expect(out.remaining.keys, [
      ws[1].address.toLowerCase(),
      ws[2].address.toLowerCase(),
    ]);
    backend.refuse.clear();
    backend.submitted.clear();
    final resumed = await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: ws,
        mode: SendMode.interval,
        amount: AmountRule(ratio: false, min: BigInt.one, max: BigInt.one),
        resume: out.remaining,
      ),
    );
    expect(resumed.confirmed, 2);
    expect(backend.submitted, [
      expectedTrade(ws[1], 5, amt),
      expectedTrade(ws[2], 5, amt),
    ], reason: 'first wallet not traded again');
  });

  test(
    'unknown status blocks new sends until the original transaction is queried',
    () async {
      final w = wallet(1);
      fund(w);
      backend.receipt = 'pending';
      final amt = parseUnits('0.01', 18);
      final plan = TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.interval,
        loop: true,
        amount: AmountRule(ratio: false, min: amt, max: amt),
      );
      final out = await trader.run(plan);
      expect(out.stopped, isTrue);
      expect(trader.unresolved, hasLength(1));
      expect(
        backend.submitted,
        hasLength(1),
        reason: 'loop stops at the unknown transaction',
      );
      await expectLater(trader.run(plan), throwsStateError);
      expect(backend.submitted, hasLength(1));
      backend.receipt = 'confirmed';
      expect(await trader.query(), 1);
      expect(trader.unresolved, isEmpty);
      expect(backend.submitted, hasLength(1), reason: 'query never resends');
    },
  );

  test("the user's price-impact limit travels with every route request (default 20%)", () async {
    final w = wallet(1);
    fund(w);
    final amt = parseUnits('0.01', 18);
    await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.bundle,
        amount: AmountRule(ratio: false, min: amt, max: amt),
      ),
    );
    expect(backend.routeBodies.last['maxImpactPercent'], 20);
    await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.interval,
        maxImpactPercent: 3.5,
        amount: AmountRule(ratio: false, min: amt, max: amt),
      ),
    );
    expect(backend.routeBodies.last['maxImpactPercent'], 3.5);
  });

  test('reverted receipt is a failure, never a success', () async {
    final w = wallet(1);
    fund(w);
    backend.receipt = 'reverted';
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.interval,
        amount: AmountRule(
          ratio: false,
          min: parseUnits('0.01', 18),
          max: parseUnits('0.01', 18),
        ),
      ),
    );
    expect(out.confirmed, 0);
    expect(out.failed, 1);
  });

  test('wallet without enough BNB is skipped', () async {
    final w = wallet(1);
    fund(w, native: '1000');
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.bundle,
        amount: AmountRule(
          ratio: false,
          min: parseUnits('0.01', 18),
          max: parseUnits('0.01', 18),
        ),
      ),
    );
    expect(out.skipped, 1);
    expect(backend.bundles, isEmpty);
  });

  test('cancel stops before the next send', () async {
    final ws = [wallet(1), wallet(2)];
    for (final w in ws) {
      fund(w);
    }
    trader = BatchTrader(
      backend.api(),
      log,
      sleep: (_) async => trader.cancel(),
    );
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: ws,
        mode: SendMode.interval,
        intervalMin: 5,
        intervalMax: 5,
        amount: AmountRule(
          ratio: false,
          min: parseUnits('0.01', 18),
          max: parseUnits('0.01', 18),
        ),
      ),
    );
    expect(out.stopped, isTrue);
    expect(backend.submitted, hasLength(1));
  });

  test('a second run cannot start while one is running', () async {
    final w = wallet(1);
    fund(w);
    final first = trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.bundle,
        amount: AmountRule(
          ratio: false,
          min: BigInt.from(10),
          max: BigInt.from(10),
        ),
      ),
    );
    expect(
      () => trader.run(
        TradePlan(
          token: token,
          buy: true,
          wallets: [w],
          mode: SendMode.bundle,
          amount: AmountRule(
            ratio: false,
            min: BigInt.from(10),
            max: BigInt.from(10),
          ),
        ),
      ),
      throwsStateError,
    );
    await first;
  });

  test('ratio buy spends a share of BNB after the gas reserve', () async {
    final w = wallet(1);
    fund(w, native: '1000000000000000000'); // 1 BNB
    await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: [w],
        mode: SendMode.bundle,
        amount: AmountRule(
          ratio: true,
          min: BigInt.from(5000),
          max: BigInt.from(5000),
        ),
      ),
    );
    final reserve = gasPrice * BigInt.from(200000);
    final expected =
        (BigInt.parse('1000000000000000000') - reserve) *
        BigInt.from(5000) ~/
        BigInt.from(10000);
    expect(backend.bundles.single.single, expectedTrade(w, 5, expected));
  });

  test('sell amount is capped at the token balance', () async {
    final w = wallet(1);
    fund(w, tokenBalance: '700', allowance: '1000', nonce: 1);
    await trader.run(
      TradePlan(
        token: token,
        buy: false,
        wallets: [w],
        mode: SendMode.interval,
        amount: AmountRule(
          ratio: false,
          min: BigInt.from(900),
          max: BigInt.from(900),
        ),
      ),
    );
    final routeCall = backend.routeAmounts.single;
    expect(routeCall, '700');
  });

  test('random interval loop checks one live order at a time across rounds', () async {
    final ws = [wallet(1), wallet(2)];
    for (final w in ws) {
      fund(w);
    }
    final rule = AmountRule(ratio: false, min: BigInt.from(100), max: BigInt.from(200));
    TradePlan plan([Map<String, BigInt>? firstRound]) => TradePlan(
      wallets: ws, token: token, buy: true, mode: SendMode.interval, amount: rule,
      loop: true, randomOrder: true, resume: firstRound,
    );
    backend.onBundle = (raws) {
      final owner = backend.signatures[raws.single]!.$2;
      final st = backend.wallets[owner]!;
      st['tokenBalance'] = (BigInt.parse(st['tokenBalance'] as String) + BigInt.from(1000)).toString();
      if (backend.bundles.length == 3) trader.cancel();
    };
    final preview = await trader.prepare(plan());
    final result = await trader.run(plan(preview.amounts));
    expect(result.rounds, 2);
    expect(result.confirmed, 3, reason: log.entries.map((e) => e.text).join('\n'));
    final reads = backend.routeBodies;
    expect(reads.where((r) => r['forecastOnly'] == true), hasLength(2));
    expect(reads.where((r) => r['forecastOnly'] != true).take(2).map((r) => r['wallet'].toLowerCase()), preview.amounts.keys);
    expect(reads.where((r) => r['forecastOnly'] != true), hasLength(3));
  });

  test('loop repeats rounds until nothing is left to trade', () async {
    final w = wallet(1);
    fund(w, tokenBalance: '1000', allowance: '1000', nonce: 1);
    backend.afterSubmit = () =>
        backend.wallets[w.address.toLowerCase()]!['tokenBalance'] = '0';
    final out = await trader.run(
      TradePlan(
        token: token,
        buy: false,
        wallets: [w],
        mode: SendMode.interval,
        loop: true,
        amount: AmountRule(
          ratio: true,
          min: BigInt.from(10000),
          max: BigInt.from(10000),
        ),
      ),
    );
    expect(
      out.rounds,
      2,
      reason: 'second round finds no balance and ends the loop',
    );
    expect(out.confirmed, 1);
    expect(out.stopped, isFalse);
  });

  test('interval waits a random time inside the configured range', () async {
    final ws = [wallet(1), wallet(2), wallet(3)];
    for (final w in ws) {
      fund(w);
    }
    final waits = <Duration>[];
    trader = BatchTrader(
      backend.api(),
      log,
      sleep: (d) async => waits.add(d),
    );
    await trader.run(
      TradePlan(
        token: token,
        buy: true,
        wallets: ws,
        mode: SendMode.interval,
        intervalMin: 2,
        intervalMax: 4,
        amount: AmountRule(
          ratio: false,
          min: BigInt.from(10),
          max: BigInt.from(10),
        ),
      ),
    );
    final intervals = waits.where((d) => d.inSeconds >= 1).toList();
    expect(intervals, hasLength(4));
    for (var i = 0; i < intervals.length; i += 2) {
      expect(intervals[i + 1], const Duration(seconds: 1));
      expect((intervals[i] + intervals[i + 1]).inMilliseconds, inInclusiveRange(1900, 4000));
    }
  });

  group('wallets', () {
    test('import parses labels, skips duplicates and rejects bad keys', () {
      final text =
          'alice,0x${'1'.padLeft(64, '0')}\n0x${'2'.padLeft(64, '0')}\n0x${'1'.padLeft(64, '0')}\n';
      final ws = parsePrivateKeys(text, existing: {}, startIndex: 0);
      expect(ws.map((w) => w.label), ['alice', 'W2']);
      expect(ws.first.address, '0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf');
      expect(
        () => parsePrivateKeys('0x1234', existing: {}, startIndex: 0),
        throwsFormatException,
      );
      expect(
        () => parsePrivateKeys('0x${'0' * 64}', existing: {}, startIndex: 0),
        throwsFormatException,
      );
    });

    test('toString never contains the private key', () {
      final w = wallet(1);
      expect(w.toString().contains(w.exportPrivateKey().substring(2)), isFalse);
    });

    test('pasted rows keep both wallets and reject two keys on one line', () {
      final a = wallet(1), b = wallet(2);
      final one = a.exportPrivateKey(), two = b.exportPrivateKey();
      final imported = parsePrivateKeys(
        '${a.address},$one\r\n\r\n$two\n$one',
        existing: {}, startIndex: 0,
      );
      expect(imported.map((w) => w.address), [a.address, b.address]);
      for (final merged in ['$one $two', '$one,$two', '$one$two']) {
        expect(
          () => parsePrivateKeys('\n$merged', existing: {}, startIndex: 0),
          throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', '第 2 行：私钥格式无效，请一行输入一个私钥',
          )),
        );
      }
    });
  });
}
