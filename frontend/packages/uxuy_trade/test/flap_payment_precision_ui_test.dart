import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

const _quote = '0x0000000000000000000000000000000000000001';

// Captures the UI -> execution boundary. Never prepares, signs or submits a transaction.
class _RecordingFlap extends FlapLauncher {
  _RecordingFlap(super.api, super.log);
  List<LaunchBuyer>? buyers;
  FlapLaunchForm? form;

  @override
  Future<FlapCatalogSnapshot> catalogSnapshot({required bool custom}) async => (
    partial: false,
    stale: false,
    refreshError: null,
    tokens: custom
        ? <FlapPayment>[]
        : [
            FlapPayment({
              'address': '0x0000000000000000000000000000000000000000',
              'symbol': 'BNB',
              'decimals': 18,
            }),
            FlapPayment({'address': _quote, 'symbol': 'USDX', 'decimals': 6}),
          ],
  );

  @override
  Future<void> launch(
    FlapLaunchForm form, {
    required LaunchBuyer dev,
    List<LaunchBuyer> internal = const [],
    List<LaunchBuyer> external = const [],
    String? metaOverride,
  }) async {
    form.validate();
    this.form = form;
    buyers = [dev, ...internal, ...external];
  }
}

class _RecordingFour extends FourLauncher {
  _RecordingFour(super.api, super.log);
  FourLaunchForm? form;
  List<LaunchBuyer>? buyers;

  @override
  Future<List<FourRaised>> raisedTokens() async => [
    FourRaised({
      'symbolAddress': _quote,
      'nativeSymbol': 'USDX',
      'totalBAmount': '100',
    }),
  ];

  @override
  Future<void> launch(
    FourLaunchForm form, {
    required LaunchBuyer dev,
    List<LaunchBuyer> internal = const [],
    List<LaunchBuyer> external = const [],
  }) async {
    this.form = form;
    buyers = [dev, ...internal, ...external];
  }
}

class _TestState extends AppState {
  _TestState(super.api, super.store, {super.imagePicker});
  _RecordingFour? _four;
  @override
  _RecordingFour get four => _four ??= _RecordingFour(api, log);
  _RecordingFlap? _recording;
  @override
  _RecordingFlap get flap => _recording ??= _RecordingFlap(api, log);
}

String _testKey(int value) => '0x${value.toRadixString(16).padLeft(64, '0')}';

void main() {
  test('launch paste accepts generated, legacy and per-wallet amount rows', () {
    final a = '0x${'1'.padLeft(64, '0')}';
    final b = '0x${'2'.padLeft(64, '0')}';
    final c = '0x${'3'.padLeft(64, '0')}';
    final oldAddress = TradeWallet.import('legacy', b).address;
    final buyers = parseBuyers('$a\r\n$oldAddress,$b\n$c,0.75', '1', 6);
    expect(buyers.map((x) => x.wallet.exportPrivateKey()), [a, b, c]);
    expect(buyers.map((x) => x.amount), [
      BigInt.from(1000000),
      BigInt.from(1000000),
      BigInt.from(750000),
    ]);
    for (final badRow in ['$a $b', '$a,1,$c', '$a,$b']) {
      expect(() => parseBuyers(badRow, '1', 6), throwsFormatException);
    }
  });
  for (final isFour in [true, false]) {
    testWidgets(
      '${isFour ? 'Four' : 'Flap'} preserves a six-decimal Dev amount from input through confirmation to creation',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final client = MockClient((request) async {
          if (request.url.path == '/api/v1/tokens/$_quote') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'token': {
                  'token': _quote,
                  'name': 'Test',
                  'symbol': 'USDX',
                  'decimals': 6,
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/api/fourmeme');
          return http.Response(
            jsonEncode({
              'ok': true,
              'payload': {'code': 0, 'data': []},
            }),
            200,
          );
        });
        final state = _TestState(
          BackendClient(Uri.parse('http://fixture.invalid/'), client),
          MemoryKeyStore(),
          imagePicker: () async => LaunchImage(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
            'test.png',
            'image/png',
          ),
        );
        addTearDown(() {
          state.dispose();
          client.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: componentTheme(uxuyTheme(ThemeData())),
            home: Scaffold(
              body: LaunchPage(
                state: state,
                selectedPlatform: isFour ? 0 : 1,
                onTrade: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Future<void> tap(Finder target) async {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Finder field(String label, [int index = 0]) {
          final column = find
              .ancestor(
                of: find.text(label).at(index),
                matching: find.byType(Column),
              )
              .first;
          return find
              .descendant(of: column, matching: find.byType(TextField))
              .first;
        }

        Future<void> fill(String label, String value, [int index = 0]) async {
          final target = field(label, index);
          await tester.ensureVisible(target);
          await tester.enterText(target, value);
          await tester.pumpAndSettle();
        }

        Future<void> keys(String label, String value) async {
          await tap(find.text(label));
          await tester.enterText(
            find.descendant(
              of: find.byType(KeyEditorPage),
              matching: find.byType(TextField),
            ),
            value,
          );
          await tap(find.widgetWithText(TextButton, '保存'));
        }

        await fill('名称', 'Precision test');
        await fill('简写', 'TEST');
        await tap(find.text('选择图片'));
        final select = find.byWidgetPredicate(
          (widget) =>
              widget is UiSelect<String> && widget.semanticLabel == '底池代币',
        );
        if (!isFour) {
          await tap(select);
          await tap(find.text('USDX').last);
        }
        await tap(find.text('USDX').last);
        await keys('Dev 钱包', _testKey(101));
        await keys('内盘购买钱包 · 0', '${_testKey(102)},0.111111\n${_testKey(103)}');
        await fill('每个地址', '0.222222');
        expect(find.text('内盘购买钱包 · 2'), findsOneWidget);
        expect(find.text('Dev 首买'), findsOneWidget);
        await fill('贿赂费', '0.00000001');
        if (!isFour) {
          await fill('创作者收款地址（留空使用 Dev）', _quote);
          await fill('防挖提卖保护期', '7');
        }
        await fill('Dev 首买', '0.123456');
        await tap(find.text('准备发币'));
        expect(find.textContaining('0.123456 USDX'), findsOneWidget);
        expect(find.textContaining('内盘 2 个钱包 · 0.333333 USDX'), findsOneWidget);
        expect(find.textContaining('发币服务费'), findsNothing);
        expect(isFour ? state.four.buyers : state.flap.buyers, isNull);
        await tap(find.widgetWithText(TextButton, '继续预检'));
        final buyers = isFour ? state.four.buyers : state.flap.buyers;
        expect(buyers!.map((b) => b.amount), [
          BigInt.from(123456),
          BigInt.from(111111),
          BigInt.from(222222),
        ]);
        final tip = isFour ? state.four.form!.tip : state.flap.form!.tip;
        expect(tip, BigInt.from(10000000000));
        if (!isFour) {
          expect(state.flap.form!.payment.address, _quote);
          expect(state.flap.form!.beneficiary, _quote);
          expect(state.flap.form!.antiFarmerDays, 7);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
