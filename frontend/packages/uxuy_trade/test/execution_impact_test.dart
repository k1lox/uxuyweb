import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

class _Api extends BackendClient {
  _Api(this.fake) : super(Uri.parse('http://backend.test'), fake.client());
  final FakeBackend fake;
  final forecasts = <BigInt>[];
  final bundleAmounts = <BigInt>[];
  final walletRoutes = <RouteRequestData>[];
  double small = 1, total = 21;
  bool wrongWalletData = false;
  bool mixed = false,
      expired = false,
      wrongAmount = false,
      loseResponse = false;
  void Function()? afterQuote;
  int block = 1000;
  bool gasSpikes = false;
  int flapStatus = 1;
  final quotedBlocks = <String>[];
  int? relayBlock;

  @override
  Future<GasInfo> gas() async {
    block++;
    return GasInfo(
      gasSpikes && block > 1001 ? parseUnits('1', 14) : gasPrice,
      block,
    );
  }

  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    quotedBlocks.add(block);
    return '0x${flapStatus.toRadixString(16).padLeft(64, '0')}';
  }

  RoutePlan plan(RouteRequestData r, {bool bundle = false, int? expires}) {
    if (r.forecastOnly) {
      forecasts.add(r.amount);
    } else {
      walletRoutes.add(r);
    }
    final deadline =
        expires ??
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 + (expired ? -1 : 90));
    final path = [
      mixed && !r.forecastOnly && walletRoutes.length.isEven ? token : pool,
    ];
    return RoutePlan(
      token: r.token,
      buy: r.buy,
      amount: wrongAmount ? r.amount + BigInt.one : r.amount,
      wallet: r.wallet,
      to: router,
      data: r.forecastOnly ? '0x' : uxuyCall(r.wallet, r.amount, r.buy),
      quoteScope: bundle && r.forecastOnly ? 'bundle' : 'wallet',
      chainId: 56,
      slippagePpm: 5000,
      spender: router,
      simulation: r.forecastOnly ? 'forecast' : !r.buy && BigInt.parse('${fake.wallets[r.wallet.toLowerCase()]?['routerAllowance'] ?? 0}') < r.amount ? 'approve_then_swap' : 'uxuy',
      executed: !r.forecastOnly && !wrongWalletData,
      value: r.buy ? r.amount : BigInt.zero,
      pools: path,
      dexes: ['PancakeSwap'],
      quoteOut: r.amount * BigInt.two,
      minOut: r.amount * BigInt.two,
      priceImpact: r.amount > BigInt.from(100) ? total : small,
      deadline: deadline,
      gasLimit: r.forecastOnly ? 0 : 200000,
    );
  }

  @override
  Future<RoutePlan> route(RouteRequestData req) async {
    final planned = plan(req);
    afterQuote?.call();
    return planned;
  }

  @override
  Future<List<RouteResult>> routes(List<RouteRequestData> requests) async => [
    for (final req in requests) RouteResult.ok(plan(req)),
  ];

  @override
  Future<({RoutePlan group, List<RoutePlan> wallets})> bundleRoute(
    List<RouteRequestData> requests,
  ) async {
    final first = requests.first;
    final total = requests.fold(BigInt.zero, (sum, r) => sum + r.amount);
    bundleAmounts.add(total);
    final group = plan(
      RouteRequestData(
        buy: first.buy,
        token: first.token,
        amount: total,
        wallet: first.wallet,
        forecastOnly: true,
      ),
      bundle: true,
    );
    return (
      group: group,
      wallets: [
        if (!first.forecastOnly)
          for (final r in requests)
            plan(r, bundle: true, expires: group.deadline),
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> groupBundle(List<String> raws,int maxBlockNumber,
      {required bool Function() active,Object? schedule}) async {
    relayBlock = maxBlockNumber;
    if (loseResponse) throw TimeoutException('response lost');
    return super.groupBundle(raws, maxBlockNumber,active:active,schedule:schedule);
  }
}

void main() {
  late FakeBackend fake;
  late _Api api;
  late BatchTrader trader;
  late List<TradeWallet> wallets;

  TradePlan plan({
    SendMode mode = SendMode.bundle,
    double threshold = 20,
    bool unknown = false,
  }) => TradePlan(
    wallets: wallets,
    buy: true,
    token: token,
    mode: mode,
    maxImpactPercent: threshold,
    allowUnknownImpact: unknown,
    amount: AmountRule(
      ratio: false,
      min: BigInt.from(100),
      max: BigInt.from(100),
    ),
  );

  setUp(() {
    fake = FakeBackend();
    api = _Api(fake);
    trader = BatchTrader(api, ExecutionLog(), sleep: (_) async {});
    wallets = [
      for (final key in ['1', '2'])
        TradeWallet.import('W$key', '0x${key.padLeft(64, '0')}'),
    ];
    for (final w in wallets) {
      fake.wallets[w.address.toLowerCase()] = {
        'native': parseUnits('1', 18).toString(),
        'nonce': 0,
        'tokenBalance': '0',
        'routerAllowance': '0',
      };
    }
  });

  test('zero threshold executes an explicitly zero route and blocks a positive route', () async {
    api.total = .0001;
    api.small = 0;
    expect((await trader.run(plan(threshold: 0))).stopped, isTrue);
    expect(fake.submitted,isEmpty);
    api.total = 0;
    expect((await trader.run(plan(threshold: 0))).confirmed,2);
  });

  test('forecast uses total input; two small wallet impacts cannot override the group ceiling', () async {
    final preview = await trader.prepare(plan());
    expect(preview.impact, 21);
    expect(api.forecasts, [BigInt.from(200)]);
    final out = await trader.run(plan());
    expect(out.stopped, true);
    expect(out.remaining, hasLength(2));
    expect(fake.bundles, isEmpty);
    expect(api.bundleAmounts, [
      BigInt.from(200),
      BigInt.from(200),
    ], reason: 'one group-sized quote at preview and one at execution');
  });

  test(
    'execution checks current group impact even with a fresh preview',
    () async {
      api.total = 8;
      expect((await trader.prepare(plan())).impact, 8);
      api.total = 25;
      expect((await trader.run(plan())).stopped, isTrue);
      expect(api.forecasts, [BigInt.from(200), BigInt.from(200)]);
      expect(fake.bundles, isEmpty);
    },
  );

  test(
    'fresh gas spike pauses interval even after a successful price forecast',
    () async {
      api.gasSpikes = true;
      final out = await trader.run(plan(mode: SendMode.interval));
      expect(out.stopped, isTrue);
      expect(out.remaining, hasLength(2));
      expect(fake.bundles, isEmpty);
    },
  );

  test('each wallet may have its own UXUY pool path', () async {
    api.mixed = true;
    expect((await trader.run(plan(threshold: 22))).confirmed, 2);
  });

  test(
    'matching metadata cannot authorize an unexecuted wallet quote',
    () async {
      api.total = 5;
      api.wrongWalletData = true;
      final out = await trader.run(plan());
      expect(out.stopped, isTrue);
      expect(fake.bundles, isEmpty);
    },
  );

  test('interval forecast always completes at high impact; live cap pauses before sending', () async {
    api.small = 25;
    final preview = await trader.prepare(plan(mode: SendMode.interval));
    expect(preview.impact, 25);
    expect(api.forecasts, [BigInt.from(100), BigInt.from(100)]);
    expect(preview.quotedOutput, BigInt.from(200));
    expect(preview.inputTotal, BigInt.from(200));
    final out = await trader.run(plan(mode: SendMode.interval));
    expect(out.stopped, true);
    expect(out.remaining, hasLength(2));
    expect(fake.bundles, isEmpty);
  });

  test(
    'pause and resume while the route is in flight invalidates it',
    () async {
      api.afterQuote = () {
        trader.pause();
        trader.resume();
      };
      final out = await trader.run(plan(mode: SendMode.interval));
      expect(out.stopped, true);
      expect(out.sent, isEmpty);
      expect(fake.bundles, isEmpty);
    },
  );

  test('interval sells check every funded wallet, surface the worst, and enforce its live cap', () async {
    final empty = TradeWallet.import('empty', '3'.padLeft(64, '0'));
    fake.wallets[empty.address.toLowerCase()] = {
      'native': '1000000000000000000', 'nonce': 0, 'tokenBalance': '0', 'routerAllowance': '0',
    };
    for (var i = 0; i < wallets.length; i++) {
      final st = fake.wallets[wallets[i].address.toLowerCase()]!;
      st['tokenBalance'] = '${(i + 1) * 100}';
      st['routerAllowance'] = '1000';
    }
    final plan = TradePlan(
      wallets: [empty, ...wallets], token: token, buy: false, mode: SendMode.interval,
      amount: AmountRule(ratio: true, min: BigInt.from(10000), max: BigInt.from(10000)),
    );
    final prepared = await trader.prepare(plan);
    expect(prepared.skipped, 1);
    expect(prepared.amounts.keys.first, wallets.first.address.toLowerCase());
    expect(api.forecasts, [BigInt.from(100), BigInt.from(200)]);
    expect(prepared.impact, api.total);
    expect(prepared.quotedOutput, BigInt.from(200));
    expect(prepared.inputTotal, BigInt.from(300));
    final out = await trader.run(plan);
    expect(api.walletRoutes.map((r) => r.amount), [BigInt.from(100), BigInt.from(200)]);
    expect(out.confirmed, 1);
    expect(out.stopped, isTrue);
    expect(out.remaining.keys, [wallets.last.address.toLowerCase()]);
    expect(fake.bundles, hasLength(1));
  });

  test('a changed first sell amount pauses before substituting the next wallet', () async {
    final amount = BigInt.from(100);
    final initial = TradePlan(
      wallets: wallets, token: token, buy: false, mode: SendMode.interval,
      amount: AmountRule(ratio: false, min: amount, max: amount),
    );
    final preview = await trader.prepare(initial, walletSnapshot: [
      for (final w in wallets) WalletState(w.address, parseUnits('1', 18), 0, amount, amount),
    ]);
    // The executable snapshot now has zero tokens in the first wallet.
    fake.wallets[wallets.last.address.toLowerCase()]!['tokenBalance'] = '100';
    final result = await trader.run(TradePlan(
      wallets: wallets, token: token, buy: false, mode: SendMode.interval,
      amount: initial.amount, resume: preview.amounts,
    ));
    expect(result.stopped, isTrue);
    expect(result.remaining, preview.amounts);
    expect(api.walletRoutes, isEmpty);
    expect(fake.bundles, isEmpty);
  });

  for (final pending in [false, true]) {
    test('interval sale refreshes the next wallet after the first receipt (pending: $pending)', () async {
      final engine = BatchTrader(fake.api(), ExecutionLog(), sleep: (_) async {});
      addTearDown(engine.dispose);
      for (final w in wallets) {
        final row = fake.wallets[w.address.toLowerCase()]!;
        row['tokenBalance'] = '1000';
        row['routerAllowance'] = '1000';
      }
      final second = wallets.last.address.toLowerCase();
      fake.onBundle = (_) {
        if (fake.bundles.length != 1) return;
        fake.wallets[second]!['nonce'] = 9;
        fake.wallets[second]!['tokenBalance'] = '310';
        fake.minedNonces[second] = pending ? 8 : 9;
      };
      final outcome = await engine.run(TradePlan(
        wallets: wallets, token: token, buy: false, mode: SendMode.interval,
        amount: AmountRule(ratio: false, min: BigInt.from(500), max: BigInt.from(500)),
      ));
      expect(fake.bundles, hasLength(pending ? 1 : 2));
      expect(outcome.confirmed, pending ? 1 : 2);
      expect(outcome.stopped, pending);
      if (pending) {
        expect(outcome.remaining.keys, [second]);
        expect(fake.signatures, hasLength(1));
      } else {
        expect(fake.signatures[fake.bundles.last.single]!.$3.nonce, 9);
        expect(fake.routeBodies.last['amount'], '310');
      }
    });
  }

  test('expired or mismatched preview cannot be accepted or sent', () async {
    api.wrongAmount = true;
    await expectLater(trader.prepare(plan()), throwsA(isA<BackendException>()));
    api.wrongAmount = false;
    api.expired = true;
    final out = await trader.run(plan(mode: SendMode.interval));
    expect(out.stopped, true);
    expect(fake.bundles, isEmpty);
  });

  test('lost relay reply retains the uncertain hash and excludes it from retry amounts', () async {
    api.loseResponse = true;
    final out = await trader.run(plan(mode: SendMode.interval));
    expect(out.stopped, isTrue);
    expect(trader.unresolved, hasLength(1));
    expect(out.remaining.keys, [wallets.last.address.toLowerCase()]);
    await expectLater(trader.run(plan()), throwsStateError);
  });

}
