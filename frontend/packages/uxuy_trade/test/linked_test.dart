import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';
import 'support/inner_quote.dart';

TradeWallet entry(int n) =>
    TradeWallet.import('E$n', '0x${n.toRadixString(16).padLeft(64, '0')}');

/// Ported from apps/web/tests/wallet-tools.test.mjs (planTransitFunding cases).
void main() {
  test('funded buyers need no transit and insufficient sellers produce no partial payment plan', () {
    final buyers = [entry(20)], sellers = [entry(21)], transits = [entry(22)];
    List<BalanceRow> rows(BigInt buyerBnb) => [
      BalanceRow(buyers[0].address, buyerBnb, BigInt.one),
      BalanceRow(sellers[0].address, BigInt.zero, BigInt.one),
      BalanceRow(transits[0].address, BigInt.zero, BigInt.one),
    ];
    List<FundingTransfer> plan(BigInt buyerBnb) => planTransitFunding(
      amount: BigInt.from(100000),
      buyers: buyers,
      sellers: sellers,
      transits: transits,
      rows: rows(buyerBnb),
      gasPrice: BigInt.one,
      buyGas: BigInt.from(350000),
      sellerGas: BigInt.from(500000),
    );
    expect(
      () => plan(BigInt.zero),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('不足')),
      ),
    );
    expect(plan(BigInt.from(450000)), isEmpty);
  });

  test('two sellers top up one relay; the relay forwards the shortage plus buyer gas', () {
    final e18 = BigInt.from(10).pow(18);
    final amount = e18 ~/ BigInt.from(10);
    final gasPrice = BigInt.from(1000000000);
    final buyGas = BigInt.from(300000), sellerGas = BigInt.from(400000);
    final buyers = [entry(30)],
        sellers = [entry(31), entry(32)],
        transits = [entry(33)];
    final rows = [
      BalanceRow(buyers[0].address, BigInt.zero, BigInt.zero),
      BalanceRow(
        sellers[0].address,
        amount * BigInt.from(3) ~/ BigInt.from(5),
        e18,
      ),
      BalanceRow(
        sellers[1].address,
        amount * BigInt.from(3) ~/ BigInt.from(5),
        e18,
      ),
      BalanceRow(transits[0].address, BigInt.zero, BigInt.zero),
    ];
    final out = planTransitFunding(
      amount: amount,
      buyers: buyers,
      sellers: sellers,
      transits: transits,
      rows: rows,
      gasPrice: gasPrice,
      buyGas: buyGas,
      sellerGas: sellerGas,
    );
    expect(out, hasLength(3));
    expect(out[0].to, transits[0].address);
    expect(out[1].to, transits[0].address);
    expect(out[2].to, buyers[0].address);
    expect(out[2].from.address, transits[0].address);
    expect(
      out[2].value,
      amount + buyGas * gasPrice,
      reason: 'buyer receives the shortage plus its own trade gas',
    );
    final transferFee = BigInt.from(21000) * gasPrice;
    for (final t in out.take(2)) {
      final row = rows.firstWhere((r) => r.address == t.from.address);
      expect(
        row.bnb - t.value >= sellerGas * gasPrice + transferFee,
        isTrue,
        reason: 'sellers keep gas for their own sell and transfer',
      );
    }
  });

  test('relay count must match buyers', () {
    expect(
      () => planTransitFunding(
        amount: BigInt.one,
        buyers: [entry(1)],
        sellers: [entry(2)],
        transits: const [],
        rows: const [],
        gasPrice: BigInt.one,
        buyGas: BigInt.one,
        sellerGas: BigInt.one,
      ),
      throwsStateError,
    );
  });

  group('linked trader (sell, then buy back with the BNB received)', () {
    late FakeBackend backend;
    late ExecutionLog log;
    late LinkedTrader linked;
    final e18 = BigInt.from(10).pow(18);
    final tenth = e18 ~/ BigInt.from(10);
    final sellers = [entry(41), entry(42)], buyers = [entry(43)];
    Map<String, Object> row(BigInt native, BigInt token) => {
      'native': '$native',
      'nonce': 1,
      'tokenBalance': '$token',
      'routerAllowance': '${BigInt.two.pow(255)}',
    };
    void put(TradeWallet w, BigInt native, BigInt token) =>
        backend.wallets[w.address.toLowerCase()] = row(native, token);
    // This local market mutates only a transaction's signer and spends the actual signed amount.
    void market() {
      backend.onBundle = (raws) {
        for (final raw in raws) {
          final (_, owner, tx) = backend.signatures[raw]!;
          final balance = backend.wallets[owner]!;
          final nativeBalance = BigInt.parse('${balance['native']}');
          final tokenBalance = BigInt.parse('${balance['tokenBalance']}');
          if (tx.value > BigInt.zero) {
            balance['native'] = (nativeBalance - tx.value).toString();
            balance['tokenBalance'] = (tokenBalance + BigInt.from(5)).toString();
          } else {
            final amount = BigInt.parse(bytesToHex(tx.data.sublist(36, 68), prefix: false), radix: 16);
            balance['native'] = (nativeBalance + amount * tenth ~/ BigInt.from(500)).toString();
            balance['tokenBalance'] = (tokenBalance - amount).toString();
          }
        }
      };
    }

    LinkedPlan plan({bool loop = false, int bps = 5000}) => LinkedPlan(
      token: token,
      market: null,
      sellers: sellers,
      buyers: buyers,
      sizing: LinkedSizing.percent(bps),
      loop: loop,
    );

    setUp(() {
      backend = FakeBackend();
      log = ExecutionLog();
      linked = LinkedTrader(
        backend.api(),
        log,
        sleep: (_) async {},
      );
      for (final w in sellers) {
        put(w, e18, BigInt.from(1000));
      }
      put(buyers.single, e18, BigInt.zero);
      market();
    });

    test('linked sell and buy legs preserve both holder lists for later launch liquidation', () async {
      final app = AppState(backend.api(), MemoryKeyStore());
      addTearDown(app.dispose);
      final dev = entry(88);
      put(dev, e18, BigInt.zero);
      app.four..session = LaunchSession(platform:'four', token:token,symbol:'T',dev:dev,wallets:[dev])..state=LaunchState.launched;
      final group = app.addLinkedGroup();
      expect((await group.trader.run(plan(bps: 7500))).finished,isTrue);
      app.removeGroup(group);
      final prepared=await app.four.prepareLiquidation();
      expect(prepared.amounts,{
        sellers.last.address.toLowerCase(): BigInt.from(500),
        buyers.first.address.toLowerCase():BigInt.from(5),
      });
    });

    test('one round: tranche from start holdings, buy-back equals the BNB actually received', () async {
      final p = await linked.run(plan());
      expect(
        p.finished,
        isTrue,
        reason: log.entries.map((e) => e.text).join('\n'),
      );
      expect(p.tranche, BigInt.from(1000));
      expect(p.received, tenth * BigInt.two);
      expect(p.spent, tenth * BigInt.two);
      expect(p.buyRemaining, BigInt.zero);
      expect(backend.bundles, hasLength(2));
    });

    test('inner check includes a later-round seller and scopes buyback checks to funded buyers in order', () async {
      final venue = innerMarket('flap', collateral: wbnb);
      backend.innerQuote = (r) => innerQuote(venue, r);
      final secondBuyer = entry(44);
      put(secondBuyer, e18, BigInt.zero);
      final amount = BigInt.from(500);
      final plan = LinkedPlan(token: token, market: venue, sellers: sellers, buyers: [...buyers, secondBuyer],
          sizing: LinkedSizing(ratio: false, min: amount, max: amount), mode: SendMode.interval);
      final preview = await linked.prepare(plan);
      expect(preview.amounts.keys, [sellers.first.address.toLowerCase()]);
      backend.routeBodies.clear();
      expect(await linked.checkLinkedGrants(plan, preview, inspectOnly: true), isFalse);
      Set<String> owners(String side) => {for (final r in backend.routeBodies)
        if (r['forecastOnly'] == true && r['side'] == side) (r['wallet'] as String).toLowerCase()};
      expect(owners('sell'), {for (final s in sellers) s.address.toLowerCase()});
      expect(owners('buy'), {buyers.first.address.toLowerCase()});
      expect(backend.signatures, isEmpty);
    });

    for (final sellable in [true, false]) {
      test('Four lot distinguishes a small configured tranche from exhausted wallets ($sellable)', () async {
        final venue = innerMarket('four');
        final holding = sellable ? BigInt.from(1000000000) : BigInt.from(1000);
        for (final seller in sellers) put(seller, e18, holding);
        final result = await linked.run(LinkedPlan(token: token, market: venue, buyers: buyers, sellers: sellers,
            sizing: LinkedSizing(ratio: false, min: BigInt.from(500), max: BigInt.from(500))));
        expect(result.finished, !sellable);
        expect(result.stopped, sellable);
        expect(backend.signatures, isEmpty);
      });
    }

    for (final randomOrder in [false, true]) {
      for (final target in [500, 1000, 1200]) {
        test('linked order consumes each wallet before the next (amount: $target, random: $randomOrder)', () async {
          final buyWallets = [buyers.first, entry(44)];
          put(buyWallets.last, e18, BigInt.zero);
          final amount = BigInt.from(target);
          final plan = LinkedPlan(token: token, market: null, sellers: sellers, buyers: buyWallets,
              sizing: LinkedSizing(ratio: false, min: amount, max: amount), loop: false, randomOrder: randomOrder);
          final reader = LinkedTrader(backend.api(), ExecutionLog());
          final preview = await reader.prepare(plan);
          reader.dispose();
          final order = [for (final i in preview.order.sellers) sellers[i].address.toLowerCase()];
          if (!randomOrder) expect(order.first, sellers.first.address.toLowerCase());
          expect(preview.amounts, {
            order.first: BigInt.from(target > 1000 ? 1000 : target),
            if (target > 1000) order.last: BigInt.from(target - 1000),
          });
          linked.adoptPreview(plan, preview);
          final result = await linked.run(plan);
          expect(result.finished, isTrue, reason: linked.error);
          expect(backend.bundles.first.map((raw) => backend.signatures[raw]!.$2), order.take(preview.amounts.length));
          expect(backend.signatures[backend.bundles.last.single]!.$2, buyWallets[preview.order.buyers.first].address.toLowerCase());
        });
      }
    }

    test('bundled sell and buy-back each request one route for all participating wallets', () async {
      final buyWallets = [buyers.first, entry(44)];
      put(buyWallets.last, e18, BigInt.zero);
      put(sellers.last, e18, BigInt.from(3000));
      final linkedPlan = LinkedPlan(
        token: token,
        market: null,
        sellers: sellers,
        buyers: buyWallets,
        sizing: LinkedSizing.percent(5000),
        loop: false,
      );
      final preview = await linked.prepare(linkedPlan);
      expect(preview.tranche, BigInt.from(2000));
      final p = await linked.run(linkedPlan);
      expect(p.finished, isTrue, reason: log.entries.map((e) => e.text).join('\n'));
      expect(p.received, tenth * BigInt.from(4));
      expect(p.spent, p.received);
      expect(backend.bundleRouteRequests, hasLength(3));
      final sellAmounts = {
        sellers.first.address.toLowerCase(): '1000',
        sellers.last.address.toLowerCase(): '1000',
      };
      final buyAmounts = {
        buyWallets.first.address.toLowerCase(): (tenth * BigInt.from(4)).toString(),
      };
      for (var i = 0; i < backend.bundleRouteRequests.length; i++) {
        final rows = backend.bundleRouteRequests[i];
        final buy = i == 2;
        expect(rows, hasLength(buy ? 1 : 2));
        expect(rows.every((r) => r['token'] == token && r['side'] == (buy ? 'buy' : 'sell')), isTrue);
        expect(rows.every((r) => (r['forecastOnly'] == true) == (i == 0)), isTrue);
        expect({
          for (final r in rows) (r['wallet'] as String).toLowerCase(): r['amount'],
        }, buy ? buyAmounts : sellAmounts);
      }
      expect(backend.calls, isNot(contains('routes')));
      expect(backend.calls.where((path)=>path=='routes/batch'),hasLength(1),
          reason:'The buyback measures each buyer’s executable gas before splitting the real proceeds.');
      expect(backend.bundles, hasLength(2));
    });

    test(
      'stop keeps the round; continue buys back without selling again',
      () async {
        var sleeps = 0;
        linked = LinkedTrader(
          backend.api(),
          log,
          sleep: (_) async {
            if (++sleeps == 1) linked.cancel(); // the wait after the sell phase
          },
        );
        final first = await linked.run(withInterval(plan()));
        expect(first.stopped, isTrue);
        expect(linked.resumable, isTrue);
        expect(first.phase, 'sell');
        expect(first.sellRemaining, BigInt.zero);
        expect(first.buyRemaining, tenth * BigInt.two);
        expect(backend.bundles, hasLength(1));
        final second = await linked.run(plan());
        expect(
          second.finished,
          isTrue,
          reason: log.entries.map((e) => e.text).join('\n'),
        );
        expect(
          backend.bundles,
          hasLength(2),
          reason: 'only the buy-back was sent',
        );
        expect(second.spent, tenth * BigInt.two);
      },
    );

    test('end round drops the remaining buy-back', () async {
      var sleeps = 0;
      linked = LinkedTrader(
        backend.api(),
        log,
        sleep: (_) async {
          if (++sleeps == 1) linked.cancel();
        },
      );
      await linked.run(withInterval(plan()));
      linked.finish();
      expect(linked.progress, isNull);
      expect(log.entries.last.text, contains('未买回'));
    });

    test('unknown sell status: nothing new until queried; the query accounts the round once', () async {
      backend.receipt = 'pending';
      final first = await linked.run(plan());
      expect(first.stopped, isTrue);
      expect(linked.needsQuery, isTrue);
      await expectLater(linked.run(plan()), throwsStateError);
      expect(backend.bundles, hasLength(1));
      backend.receipt = 'confirmed';
      await linked.query(plan());
      expect(linked.needsQuery, isFalse);
      expect(linked.progress!.buyRemaining, tenth * BigInt.two);
      final done = await linked.run(plan());
      expect(done.finished, isTrue);
      expect(backend.bundles, hasLength(2));
    });

    test('auto loop runs rounds until the sellers are empty', () async {
      final p = await linked.run(plan(loop: true));
      expect(
        p.finished,
        isTrue,
        reason: log.entries.map((e) => e.text).join('\n'),
      );
      expect(
        p.round,
        3,
        reason: 'rounds 1 and 2 trade, round 3 finds no holdings',
      );
      expect(p.sold, BigInt.from(2000));
      expect(backend.bundles, hasLength(4));
    });

    test('tiny remainders are kept in the wallets', () {
      expect(isSmallRemainder(BigInt.one, BigInt.from(1000000)), isTrue);
      expect(isSmallRemainder(BigInt.two, BigInt.from(1000000)), isFalse);
      expect(
        isSmallRemainder(
          BigInt.from(10000000001),
          BigInt.parse('100000000000000000000'),
          buy: true,
        ),
        isFalse,
      );
    });

    test('a wallet cannot be on both sides', () async {
      await expectLater(
        linked.run(
          LinkedPlan(
            token: token,
            market: null,
            sellers: sellers,
            buyers: [sellers.first],
            sizing: LinkedSizing.percent(5000),
          ),
        ),
        throwsStateError,
      );
    });
  });
}

/// Same plan with a 1 s interval so the test can stop during the wait after the sell phase.
LinkedPlan withInterval(LinkedPlan p) => LinkedPlan(
  token: p.token,
  market: p.market,
  sellers: p.sellers,
  buyers: p.buyers,
  sizing: p.sizing,
  loop: p.loop,
  intervalMin: 1,
  intervalMax: 1,
);
