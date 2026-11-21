import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/ui/launch_budget.dart';
import 'package:uxuy_trade/src/ui/theme.dart';

const quote = '0x0000000000000000000000000000000000000010';
const router = '0x0000000000000000000000000000000000000020';
const pool = '0x0000000000000000000000000000000000000030';
const other = '0x0000000000000000000000000000000000000040';

class _Market extends Fake implements BackendClient {
  final queries = <RouteRequestData>[];
  final blocks = <String>[];
  bool badWallet = false;
  final devReads = <String?>[];
  Completer<List<WalletState>>? pendingDev;
  String metadataAddress = quote;
  int? metadataDecimals = 6;

  @override
  Future<List<WalletState>> transferPreviewStates(
    List<String> wallets, {
    String? token,
  }) async {
    devReads.add(token);
    if (pendingDev case final pending?) return pending.future;
    return [
      WalletState(
        badWallet ? pool : wallets.single,
        parseUnits('0.75', 18),
        0,
        token == null ? null : BigInt.from(1234567),
        null,
      ),
    ];
  }

  @override
  Future<ModuleConfig> config() async => const ModuleConfig(
    router: router,
    approvalSpender: router,
    maxImpact: 10,
    routeEnabled: true,
  );
  @override
  Future<TokenMeta> token(String address) async =>
      TokenMeta(metadataAddress, 'USD', 'USD', metadataDecimals);
  @override
  Future<RoutePlan> route(RouteRequestData r) async {
    queries.add(r);
    final output = r.buy ? BigInt.from(10000000) : parseUnits('0.99', 18);
    return RoutePlan(
      wallet: badWallet ? pool : r.wallet,
      to: router,
      data: '0x',
      value: r.buy ? r.amount : BigInt.zero,
      pools: const [pool],
      dexes: const ['DEX'],
      quoteOut: output,
      minOut: output,
      chainId: 56,
      simulation: 'forecast',
      executed: false,
      spender: router,
      slippagePpm: 5000,
      priceImpact: 0.03,
      deadline: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 45,
      quoteScope: 'wallet',
      token: quote,
      buy: r.buy,
      amount: r.amount,
    );
  }

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async => [
    '0x18',
  ];
  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    blocks.add(block);
    String words(List<String> types, List<Object?> values) =>
        bytesToHex(encodeSequence(types.map(AbiType.parse).toList(), values));
    if (data == AbiFunction.parse('token0()').encodeHex([]))
      return words(['address'], [other]);
    if (data == AbiFunction.parse('token1()').encodeHex([]))
      return words(['address'], [quote]);
    if (data == AbiFunction.parse('getReserves()').encodeHex([]))
      return words(
        ['uint112', 'uint112', 'uint32'],
        [parseUnits('90', 18), parseUnits('900', 6), BigInt.one],
      );
    if (data == AbiFunction.parse('decimals()').encodeHex([]))
      return words(
        ['uint8'],
        [BigInt.from(to.toLowerCase() == quote ? 6 : 18)],
      );
    if (data == AbiFunction.parse('symbol()').encodeHex([]))
      return words(['string'], [to.toLowerCase() == quote ? 'USD' : 'WBNB']);
    throw StateError('selector');
  }
}

