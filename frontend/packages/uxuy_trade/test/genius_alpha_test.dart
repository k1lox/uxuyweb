import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/component_theme.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart' show FakeBackend;

const _token = '0x0000000000000000000000000000000000000022';
String _word(BigInt n) => n.toRadixString(16).padLeft(64, '0');
String _selector(String sig) => bytesToHex(AbiFunction.parse(sig).selector);

class _AlphaBackend extends BackendClient {
  _AlphaBackend()
    : super(Uri.parse('http://fixture.invalid'), FakeBackend().client());
  var price = BigInt.parse('123456789012345678');
  var approved = true;
  final alphaBatchSizes = <int>[];
  List<Map>? simulation;

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    if (calls.first.$1 == 'eth_simulateV1') {
      final payload = calls.single.$2.first as Map;
      simulation =
          ((payload['blockStateCalls'] as List).single['calls'] as List)
              .cast<Map>();
      throw const BackendException('RPC_ERROR', 'method unavailable', false);
    }
    if (calls.any((c) => (c.$2.first as Map)['to'] == geniusAlphaRegistry)) {
      alphaBatchSizes.add(calls.length);
    }
    final policy = List.filled(23, BigInt.zero)..[4] = BigInt.one;
    String words(Iterable<BigInt> values) => '0x${values.map(_word).join()}';
    final replies = {
      _selector('priceWei()'): words([price]),
      _selector('approvedFactories(address)'): words([
        approved ? BigInt.one : BigInt.zero,
      ]),
      _selector('launchFee()'): words([BigInt.zero]),
      _selector('launchEnabled()'): words([BigInt.one]),
      _selector('canLaunch(address)'): words([BigInt.one]),
      _selector('maxCreatorTaxBps()'): words([BigInt.from(500)]),
      _selector('previewLaunchEconomics(uint256,address)'): words([BigInt.one]),
      bytesToHex(geniusPlatformPolicy.selector): words(policy),
      _selector('getLaunchConfig(uint256)'): words([
        BigInt.from(1000000),
        ...List.filled(5, BigInt.zero),
        BigInt.one,
      ]),
      bytesToHex(geniusPreview.selector): words([
        BigInt.parse(_token),
        BigInt.from(2),
        BigInt.one,
      ]),
    };
    return [
      for (final call in calls)
        if ((call.$2.first as Map).containsKey('gas'))
          words([
            BigInt.parse(_token),
            BigInt.from(2),
          ]) // Legacy launch preview.
        else
          replies[(call.$2.first as Map)['data'].toString().substring(0, 10)] ??
              (throw StateError('Unexpected test call ${call.$1}')),
    ];
  }
}

void main() {
  late _AlphaBackend node;
  late GeniusLauncher launcher;
  final wallet = TradeWallet.import('test', '1'.padLeft(64, '0'));

  setUp(() {
    node = _AlphaBackend();
    launcher = GeniusLauncher(node, ExecutionLog());
  });
  tearDown(() {
    launcher.dispose();
    node.http_.close();
  });

  Future<void> launch({bool alpha = true, GeniusAlphaQuote? quote}) =>
      launcher.launch(
        GeniusLaunchForm(
          name: 'Alpha',
          symbol: 'A',
          logo: 'ipfs://a',
          creatorFeeRecipient: wallet.address,
          alpha: alpha,
          confirmedAlpha: quote,
        ),
        dev: LaunchBuyer(wallet, BigInt.zero),
      );

  for (final version in geniusFactories.keys) {
    test(
      '$version simulates official creation and stops signing on unsupported simulation',
      () async {
        await launcher.launch(
          GeniusLaunchForm(
            version: version,
            name: 'Test',
            symbol: 'T',
            logo: 'ipfs://a',
            creatorFeeRecipient: wallet.address,
          ),
          dev: LaunchBuyer(wallet, BigInt.zero),
        );
        expect(launcher.error, contains('连续模拟不可用'));
        expect(launcher.transactions, isEmpty);
        expect(launcher.session, isNull);
        expect(
          node.simulation!.map((tx) => tx['to'].toString().toLowerCase()),
          [geniusFactories[version]!.toLowerCase()],
        );
      },
    );
  }

  test('only explicitly confirmed Alpha produces a promote call for the exact price', () async {
    final quote = await launcher.quoteAlpha(geniusM52);
    expect(quote, (factory: geniusM52Factory, priceWei: node.price));
    await launch(quote: quote);
    final tx = node.simulation!.last;
    expect(tx['to'].toString().toLowerCase(), geniusAlphaRegistry);
    expect(BigInt.parse(tx['value'] as String), quote.priceWei);
    expect(
      AbiFunction.parse('promote(address,address)').decodeInput(tx['data']),
      [checksumAddress(geniusM52Factory), checksumAddress(_token)],
    );
    expect(node.alphaBatchSizes.first, 2);
    expect(node.alphaBatchSizes, hasLength(2));
  });

  for (final change in [-1, 1]) {
    test(
      'a one-wei price change ($change) requires a new confirmation',
      () async {
        final quote = await launcher.quoteAlpha(geniusM52);
        node.price += BigInt.from(change);
        await launch(quote: quote);
        expect(launcher.error, contains('重新准备并确认'));
        expect(node.simulation, isNull);
      },
    );
  }

  test(
    'disabled Alpha does not request or include Alpha even with an old quote',
    () async {
      await launch(
        alpha: false,
        quote: (factory: geniusM52Factory, priceWei: node.price),
      );
      expect(node.alphaBatchSizes, isEmpty);
      expect(node.simulation, hasLength(1));
    },
  );

  test(
    'no consent, wrong factory and revoked approval stop before signing',
    () async {
      await launch();
      expect(launcher.error, contains('重新确认'));
      await launch(
        quote: (factory: geniusFactories['v2']!, priceWei: node.price),
      );
      expect(launcher.error, contains('重新确认'));
      expect(node.alphaBatchSizes, isEmpty);
      final quote = await launcher.quoteAlpha(geniusM52);
      node.approved = false;
      await launch(quote: quote);
      expect(launcher.error, contains('尚未开放 Alpha'));
      expect(node.simulation, isNull);
      await expectLater(launcher.quoteAlpha(geniusM52), throwsStateError);
      node.approved = true;
      node.price = BigInt.zero;
      await expectLater(launcher.quoteAlpha(geniusM52), throwsStateError);
    },
  );

  for (final size in [const Size(390, 844), const Size(1280, 1500)]) {
    testWidgets(
      'confirmation shows the full Alpha amount before any upload or launch at ${size.width} px',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState(node, MemoryKeyStore());
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: componentTheme(uxuyTheme(ThemeData())),
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

        for (final (label, key) in [('Dev 钱包', 1)]) {
          await tap(find.text(label));
          await tester.enterText(
            find.descendant(
              of: find.byType(KeyEditorPage),
              matching: find.byType(TextField),
            ),
            key.toString().padLeft(64, '0'),
          );
          await tap(find.widgetWithText(TextButton, '保存'));
        }
        final row = find
            .ancestor(of: find.text('开通 Alpha'), matching: find.byType(Row))
            .first;
        await tap(find.descendant(of: row, matching: find.byType(Checkbox)));
        await tap(find.text('准备发币'));
        expect(
          find.text('开通 Alpha 费用  0.123456789012345678 BNB'),
          findsOneWidget,
        );
        expect(find.textContaining('发币服务费'), findsNothing);
        expect(node.alphaBatchSizes, [2]);
        await tap(find.widgetWithText(TextButton, '取消'));
        expect(node.simulation, isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
