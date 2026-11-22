import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

TradeWallet wallet(int i) => TradeWallet.import(
  'fixture $i',
  '0x${i.toRadixString(16).padLeft(64, '0')}',
);

class HeldBundles extends FakeBackend {
  final atLimit = Completer<void>();
  final release = Completer<void>();
  int inFlight = 0;
  @override
  http.Client client() {
    final base = super.client();
    return MockClient((req) async {
      if (req.url.path.endsWith('/bundles')) {
        inFlight++;
        if (inFlight == 64 && !atLimit.isCompleted) atLimit.complete();
        await release.future;
      }
      if (req.method == 'GET') return base.get(req.url, headers: req.headers);
      return base.post(req.url, headers: req.headers, body: req.body);
    });
  }
}

void main() {
  final w = wallet(1), other = wallet(2);
  late FakeBackend backend;
  late BatchTrader trader;
  late Map<String, Object> row;
  setUp(() {
    backend = FakeBackend();
    trader = BatchTrader(backend.api(), ExecutionLog(), sleep: (_) async {});
    row = {
      'native': '1000000000000000000',
      'tokenBalance': '1000',
      'nonce': 3,
      'routerAllowance': '1000000000',
    };
    for (final key in [w, other])
      backend.wallets[key.address.toLowerCase()] = Map.of(row);
    row = backend.wallets[w.address.toLowerCase()]!;
  });
  tearDown(() => trader.dispose());

  for (final mode in SendMode.values) {
    for (final drain in [0, 130]) {
      test(
        'ordinary $mode keeps starting 50% and sells the remaining tail ($drain)',
        () async {
          final sold = <int>[];
          backend.onBundle = (txs) {
            final order = mode == SendMode.interval
                ? backend.routeBodies.lastWhere(
                    (x) => x['forecastOnly'] != true,
                  )
                : backend.bundleRouteRequests.last.single;
            final amount = int.parse(order['amount'] as String);
            sold.add(amount);
            final live = int.parse(row['tokenBalance'] as String);
            row['tokenBalance'] =
                (live - amount - (sold.length == 1 ? drain : 0)).toString();
            row['nonce'] = (row['nonce'] as int) + 1;
            if (sold.length > 2) trader.cancel();
          };
          final out = await trader.run(
            TradePlan(
              token: token,
              buy: false,
              wallets: [w],
              mode: mode,
              loop: true,
              amount: AmountRule(
                ratio: true,
                min: BigInt.from(5000),
                max: BigInt.from(5000),
              ),
            ),
          );
          expect(sold, [500, 500 - drain]);
          expect(row['tokenBalance'], '0');
          expect(out.confirmed, 2);
        },
      );
    }
  }

  test('switching direction and sizing restores each independent range including partially edited input', () {
    final state = AppState(backend.api(), MemoryKeyStore());
    addTearDown(state.dispose);
    final g = state.addGroup()
      ..setBuy(false)
      ..min = '40'
      ..max = '55';
    g.setRatio(false);
    g.min = '3';
    g.max = '';
    g.setBuy(true);
    g.min = '0.3';
    g.max = '0.5';
    g.setRatio(true);
    g.min = '2';
    g.max = '4';
    g.setBuy(false);
    expect((g.ratio, g.min, g.max), (false, '3', ''));
    g.setRatio(true);
    expect((g.min, g.max), ('40', '55'));
    g.setBuy(true);
    expect((g.ratio, g.min, g.max), (true, '2', '4'));
    g.setRatio(false);
    expect((g.min, g.max), ('0.3', '0.5'));
  });

  test('unknown original hash counts only once after recovery and a reverted loop stops', () async {
    TradePlan order(bool loop) => TradePlan(
      token: token,
      buy: true,
      wallets: [w],
      mode: SendMode.interval,
      loop: loop,
      amount: AmountRule(ratio: false, min: BigInt.one, max: BigInt.one),
    );
    backend.receipt = 'pending';
    final out = await trader.run(order(false));
    expect(out.failed, 0);
    expect(trader.unresolved, hasLength(1));
    backend.receipt = 'confirmed';
    await trader.query();
    expect((out.confirmed, out.failed), (1, 0));
    backend.receipt = 'reverted';
    row['nonce'] = 10;
    await trader.api.refreshWalletStates([w.address], token: token);
    final failed = await trader.run(order(true));
    expect((failed.stopped, failed.failed), (true, 1));
    expect(backend.bundles, hasLength(2));
  });

  test('group intervals accept milliseconds and random amount ranges accept a zero lower bound', () {
    expect(parseGroupSeconds('0.001'), 0.001);
    expect(parseGroupSeconds('0.0001'), isNull);
    expect(parseGroupSeconds('86400.001'), isNull);
    final normal = TradeGroup(1, backend.api(), ExecutionLog())
      ..wallets = [w]
      ..setBuy(false);
    normal.selected.add(w.address);
    normal.min = '0';
    normal.max = '12';
    normal.intervalMin = '0.125';
    normal.intervalMax = '0.26';
    expect(normal.plan(token, 18).intervalMin, 0.125);
    final linked = LinkedGroup(2, backend.api(), ExecutionLog())
      ..sellers = [w]
      ..buyers = [other]
      ..min = '0'
      ..max = '2'
      ..intervalMin = '0.001'
      ..intervalMax = '0.002';
    linked.transitByBuyer[other.address.toLowerCase()] = wallet(3);
    expect(linked.plan(token, 18).intervalMax, 0.002);
    normal.dispose();
    linked.dispose();
  });

  RapidPlan plan({
    RapidDirection mode = RapidDirection.both,
    String count = '4',
    String percent = '50',
    bool percentSell = true,
    String interval = '0',
    String minNative = '0',
  }) => RapidPlan.parse(
    token: token,
    decimals: 0,
    wallets: [w, other],
    direction: mode,
    buyAmount: '0.001',
    percentSell: percentSell,
    sellAmount: '30',
    sellPercent: percent,
    interval: interval,
    total: count,
    minNative: minNative,
    minToken: '0',
    impactLimit: 20,
  );

  for (final (balance, reason) in [
    ('0', '没有可卖的代币'),
    ('1', '卖量低于最小交易单位'),
  ]) {
    test('rapid sell preflight reports the cause for balance $balance', () async {
      row['tokenBalance'] = balance;
      final sale = plan(mode: RapidDirection.sell, count: '1', percent: '50');
      await expectLater(
        trader.prepareRapid(sale, () => true),
        throwsA(isA<StateError>().having((e) => e.message, 'message', '${w.address} $reason')),
      );
      expect(backend.bundles, isEmpty);
    });
  }

  test('rapid checks latest versus pending nonce at preparation and start',() async {
    final p=plan(mode:RapidDirection.buy,count:'1');
    backend.minedNonces[w.address.toLowerCase()]=2;
    await expectLater(trader.prepareRapid(p,()=>true),throwsStateError);
    expect(backend.signatures,isEmpty);
    backend.minedNonces.clear();
    final checked=await trader.prepareRapid(p,()=>true);
    backend.minedNonces[w.address.toLowerCase()]=2;
    await expectLater(trader.runRapid(checked),throwsStateError);
    expect(backend.signatures,isEmpty);
  });

  test('revoked rapid allowance stops before selling and a recheck resumes only unsent positions',() async {
    row['routerAllowance']='1000000000000000000';
    final p=plan(mode:RapidDirection.both,count:'2',percentSell:true);
    final checked=await trader.prepareRapid(p,()=>true);
    backend.onBundle=(raws){
      row['routerAllowance']='0';
      row['nonce']=(row['nonce'] as int)+1;
    };
    final interrupted=await trader.runRapid(checked);
    expect(interrupted.stopped,isTrue);
    expect(backend.bundles,hasLength(1));
    await trader.queryRapid();
    row['routerAllowance']='1000';
    backend.onBundle=null;
    final next=await trader.prepareRapid(p,()=>true);
    expect(next.remainingCount,1);
    final result=await trader.runRapid(next);
    expect(result.tradeHashes,hasLength(1));
    expect(backend.routeBodies.last['side'],'sell');
    expect(backend.bundles,hasLength(2));
  });

  test('percentage loop reserves route gas for the rounded tail',() {
    expect(BatchTrader.buyBasis(BigInt.from(1000),BigInt.from(10),BigInt.from(5000),true),BigInt.from(980));
    expect(BatchTrader.buyBasis(BigInt.from(1001),BigInt.from(10),BigInt.from(5000),true),BigInt.from(971));
    expect(BatchTrader.buyBasis(BigInt.from(15),BigInt.from(10),BigInt.from(5000),true),BigInt.zero);
  });

  test('rapid finite rotation, millisecond cadence, bounds and zero-percent alternate shortcut', () {
    final p = plan(interval: '0.001');
    expect(p.interval, const Duration(milliseconds: 1));
    expect(
      [for (var i = 0; i < 6; i++) p.at(i)],
      [(0, true), (0, false), (1, true), (1, false), (0, true), (0, false)],
    );
    expect(plan(count: '1').wallets.length, 1);
    expect(plan(percent: '0').direction, RapidDirection.buy);
    expect(
      () => plan(mode: RapidDirection.sell, percent: '0'),
      throwsStateError,
    );
    expect(() => plan(count: '10001'), throwsStateError);
    expect(() => plan(interval: '0.0001'), throwsStateError);
    expect(() => plan(interval: '86401'), throwsStateError);
  });

  test('rapid alternating sends actual private swaps and queries original hashes after the finite run', () async {
    final p = plan(percentSell: false);
    final checked = await trader.prepareRapid(p, () => true);
    backend.routeBodies.clear();
    final out = await trader.runRapid(checked);
    expect(
      out.stopped,
      false,
      reason: trader.log.entries.map((e) => e.text).join('\n'),
    );
    final orders = backend.routeBodies
        .where((r) => r['forecastOnly'] != true)
        .toList();
    expect(orders.map((r) => (r['wallet'], r['side'])), [
      (w.address, 'buy'),
      (w.address, 'sell'),
      (other.address, 'buy'),
      (other.address, 'sell'),
    ]);
    expect(backend.bundles.length, 4);
    expect(out.tradeHashes.length, 4);
    await trader.queryRapid();
    expect(trader.unresolved, isEmpty);
    expect(out.confirmed, 4);
    expect(out.failed, 0);
  });

  test(
    'rapid percentage sells use live remaining balances for each wallet',
    () async {
      final p = plan(mode: RapidDirection.sell, count: '3');
      backend.onBundle = (raws) {
        final owner = backend.signatures[raws.single]!.$2;
        final order = backend.routeBodies.lastWhere(
          (r) =>
              r['forecastOnly'] != true &&
              (r['wallet'] as String).toLowerCase() == owner,
        );
        final st = backend.wallets[(order['wallet'] as String).toLowerCase()]!;
        st['tokenBalance'] =
            (int.parse(st['tokenBalance'] as String) -
                    int.parse(order['amount'] as String))
                .toString();
        st['nonce'] = (st['nonce'] as int) + 1;
      };
      final pre = await trader.prepareRapid(p, () => true);
      backend.routeBodies.clear();
      final out = await trader.runRapid(pre);
      expect(
        out.sent.length,
        3,
        reason: trader.log.entries.map((e) => e.text).join('\n'),
      );
      expect(
        backend.routeBodies
            .where((r) => r['forecastOnly'] != true)
            .map((r) => r['amount']),
        ['500', '500', '250'],
      );
    },
  );

  test('fast schedule stops when the current wallet already crossed its balance floor', () async {
    final fast = BatchTrader(backend.api(), ExecutionLog());
    addTearDown(fast.dispose);
    final checked = await fast.prepareRapid(
      plan(mode: RapidDirection.buy, count: '2', interval: '0.08', minNative: '0.5'),
      () => true,
    );
    backend.onBundle = (_) {
      backend.wallets[other.address.toLowerCase()]!['native'] = '499999999999999999';
    };
    final result = await fast.runRapid(checked);
    expect(result.stopped, isTrue);
    expect(backend.bundles, hasLength(1));
    expect(backend.signatures, hasLength(1));
    expect(fast.log.entries.any((entry) => entry.text.contains('BNB 余额低于停止线')), isTrue);
  });

  test('rapid checks configured floor before any submission', () async {
    await expectLater(
      trader.prepareRapid(plan(minNative: '3'), () => true),
      throwsStateError,
    );
    expect(backend.bundles, isEmpty);
  });

  test('fixed rapid swaps pipeline consecutive nonces but stop when 64 relay responses are outstanding', () async {
    final backend = HeldBundles();
    final engine = BatchTrader(backend.api(), ExecutionLog());
    addTearDown(engine.dispose);
    for (final owner in [w, other])
      backend.wallets[owner.address.toLowerCase()] = Map.of(row);
    final p = plan(mode: RapidDirection.buy, count: '68');
    final checked = await engine.prepareRapid(p, () => true);
    final done = engine.runRapid(checked);
    try {
      await backend.atLimit.future.timeout(const Duration(seconds: 8));
      await Future<void>.delayed(Duration.zero);
      expect(backend.inFlight, 64);
    } finally {
      backend.release.complete();
    }
    final result = await done;
    expect(result.stopped, isTrue);
    expect(result.sent, hasLength(64));
    expect(result.sent.toSet(), hasLength(64));
    for (final owner in [w, other]) {
      final nonces = backend.signatures.values
          .where((s) => s.$2 == owner.address.toLowerCase())
          .map((s) => s.$3.nonce);
      expect(nonces, List.generate(32, (i) => 3 + i));
    }
  });

  test('stop during a long rapid interval immediately suppresses subsequent orders', () async {
    final engine = BatchTrader(backend.api(), ExecutionLog());
    addTearDown(engine.dispose);
    backend.onBundle = (_) {
      engine.cancel();
    };
    final checked = await engine.prepareRapid(
      plan(mode: RapidDirection.buy, count: '6', interval: '86400'),
      () => true,
    );
    final out = await engine
        .runRapid(checked)
        .timeout(const Duration(seconds: 2));
    expect(out.stopped, isTrue);
    expect(out.tradeHashes, hasLength(1));
  });

  test('live five-second snapshot stops every wallet after an external balance falls below its floor', () async {
    final engine = BatchTrader(backend.api(), ExecutionLog());
    addTearDown(engine.dispose);
    backend.onBundle = (_) {
      row['native'] = '1';
    };
    final checked = await engine.prepareRapid(
      plan(
        mode: RapidDirection.buy,
        count: '3',
        interval: '12',
        minNative: '0.5',
      ),
      () => true,
    );
    final out = await engine
        .runRapid(checked)
        .timeout(const Duration(seconds: 8));
    expect(out.stopped, true);
    expect(out.tradeHashes, hasLength(1));
    expect(engine.log.entries.any((e) => e.text.contains('低于停止线')), true);
  });

  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets('rapid group is reachable from the new group menu at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = AppState(backend.api(), MemoryKeyStore());
      addTearDown(s.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: s,
              builder: (_, _) => BatchPage(state: s),
            ),
          ),
        ),
      );
      await tester.tap(find.text('新建组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('快速交易组'));
      await tester.pumpAndSettle();
      expect(s.group, isA<RapidGroup>());
      expect(find.text('每笔买入'), findsOneWidget);
      await tester.ensureVisible(find.text('买卖交替'));
      await tester.tap(find.text('买卖交替'));
      await tester.pumpAndSettle();
      expect(find.text('每笔卖出'), findsOneWidget);
      final buy = tester.getRect(find.byKey(const ValueKey('每笔买入BNB')));
      final sell = tester.getRect(find.byKey(const ValueKey('每笔卖出%')));
      if (width == 320) {
        expect(sell.top, greaterThanOrEqualTo(buy.bottom));
        expect(buy.width, greaterThan(200));
      } else {
        expect(sell.top, buy.top);
        expect(sell.left, greaterThanOrEqualTo(buy.right));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
