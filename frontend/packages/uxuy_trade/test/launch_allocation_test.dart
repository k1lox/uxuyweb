import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_allocation.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

class _Api extends BackendClient {
  _Api()
    : super(
        Uri.parse('http://allocation.invalid'),
        MockClient((req) async {
          final payload = req.url.path == '/api/flap'
              ? {'tokens': []}
              : {'code': 0, 'data': []};
          return http.Response(
            jsonEncode({'ok': true, 'payload': payload}),
            200,
          );
        }),
      );
  final reads = <(int, String?, bool)>[];
  bool omit = false;
  @override
  Future<List<WalletState>> transferWalletStates(
    List<String> wallets, {
    String? token,
    bool refresh = false,
  }) async {
    reads.add((wallets.length, token, refresh));
    return [
      for (final (index, wallet) in wallets.indexed)
        if (!omit || index != 0)
          WalletState(
            wallet,
            parseUnits('${index + 1}', 18),
            0,
            BigInt.from(1000001),
            null,
          ),
    ].reversed.toList();
  }

  @override
  Future<GasInfo> gas() async => GasInfo(BigInt.one, 1);
}

void main() {
  final one = parseUnits('1', 18);
  BigInt maximum(
    LaunchAllocationPlatform platform, {
    bool native = true,
    bool migrate = false,
    bool outside = false,
    bool last = false,
    bool direct = false,
    BigInt? balance,
  }) => launchBuyerMaximum(
    platform: platform,
    balance: balance ?? one,
    gasPrice: BigInt.from(10),
    payNative: !direct,
    nativePool: native,
    migrate: migrate,
    outside: outside,
    lastInner: last,
  );
  test('BotAI asset, phase, migration and future sell reserves', () {
    const four = LaunchAllocationPlatform.four,
        flap = LaunchAllocationPlatform.flap,
        genius = LaunchAllocationPlatform.genius;
    expect(maximum(four), one - BigInt.from(4300000 * 10));
    expect(maximum(four, native: false), one - BigInt.from(4450000 * 10));
    expect(
      maximum(four, migrate: true, last: true),
      one - BigInt.from(10800000 * 10),
    );
    expect(
      maximum(four, migrate: true, outside: true),
      one - BigInt.from(5300000 * 10),
    );
    expect(maximum(flap), one - BigInt.from(8150000 * 10));
    expect(
      maximum(flap, migrate: true, last: true),
      one - BigInt.from(13150000 * 10),
    );
    expect(maximum(flap, outside: true), one - BigInt.from(10150000 * 10));
    expect(maximum(genius), parseUnits('0.995', 18));
    expect(maximum(genius, balance: BigInt.one), BigInt.zero);
    for (final kind in LaunchAllocationPlatform.values) {
      expect(maximum(kind, direct: true, native: false), one);
    }
  });

  test('fresh ERC20 reads in bounded batches, wrong or missing rows never fill a draft', () async {
    final api = _Api();
    addTearDown(api.http_.close);
    final buyers = List.generate(
      200,
      (i) => (address: '0x${i.toRadixString(16).padLeft(40, '0')}', amount: ''),
    );
    Future<List<LaunchAllocationRow>> load() => loadLaunchAllocation(
      api,
      buyers: buyers,
      platform: LaunchAllocationPlatform.genius,
      paymentToken: '0x0000000000000000000000000000000000000001',
      nativePool: false,
      migrate: true,
      outside: true,
    );
    final rows = await load();
    expect(
      rows.map((row) => row.address),
      buyers.map((buyer) => buyer.address),
    );
    expect(rows.every((row) => row.maximum == BigInt.from(1000001)), isTrue);
    expect(api.reads.map((r) => r.$1), [100, 100]);
    expect(api.reads.every((r) => r.$3 && r.$2 != null), isTrue);
    api.omit = true;
    await expectLater(load(), throwsStateError);
  });

  test('Genius block checks each transaction against actual remaining gas', () {
    expect(geniusOuterWalletLimit, 200);
    expect(geniusInnerWalletLimit(migrate: true, tip: BigInt.one), 96);
    expect(geniusInnerWalletLimit(migrate: false, tip: BigInt.one), 95);
    expect(geniusInnerWalletLimit(migrate: false, tip: BigInt.zero), 96);
    final wallet = TradeWallet.import('fixture', '1'.padLeft(64, '0'));
    List<LaunchTx> buys(int count) => List.generate(
      count,
      (_) =>
          LaunchTx('buy', wallet, null, Uint8List(0), BigInt.zero, 200000)
            ..simulatedGasUsed = 100000,
    );
    final txs = buys(297);
    checkLaunchBlockCapacity(txs, BigInt.from(29800000));
    expect(
      () => checkLaunchBlockCapacity(txs, BigInt.from(29799999)),
      throwsStateError,
    );
    txs.first.simulatedGasUsed = null;
    expect(
      () => checkLaunchBlockCapacity(txs, BigInt.from(60000000)),
      throwsStateError,
    );
  });

  testWidgets('six-decimal pool token keeps the last atomic unit at MAX', (
    tester,
  ) async {
    final selected = <String, String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('分配'),
              onPressed: () async {
                final result = await showDialog<Map<String, String>>(
                  context: context,
                  builder: (_) => LaunchAllocationDialog(
                    title: '外盘',
                    decimals: 6,
                    symbol: 'UUSD',
                    rows: [
                      (
                        address: '0x${'1'.padLeft(40, '0')}',
                        maximum: BigInt.from(1000001),
                        amount: '',
                      ),
                    ],
                  ),
                );
                if (result != null) selected.addAll(result);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('分配'));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(30);
    await tester.pumpAndSettle();
    expect(find.text('买入 0.3 UUSD'), findsOneWidget);
    await tester.tap(find.text('最大'));
    await tester.pumpAndSettle();
    expect(find.text('买入 1.000001 UUSD'), findsOneWidget);
    await tester.tap(find.text('应用金额'));
    await tester.pumpAndSettle();
    expect(selected.values.single, '1.000001');
  });

  for (final width in [320.0, 390.0, 1440.0]) {
    testWidgets(
      'Genius launch draft applies percentage and individual maximum at ${width}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final api = _Api(),
            keys = [
              for (final n in [1, 2])
                '0x${n.toRadixString(16).padLeft(64, '0')}',
            ];
        final state = AppState(api, MemoryKeyStore());
        addTearDown(() {
          state.dispose();
          api.http_.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: LaunchPage(
                state: state,
                selectedPlatform: 2,
                onTrade: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> tap(Finder f) async {
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          await tester.pumpAndSettle();
        }

        Finder editor() => find
            .descendant(
              of: find.byType(KeyEditorPage),
              matching: find.byType(TextField),
            )
            .first;
        final group = find.textContaining(RegExp('内盘.* · [02]'));
        await tap(group);
        await tester.enterText(editor(), keys.join('\n'));
        await tap(find.text('保存').first);
        await tap(find.text('按余额分配'));
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(30);
        await tester.pumpAndSettle();
        expect(find.text('买入 0.2985 BNB'), findsOneWidget);
        expect(find.text('买入 0.5985 BNB'), findsOneWidget);
        await tap(find.text('最大').last);
        expect(find.text('买入 1.995 BNB'), findsOneWidget);
        await tap(find.text('应用金额'));
        await tap(group);
        expect(
          tester.widget<TextField>(editor()).controller!.text,
          '${keys[0]} 0.2985\n${keys[1]} 1.995',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
