import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:uxuy_trade/src/ui/holding_ratio_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/holding_ratio.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/state/app_state.dart';

import 'support/fake_backend.dart';

const _wallet = '0x0000000000000000000000000000000000000011';
const _token = '0x0000000000000000000000000000000000000042';
const _pool = '0x0000000000000000000000000000000000000088';
const _factory = '0xca143ce32fe78f1f7019d7d551a6402fc5350c73';
const _quote = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c';
const _zero = '0x0000000000000000000000000000000000000000';

class _Reads extends Fake implements BackendClient {
  int blocks = 0;
  bool failNextBlock = false;
  bool discoverPool = true;
  Completer<void>? waitForBlock;
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    final (method, params) = calls.single;
    if (method == 'eth_blockNumber') {
      blocks++;
      await waitForBlock?.future;
      if (failNextBlock) throw StateError('测试读取失败');
      return ['0x64'];
    }
    expect(method, 'eth_call');
    expect(params.last, '0x64');
    final agg = AbiFunction.parse(
      'aggregate3((address,bool,bytes)[]) returns ((bool,bytes)[])',
    );
    final entries =
        agg.decodeInput((params.first as Map)['data']).single as List;
    final rows = <List<Object?>>[];
    for (final entry in entries) {
      final (target, bytes) = (entry[0].toString().toLowerCase(), entry[2]);
      final signatures = [
        'totalSupply() returns (uint256)',
        'decimals() returns (uint8)',
        'symbol() returns (string)',
        'balanceOf(address) returns (uint256)',
        'getPair(address,address) returns (address)',
        'getPool(address,address,uint24) returns (address)',
        'token0() returns (address)',
        'token1() returns (address)',
        'factory() returns (address)',
      ];
      var ok = false;
      for (final sig in signatures) {
        final call = AbiFunction.parse(sig);
        List<Object?> args;
        try {
          args = call.decodeInput(bytes);
        } on FormatException {
          continue;
        }
        Object? val;
        if (target == _token) {
          val = switch (call.name) {
            'totalSupply' => 1000,
            'decimals' => 0,
            'symbol' => 'FIX',
            'balanceOf' =>
              args.first.toString().toLowerCase() == _wallet
                  ? 100
                  : args.first.toString().toLowerCase() == _pool
                  ? 200
                  : 0,
            _ => null,
          };
        } else if (call.name == 'getPair') {
          val =
              discoverPool && target == _factory &&
                  args.map((a) => a.toString().toLowerCase()).contains(_quote)
              ? _pool
              : _zero;
        } else if (call.name == 'getPool') {
          val = _zero;
        } else if (target == _pool) {
          val = switch (call.name) {
            'token0' => _token,
            'token1' => _quote,
            'factory' => _factory,
            _ => null,
          };
        }
        if (val != null) {
          rows.add([
            true,
            encodeSequence(call.outputs, [val]),
          ]);
          ok = true;
        }
        break;
      }
      if (!ok) rows.add([false, <int>[]]);
    }
    return [
      bytesToHex(encodeSequence(agg.outputs, [rows])),
    ];
  }
}