void main() {
  test('payment metadata belongs to the selected pool and uses a supported precision', () async {
    final api = _Market();
    expect((await launchPaymentMeta(api, quote)).decimals, 6);
    api.metadataAddress = other;
    await expectLater(launchPaymentMeta(api, quote), throwsStateError);
    api.metadataAddress = quote;
    for (final value in [null, -1, 37]) {
      api.metadataDecimals = value;
      await expectLater(launchPaymentMeta(api, quote), throwsStateError);
    }
  });
  testWidgets(
    'Dev wallet snapshot follows active payer and currency, rejects a misbound response and retries',
    (tester) async {
      final api = _Market();
      Future<void> show(String owner, String? token) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LaunchDevBalance(
                api: api,
                address: owner,
                paymentToken: token,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }

      final delayed = Completer<List<WalletState>>();
      api.pendingDev = delayed;
      await show(pool, null);
      api.pendingDev = null;
      await show(other, quote);
      expect(find.text('Dev 余额  1.234567 USD · 0.75 BNB'), findsOneWidget);
      delayed.complete([WalletState(pool, parseUnits('5', 18), 0, null, null)]);
      await tester.pump();
      expect(find.text('Dev 余额  5 BNB'), findsNothing);
      api.badWallet = true;
      await show(other, null);
      expect(find.textContaining('Dev 余额读取失败'), findsOneWidget);
      expect(find.textContaining('1.234567 USD'), findsNothing);
      api.badWallet = false;
      await tester.tap(find.byTooltip('刷新 Dev 余额'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Dev 余额  0.75 BNB'), findsOneWidget);
      expect(api.devReads, [null, quote, null, null]);
    },
  );
  test(
    'launch gas adds half a Gwei through the inclusive 100 Gwei ceiling',
    () {
      expect(
        launchBundleGasPrice(BigInt.from(99500000000)),
        BigInt.from(100000000000),
      );
      expect(
        () => launchBundleGasPrice(BigInt.from(99500000001)),
        throwsStateError,
      );
      expect(() => launchBundleGasPrice(-BigInt.one), throwsStateError);
    },
  );
  test(
    'Dev plus unique inner wallets honors defaults and per-wallet overrides',
    () {
      final a = '1'.padLeft(64, '0'), b = '2'.padLeft(64, '0');
      expect(launchInnerAmounts('0.5', '$a\n0x$a,9\n$b,2.75', '1'), [
        '0.5',
        '1',
        '2.75',
      ]);
    },
  );
  test(
    'both directions use forecasts and real reserves use a common block',
    () async {
      final api = _Market(),
          q = await readLaunchLiquidity(api, quote, parseUnits('1', 18), null);
      expect(api.queries.map((r) => r.buy), [true, false]);
      expect(api.queries.map((r) => r.forecastOnly), [true, true]);
      expect(api.queries.last.amount, q.bought);
      expect(q.pools.join(' '), contains('90 WBNB / 900 USD'));
      expect(api.blocks.toSet(), {'0x18'});
      api.badWallet = true;
      await expectLater(
        readLaunchLiquidity(api, quote, BigInt.one, null),
        throwsA(isA<BackendException>()),
      );
    },
  );
  for (final width in [1440.0, 390.0, 320.0]) {
    testWidgets(
      'expanded graduation and liquidity reads fit $width with synthetic wallets',
      (tester) async {
        final snapshot = Platform.environment['UXUY_CAPTURE_LAUNCH_PANEL_DIR'];
        final style = ThemeData(
          fontFamily: snapshot == null ? null : 'FixtureCjk',
        );
        if (snapshot != null) {
          await tester.runAsync(() async {
            final sdk = Platform.environment['FLUTTER_ROOT']!;
            final fonts = {
              'FixtureCjk': File('../../web/assets/fonts/NotoSansSC.ttf'),
              'MaterialIcons': File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'),
            };
            for (final entry in fonts.entries) {
              final loader = FontLoader(entry.key)
                ..addFont(entry.value.readAsBytes().then(ByteData.sublistView));
              await loader.load();
            }
          });
        }
        tester.view.physicalSize = Size(width, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        final keys =
            '1'.padLeft(64, '0') + ',0.125\n' + '2'.padLeft(64, '0') + ',0.25';
        await tester.pumpWidget(
          MaterialApp(
            theme: uxuyTheme(style),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width >= 900 ? 460 : width,
                  child: SingleChildScrollView(
                    child: RepaintBoundary(
                      key: boundary,
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: LaunchBudgetPanel(
                            api: _Market(),
                            selection: 1,
                            readTarget: () async => (
                              amount: parseUnits('15200', 6),
                              decimals: 6,
                              symbol: 'USD',
                            ),
                            amounts: launchInnerAmounts('1.5', keys, ''),
                            payBnb: true,
                            unit: 'BNB',
                            pool: quote,
                            dev: other,
                            paymentDecimals: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.tap(find.text('BNB 与底池币兑换预览'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 420));
        await tester.pumpAndSettle();
        expect(find.text('首买 1.875 BNB'), findsOneWidget);
        expect(find.text('目标 15200 USD'), findsOneWidget);
        expect(find.text('计算依据'), findsNothing);
        expect(find.textContaining('按市场预估距目标'), findsOneWidget);
        expect(find.textContaining(pool), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final f in [
          find.text('首买 1.875 BNB'),
          find.textContaining(pool),
        ]) {
          final rect = tester.getRect(f);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        final address = tester.widget<SelectableText>(
          find.byWidgetPredicate((w) => w is SelectableText && w.data == pool),
        );
        expect(address.maxLines, isNull);
        if (snapshot != null)
          await tester.runAsync(() async {
            final box =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await box.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$snapshot/budget-${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'budget amounts share the row and currency, wrapping on narrow cards',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Use the web font; Flutter's square test glyphs double the width of digits.
      await tester.runAsync(() async {
        final font = FontLoader('UXUYBudgetFixture')
          ..addFont(Future.value(ByteData.sublistView(
            File('../../web/assets/fonts/NotoSansSC.ttf').readAsBytesSync(),
          )));
        await font.load();
      });
      for (final (width, target, shown, singleLine) in [
        (815.0, '16.708182001', '≈16.708182', true),
        (445.0, '16.708182001', '≈16.71', true),
        (400.0, '16.708182001', '≈16.71', true),
        (340.0, '15', '15', true),
        (322.0, '15', '15', true),
        (216.0, '15', '15', false),
        (340.0, '1234567890123456', '≈1.23×10^15', false),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: uxuyTheme(ThemeData(fontFamily: 'UXUYBudgetFixture')),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: LaunchBudgetPanel(
                    api: _Market(),
                    selection: target,
                    readTarget: () async => (
                      amount: parseUnits(target, 18),
                      decimals: 18,
                      symbol: 'BNB',
                    ),
                    amounts: const ['0'],
                    payBnb: true,
                    unit: 'BNB',
                    pool: null,
                    dev: null,
                    paymentDecimals: 18,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 351));
        await tester.pump();
        final title = tester.getRect(find.text('开外盘预算'));
        for (final metric in ['首买 0', '目标 $shown', '还差 $shown BNB']) {
          final rect = tester.getRect(find.text(metric));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          if (singleLine) expect(rect.center.dy, closeTo(title.center.dy, 2), reason: '$width / $metric');
        }
        final refresh = tester.getRect(find.byTooltip('刷新内盘预算'));
        expect(refresh.right, lessThanOrEqualTo(width));
        if (singleLine)
          expect(refresh.center.dy, closeTo(title.center.dy, 2));
        expect(find.byTooltip('计划内盘首买 0 BNB'), findsOneWidget);
        expect(find.byTooltip('迁移目标 $target BNB'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'budget retries a failed read and exposes exact abbreviated amounts',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LaunchBudgetPanel(
              api: _Market(),
              selection: 1,
              readTarget: () async {
                if (++attempts == 1) throw StateError('测试读取失败');
                return (
                  amount: parseUnits('0.000000001', 18),
                  decimals: 18,
                  symbol: 'BNB',
                );
              },
              amounts: const ['0'],
              payBnb: true,
              unit: 'BNB',
              pool: null,
              dev: null,
              paymentDecimals: 18,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pump();
      expect(find.text('目标读取失败'), findsOneWidget);
      expect(find.textContaining('测试读取失败'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新内盘预算'));
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pump();
      expect(attempts, 2);
      expect(find.text('还差 < 0.000001 BNB'), findsOneWidget);
      expect(find.byTooltip('距迁移目标还差 0.000000001 BNB'), findsOneWidget);
    },
  );

  testWidgets(
    'changes to inner amounts are immediate and a stale graduation read is ignored',
    (tester) async {
      final first = Completer<LaunchTarget>();
      Widget panel(int id, List<String> amounts) => MaterialApp(
        home: Scaffold(
          body: LaunchBudgetPanel(
            api: _Market(),
            selection: id,
            readTarget: () => id == 1
                ? first.future
                : Future.value((
                    amount: BigInt.from(9000000),
                    decimals: 6,
                    symbol: 'USD',
                  )),
            amounts: amounts,
            payBnb: false,
            unit: 'USD',
            pool: null,
            dev: null,
            paymentDecimals: 6,
          ),
        ),
      );
      await tester.pumpWidget(panel(1, ['1', '2.5']));
      expect(find.text('首买 3.5 USD'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pumpWidget(panel(2, ['1', '4.5']));
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pump();
      expect(find.text('还差 3.5 USD'), findsOneWidget);
      first.complete((amount: BigInt.one, decimals: 0, symbol: 'OLD'));
      await tester.pump();
      expect(find.textContaining('OLD'), findsNothing);
    },
  );
}
