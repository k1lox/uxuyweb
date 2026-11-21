@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fork_group.dart';

/// End-to-end on a local BSC fork: Dart signing -> backend (UXUY route, private bundles) -> anvil.
/// Run: UXUY_FORK_BACKEND=http://127.0.0.1:3293/ flutter test --tags fork
/// Funding uses anvil_setBalance on the local node only; nothing reaches a public network.
final _backend = Platform.environment['UXUY_FORK_BACKEND'];
final _anvil = Platform.environment['UXUY_FORK_RPC'] ?? 'http://127.0.0.1:8545';
const cake = '0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82';
const flapInnerToken = '0xc86326b3a664478c774e0279546405bdf44f8888';
const feeTo = '0x00000000000000000000000000000000000FEe00';

Future<Object?> anvil(String method, List<Object?> params) async {
  final r = await http.post(
    Uri.parse(_anvil),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    }),
  );
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  if (j['error'] != null) throw StateError('$method: ${j['error']}');
  return j['result'];
}

Future<BigInt> nativeOf(String a) async =>
    BigInt.parse('${await anvil('eth_getBalance', [a, 'latest'])}');

Future<BigInt> tokenOf(String token, String a) async {
  final f = AbiFunction.parse('balanceOf(address) returns (uint256)');
  final out = await anvil('eth_call', [
    {
      'to': token,
      'data': f.encodeHex([a]),
    },
    'latest',
  ]);
  return f.decodeOutput('$out').single! as BigInt;
}