void main() {
  TradeWallet wallet(int i) =>
      TradeWallet.import('fixture$i', i.toRadixString(16).padLeft(64, '0'));
  void fund(
    FakeBackend b,
    TradeWallet w,
    int nonce, {
    int tokens = 0,
    String bnb = '1000000000000000000',
  }) {
    b.wallets[w.address.toLowerCase()] = {
      'nonce': nonce,
      'native': bnb,
      'tokenBalance': '$tokens',
      'routerAllowance': '0',
    };
  }

  test('holds all new transfers before signing if another app owns a pending nonce', () async {
    final b = FakeBackend(), w = wallet(21);
    fund(b, w, 3);
    b.minedNonces[w.address.toLowerCase()] = 2;
    final engine = TransferEngine(b.api(), ExecutionLog(), sleep: (_) async {});
    final rows = engine.drawOneToMany(
      w,
      [wallet(22).address],
      BigInt.one,
      BigInt.one,
    );
    await expectLater(
      engine.prepareDistribution(rows, TransferAsset.bnb, source: w),
      throwsA(predicate((e) => e.toString().contains('待确认交易'))),
    );
    expect(b.bundles, isEmpty);
  });
  test('distribution repeats only its original bytes after three expired windows and splits by block gas', () async {
    final b = FakeBackend()..blockGasLimit = 42000, w = wallet(23);
    fund(b, w, 2);
    b.receipts.addAll(List.filled(3, 'not_included'));
    final engine = TransferEngine(b.api(), ExecutionLog(), sleep: (_) async {});
    final rows = engine.drawOneToMany(
      w,
      [for (var i = 24; i < 27; i++) wallet(i).address],
      BigInt.one,
      BigInt.one,
    );
    final run = await engine.prepareDistribution(
      rows,
      TransferAsset.bnb,
      source: w,
    );
    await engine.execute(run);
    expect(run.complete, true);
    expect(b.bundles.map((p) => p.length), [2, 2, 2, 2, 1]);
    expect(
      b.bundles.take(4).every((p) => p.join() == b.bundles.first.join()),
      true,
    );
  });
  test(
    'a pending earlier wave cannot stop the thirteenth independent source',
    () async {
      final b = FakeBackend()..receipt = 'submitted';
      final resume = Completer<void>(), dispatched = Completer<void>();
      final senders = [for (var i = 1; i <= 13; i++) wallet(i + 40)];
      for (final sender in senders) {
        fund(b, sender, 0);
      }
      final engine = TransferEngine(
        b.api(),
        ExecutionLog(),
        sleep: (_) => resume.future,
      );
      final rows = await engine.drawPaired(
        senders,
        [for (var i = 1; i <= 13; i++) wallet(i + 80).address],
        TransferAsset.bnb,
        ratio: false,
        min: BigInt.one,
        max: BigInt.one,
      );
      final run = await engine.prepareDistribution(
        rows,
        TransferAsset.bnb,
        source: senders.first,
      );
      b.onBundle = (_) {
        if (b.bundles.length == 13 && !dispatched.isCompleted)
          dispatched.complete();
      };
      final work = engine.execute(run);
      try {
        await dispatched.future.timeout(const Duration(seconds: 3));
      } finally {
        b.receipt = 'confirmed';
        resume.complete();
        await work;
      }
      expect(run.complete, isTrue);
      expect(b.bundles.length, 13);
    },
  );
  test('zero-interval paired distribution isolates an underfunded source and preserves eligible rows', () async {
    final b = FakeBackend(), a = wallet(29), c = wallet(28);
    fund(b, a, 0, tokens: 500, bnb: '0');
    fund(b, c, 0, tokens: 250);
    final engine = TransferEngine(b.api(), ExecutionLog(), sleep: (_) async {});
    const asset = TransferAsset(token, 'FIX', 0);
    final rows = await engine.drawPaired(
      [a, c],
      [wallet(30).address, wallet(31).address],
      asset,
      ratio: true,
      min: BigInt.from(10000),
      max: BigInt.from(10000),
    );
    final run = await engine.prepareDistribution(rows, asset, source: a);
    expect(run.total, BigInt.from(250));
    expect(run.rows.first.amount, BigInt.zero);
    expect(run.statusOf(0), TransferStatus.skipped);
    await engine.execute(run);
    expect(run.complete, true);
    expect(b.bundles.length, 1);
    expect(run.statusOf(1), TransferStatus.confirmed);
  });
  test(
    'generation accepts 10,000 and rejects 10,001 before generating',
    () async {
      final state = AppState(FakeBackend().api(), MemoryKeyStore());
      addTearDown(state.dispose);
      await expectLater(state.generate(10001), throwsFormatException);
      final batch = await state.generate(10000);
      expect(batch.map((w) => w.address).toSet(), hasLength(10000));
      expect(batch.last.label, 'N10000');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets('holding ratio displays checked snapshot at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: uxuyTheme(ThemeData()),
          home: Scaffold(body: HoldingRatioPage(api: _Reads(), active: true)),
        ),
      );
      await tester.enterText(find.byType(TextField).first, _token);
      await tester.enterText(find.byType(TextField).at(1), _wallet);
      await tester.pump();
      await tester.tap(find.text('查询控盘率'));
      await tester.pumpAndSettle();
      expect(find.text('控盘率  12.5%'), findsOneWidget);
      expect(find.text('FIX · 区块 100'), findsOneWidget);
      final held = tester.getTopLeft(find.text('持仓'));
      final supply = tester.getTopLeft(find.text('总供应量'));
      if (width >= 1000) {
        expect(supply.dy, closeTo(held.dy, 1));
        expect(supply.dx, greaterThan(held.dx));
      } else {
        expect(supply.dx, closeTo(held.dx, 1));
        expect(supply.dy, greaterThan(held.dy));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('holding ratio keeps the dated snapshot on refresh failure and closes cancelled reads', (tester) async {
    final rpc = _Reads();
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: HoldingRatioPage(api: rpc, active: true),
    )));
    final search = find.widgetWithText(FilledButton, '查询控盘率');
    expect(tester.widget<FilledButton>(search).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, _token);
    await tester.tap(find.byTooltip('展开编辑钱包公开地址'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), _wallet);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.text('控盘率  12.5%'), findsOneWidget);
    expect(find.textContaining('查询时间'), findsOneWidget);
    rpc.failNextBlock = true;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示上次查询结果'), findsOneWidget);
    expect(find.text('FIX · 区块 100'), findsOneWidget);
    rpc.failNextBlock = false;
    rpc.waitForBlock = Completer<void>();
    await tester.tap(search);
    await tester.pump();
    await tester.tap(find.text('取消查询'));
    rpc.waitForBlock!.complete();
    await tester.pumpAndSettle();
    expect(find.text('FIX · 区块 100'), findsNothing);
    expect(tester.widget<FilledButton>(search).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('holding ratio leaves circulating supply unverified when no pool is identified', (tester) async {
    final rpc = _Reads()..discoverPool = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: HoldingRatioPage(api: rpc, active: true),
    )));
    await tester.enterText(find.byType(TextField).first, _token);
    await tester.enterText(find.byType(TextField).at(1), _wallet);
    await tester.pump();
    await tester.tap(find.text('查询控盘率'));
    await tester.pumpAndSettle();
    final circulating = find.ancestor(of: find.text('流通量'), matching: find.byType(Row)).first;
    expect(find.descendant(of: circulating, matching: find.text('待核实')), findsOneWidget);
    expect(find.descendant(of: circulating, matching: find.text('1000 FIX')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('BSC holding query uses one block, verifies official binding, excludes a wallet that is also the pool', () async {
    final rpc = _Reads();
    final r = await readHoldingRatio(
      rpc,
      _token,
      '$_wallet\n$_pool\n$_wallet',
      _pool,
    );
    expect(rpc.blocks, 1);
    expect(r.poolBalance, BigInt.from(200));
    expect(r.held, BigInt.from(100));
    expect(r.circulating, BigInt.from(800));
    expect(r.percent, '12.5%');
    expect(r.wallets, hasLength(2));
    expect(r.wallets.last.label, isNotEmpty);
  });
  test(
    'rejects an unverified user-supplied pool and private keys in watchlist',
    () async {
      await expectLater(
        readHoldingRatio(_Reads(), _token, _wallet, _wallet),
        throwsFormatException,
      );
      expect(
        () => holdingAddresses('0x${'1'.padLeft(64, '0')}'),
        throwsFormatException,
      );
    },
  );
  test(
    'one source counts unique wallets; paired inputs reject duplicate lines',
    () {
      final a = '1'.padLeft(64, '0'), b = '2'.padLeft(64, '0');
      List<TradeWallet> parse(String text, {bool paired = false}) =>
          parsePrivateKeys(
            text,
            existing: {},
            startIndex: 0,
            maxCount: paired ? 10000 : 1,
            rejectDuplicates: paired,
          );
      expect(parse('$a\n$a'), hasLength(1));
      expect(() => parse('$a\n$b'), throwsFormatException);
      expect(() => parse('$a\n$a\n$b', paired: true), throwsFormatException);
      expect(parse('$a\n$b', paired: true), hasLength(2));
    },
  );
}