void main() {
  final skip = _backend == null
      ? 'set UXUY_FORK_BACKEND to run fork tests'
      : null;

  setUpAll(() async { if (skip == null) await verifyLocalFork(_anvil, _backend!); });

  for (final (name, token) in [
    ('External', cake),
    ('Four', '0xb25ec03b04d31fb8b47bab586dcd47fd8bb6ffff'),
    ('Flap', flapInnerToken),
    ('Four pool token', '0x5899ac177247689f46cb6b430760373be281ffff'),
    ('Genius V2', '0xa024ea8513b080e7d7a295a107f289de4d4a6666'),
    ('Genius V1', '0xbaf360c78b78f06fe257904000d632122e386666'),
  ]) {
    test('$name executes the verified market on the local fork', () async {
      final client = http.Client();
      addTearDown(client.close);
      final api = BackendClient(Uri.parse(_backend!), client);
      final wallet = TradeWallet.generate('fork');
      await anvil('anvil_setBalance', [wallet.address, '0xde0b6b3a7640000']);
      final round = await ForkGroup.open(api, token, [wallet]);
      final config = await api.config();
      final priorFees = await nativeOf(feeTo);
      for (final buy in [true, false]) {
        final result = await round.trade(buy: buy);
        expect(result.confirmed, 1, reason: round.state.log.entries.map((e) => e.text).join('\n'));
        final receipts = [for (final h in result.sent)
          await anvil('eth_getTransactionReceipt', [h]) as Map];
        expect(receipts.every((row) => row['status'] == '0x1' &&
            row['from']?.toString().toLowerCase() == wallet.address.toLowerCase()), isTrue);
        final targets = receipts.map((row) => row['to']?.toString().toLowerCase()).toSet();
        final expected = round.state.market!.innerTarget ?? config.router;
        expect(targets, contains(expected.toLowerCase()));
        expect(await nativeOf(feeTo), priorFees);
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
  }

  test(
    'linked group on Flap curve: auto loop sells 50% per round, relay funds the short buyer, buys back with received BNB',
    () async {
      const token = flapInnerToken;
      final api = BackendClient(Uri.parse(_backend!), http.Client());
      final market = Market(await api.platform(token));
      final log = ExecutionLog();
      final seed = DateTime.now().microsecondsSinceEpoch % 1000000;
      TradeWallet key(int i) => TradeWallet.import(
        'L$i',
        '0x${(0x111000 + seed * 8 + i).toRadixString(16).padLeft(64, '0')}',
      );
      final sellers = [key(0), key(1)], buyers = [key(2)], transits = [key(3)];
      for (final w in sellers) {
        await anvil('anvil_setBalance', [w.address, '0xde0b6b3a7640000']);
      }
      await anvil('anvil_setBalance', [
        buyers.single.address,
        '0x2386f26fc10000',
      ]); // 0.01 BNB: too little to buy back
      // Sellers acquire a position first.
      final seedTrader = BatchTrader(
        api,
        log,
        label: 'seed',
        pollEvery: const Duration(milliseconds: 500),
      );
      final bought = await seedTrader.run(
        TradePlan(
          token: token,
          buy: true,
          wallets: sellers,
          mode: SendMode.bundle,
          market: market,
          maxImpactPercent: 60,
          amount: AmountRule(
            ratio: false,
            min: parseUnits('0.05', 18),
            max: parseUnits('0.05', 18),
          ),
        ),
      );
      expect(
        bought.confirmed,
        2,
        reason: log.entries.map((e) => e.text).join('\n'),
      );
      final buyerTokenBefore = await tokenOf(token, buyers.single.address);

      final state = AppState(api, MemoryKeyStore(), impactSettings: const ImpactSettings(
        bundle: 60, intervalStart: 60, intervalLive: 60,
      ));
      addTearDown(state.dispose);
      await state.init();
      await state.loadToken(token);
      final linked = state.addLinkedGroup()
        ..sellers = sellers
        ..buyers = buyers
        ..min = '50'
        ..max = '50';
      linked.transitByBuyer[buyers.single.address.toLowerCase()] = transits.single;
      await state.prepareLinked(linked);
      final progress = await state.startLinked(linked,
          handle: state.operationHandle(linked), impactConfirmed: true);
      expect(
        progress.stopped,
        isFalse,
        reason: state.log.entries.map((e) => e.text).join('\n'),
      );
      expect(progress.finished, isTrue);
      expect(
        progress.round,
        3,
        reason: 'auto loop: two rounds of 50% of the start holdings, then the sellers are empty',
      );
      for (final w in sellers) {
        expect(
          await tokenOf(token, w.address) * BigInt.from(1000000),
          lessThanOrEqualTo(progress.tranche),
          reason: 'at most dust is kept',
        );
      }
      expect(
        progress.received,
        greaterThan(parseUnits('0.02', 18)),
        reason: 'about half of 0.1 BNB worth sold',
      );
      expect(
        await tokenOf(token, buyers.single.address),
        greaterThan(buyerTokenBefore),
        reason: 'buyer bought back',
      );
      expect(
        state.log.entries.any((e) => e.text.contains('中转补款完成')),
        isTrue,
        reason: 'relay funding was needed and done',
      );
      expect(
        await nativeOf(transits.single.address),
        BigInt.zero,
        reason: 'relay forwards everything it received',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'wallet tools: relay distribution (BNB and token), many-to-many, collect',
    () async {
      final api = BackendClient(Uri.parse(_backend!), http.Client());
      final log = ExecutionLog();
      final engine = TransferEngine(
        api,
        log,
        pollEvery: const Duration(milliseconds: 500),
      );
      final seed = DateTime.now().microsecondsSinceEpoch % 1000000;
      TradeWallet key(int i) => TradeWallet.import(
        'T$i',
        '0x${(0x222000 + seed * 16 + i).toRadixString(16).padLeft(64, '0')}',
      );
      final src = key(0);
      final recipients = [key(1), key(2)];
      final relays = [key(3), key(4)];
      await anvil('anvil_setBalance', [src.address, '0xde0b6b3a7640000']);
      String reason() => log.entries.map((e) => e.text).join('\n');

      // One-to-many BNB through relays, one bundle.
      final amount = parseUnits('0.01', 18);
      final transits = {
        for (var i = 0; i < 2; i++)
          recipients[i].address.toLowerCase(): relays[i],
      };
      final rows = engine.drawOneToMany(
        src,
        [for (final r in recipients) r.address],
        amount,
        amount,
        transits: transits,
      );
      final run = await engine.prepareDistribution(
        rows,
        TransferAsset.bnb,
        source: src,
      );
      await engine.execute(run);
      expect(run.complete, isTrue, reason: reason());
      for (var i = 0; i < 2; i++) {
        expect(await nativeOf(recipients[i].address), amount);
        expect(
          await nativeOf(relays[i].address),
          BigInt.zero,
          reason: 'relay forwards everything, its gas was prepaid',
        );
      }

      // Token through relays (CAKE bought through UXUY first), interval mode.
      final trader = BatchTrader(
        api,
        log,
        label: 'seed',
        pollEvery: const Duration(milliseconds: 500),
      );
      final bought = await trader.run(
        TradePlan(
          token: cake,
          buy: true,
          wallets: [src],
          mode: SendMode.bundle,
          amount: AmountRule(
            ratio: false,
            min: parseUnits('0.02', 18),
            max: parseUnits('0.02', 18),
          ),
        ),
      );
      expect(bought.confirmed, 1, reason: reason());
      final cakeAsset = await engine.asset(cake);
      final held = await tokenOf(cake, src.address);
      final each = held ~/ BigInt.from(4);
      final tokenRows = engine.drawOneToMany(
        src,
        [for (final r in recipients) r.address],
        each,
        each,
        transits: transits,
      );
      final tokenRun = await engine.prepareDistribution(
        tokenRows,
        cakeAsset,
        source: src,
        intervalMin: 0,
        intervalMax: 1,
      );
      expect(tokenRun.legs, hasLength(6));
      await engine.execute(tokenRun);
      expect(tokenRun.complete, isTrue, reason: reason());
      for (var i = 0; i < 2; i++) {
        expect(await tokenOf(cake, recipients[i].address), each);
        expect(await tokenOf(cake, relays[i].address), BigInt.zero);
      }

      // Many-to-many: recipient i pays back half its BNB to a fresh wallet.
      final back = [key(5), key(6)];
      final paired = await engine.drawPaired(
        recipients,
        [for (final b in back) b.address],
        TransferAsset.bnb,
        ratio: true,
        min: BigInt.from(5000),
        max: BigInt.from(5000),
      );
      final pairedRun = await engine.prepareDistribution(
        paired,
        TransferAsset.bnb,
        source: recipients.first,
      );
      await engine.execute(pairedRun);
      expect(pairedRun.complete, isTrue, reason: reason());
      expect(await nativeOf(back[0].address), greaterThan(BigInt.zero));

      // Collect BNB and CAKE back to the source.
      final before = await nativeOf(src.address);
      final collect = await engine.prepareCollection(
        [...recipients, ...back],
        src.address,
        TransferAsset.bnb,
      );
      await engine.execute(collect);
      expect(collect.complete, isTrue, reason: reason());
      expect(await nativeOf(src.address), greaterThan(before));
      for (final w in [...recipients, ...back]) {
        expect(
          await nativeOf(w.address),
          lessThan(parseUnits('0.000001', 18)),
          reason: 'only dust below one transfer fee remains',
        );
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final nonTax in [false, true]) {
    test('Flap V${nonTax ? 7 : 6} creates without collecting a project payment', () async {
      final api = BackendClient(Uri.parse(_backend!), http.Client());
      addTearDown(api.http_.close);
      final dev = TradeWallet.import('Local creator',
        (0x333000 + (nonTax ? 1 : 0)).toRadixString(16).padLeft(64, '0'));
      await anvil('anvil_setBalance', [dev.address, '0x8ac7230489e80000']);
      final runner = FlapLauncher(api, ExecutionLog(), pollEvery: const Duration(milliseconds: 500));
      addTearDown(runner.dispose);
      final pool = (await runner.catalog()).firstWhere((p) => p.native);
      await runner.launch(FlapLaunchForm(
        nonTax: nonTax, name: 'Local fork', symbol: 'FORK', payment: pool,
        buyTaxBps: nonTax ? 0 : 300, sellTaxBps: nonTax ? 0 : 300,
        marketingBps: nonTax ? 0 : 10000, minimumShare: flapMinDividendShare,
        image: const LaunchImage([1], 'test.png', 'image/png')),
        dev: LaunchBuyer(dev, BigInt.zero),
        metaOverride: 'bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy');
      expect(runner.state, LaunchState.launched, reason: runner.error);
      final create = runner.transactions.single;
      expect(create.kind, 'create');
      expect(create.to, flapPortal);
      expect(create.value, BigInt.zero);
      expect(create.status, 'confirmed');
      expect(await anvil('eth_getCode', [runner.session!.token, 'latest']), isNot('0x'));
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
  }

  test(
    'backend refuses a direct PancakeSwap swap signed by the module',
    () async {
      final api = BackendClient(Uri.parse(_backend!), http.Client());
      final w = TradeWallet.import('X', '0x${'f00'.padLeft(64, '0')}');
      final swap = AbiFunction.parse(
        'swapExactETHForTokens(uint256,address[],address,uint256)',
      );
      final tx = w.sign(
        LegacyTx(
          nonce: 0,
          gasPrice: BigInt.from(100000000),
          gasLimit: 200000,
          to: '0x10ED43C718714eb63d5aA57B78B54704E256024E',
          value: BigInt.one,
          data: swap.encode([
            BigInt.zero,
            ['0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', cake],
            w.address,
            BigInt.from(9999999999),
          ]),
        ),
      );
      await expectLater(
        api.submit(tx.raw),
        throwsA(
          isA<BackendException>().having(
            (e) => e.code,
            'code',
            'ACTION_NOT_ALLOWED',
          ),
        ),
      );
    },
    skip: skip,
  );
}
