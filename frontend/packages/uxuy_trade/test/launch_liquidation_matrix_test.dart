import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/shell.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';
import 'support/inner_quote.dart';

void main() {
  late FakeBackend node;
  late FourLauncher launcher;
  late List<TradeWallet> wallets;

  setUp(() {
    node = FakeBackend()..settleLiquidations = true;
    wallets = [
      for (var i = 1; i <= 3; i++)
        TradeWallet.import('Test $i', i.toRadixString(16).padLeft(64, '0')),
    ];
    for (var i = 0; i < wallets.length; i++) {
      node.wallets[wallets[i].address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': i + 1,
        'tokenBalance': (i * 1000).toString(),
        'routerAllowance': '1000000',
      };
    }
    launcher = FourLauncher(node.api(), ExecutionLog(), sleep: (_) async {})
      ..session = LaunchSession(
        platform: 'four',
        token: token,
        symbol: 'TEST',
        dev: wallets.first,
        wallets: wallets,
      )
      ..state = LaunchState.launched;
    addTearDown(launcher.dispose);
  });

  for (final width in [1280.0, 390.0]) {
    testWidgets('workspace liquidation follows the current token across launchpads at $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(node.api(), MemoryKeyStore());
      addTearDown(state.dispose);
      node.tokenMetadata[token] = {'token': token, 'name': 'CAKE', 'symbol': 'CAKE', 'decimals': 18};
      const uusd = '0x61a10e8556bed032ea176330e7f17d6a12a10000';
      state.flap
        ..session = LaunchSession(platform: 'flap', token: token, symbol: 'FLAP',
          dev: wallets.first, wallets: wallets, poolToken: uusd, poolSymbol: 'UUSD',
          tip: BigInt.parse('4000000000000000'))
        ..state = LaunchState.launched;
      state.token = const TokenMeta(pool, 'OTHER', 'OTHER', 18);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData.light()),
        home: HomePage(state: state),
      ));
      await tester.pumpAndSettle();
      Future<void> navigate(String name) async {
        await tester.tap(find.text(name).last);
        await tester.pumpAndSettle();
      }
      await navigate('批量买卖');
      final action = find.text('一键清仓');
      expect(action, findsNothing);
      await state.loadToken(token);
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      expect(find.descendant(of: sidebar, matching: action), width >= 1000 ? findsOneWidget : findsNothing);
      final selector = find.byWidgetPredicate((w) => w is UiSelect<bool> && w.semanticLabel == '清仓到账币种');
      expect(tester.widget<UiSelect<bool>>(selector).options, [(false, 'BNB'), (true, 'UUSD')]);
      expect(node.calls, isNot(contains('tokens/$uusd')));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      final dialog = find.byType(UiDialog);
      expect(find.descendant(of: dialog, matching: find.text('Flap · BSC · FLAP')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text(token)), findsOneWidget);
      final tip = find.descendant(
        of: dialog,
        matching: find.text('每个捆绑的构建者小费 · 0.004 BNB\n收款地址  $bscBundleTipRecipient'),
      );
      expect(tip, findsOneWidget);
      expect(tester.getRect(dialog).contains(tester.getCenter(tip)), isTrue);
      await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
      await tester.pumpAndSettle();
      expect(node.bundles, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    for (final language in ['en', 'zh']) {
      testWidgets(
        'liquidation minimum in the $language confirmation at $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final state = AppState(node.api(), MemoryKeyStore());
          addTearDown(state.dispose);
          final choosePool = (width == 390 && language == 'en') || (width == 1280 && language == 'zh');
          if (choosePool) {
            node.tokenMetadata[pool] = {
              'token': pool, 'symbol': 'USDX', 'name': 'USDX', 'decimals': 6,
            };
          }
          state.four
            ..session = choosePool
                ? LaunchSession(platform: 'four', token: token, symbol: 'TEST',
                    dev: wallets.first, wallets: wallets, poolToken: pool)
                : launcher.session
            ..state = LaunchState.launched;
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('en'), Locale('zh')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: uxuyTheme(ThemeData.light()),
              home: Scaffold(
                body: LaunchPage(
                  state: state,
                  selectedPlatform: 0,
                  onTrade: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final chinese = language == 'zh';
          if (choosePool) {
            final asset = find.byWidgetPredicate((w) =>
                w is UiSelect<bool> && w.semanticLabel == (chinese ? '清仓到账币种' : 'Liquidation proceeds'));
            await tester.ensureVisible(asset);
            await tester.pumpAndSettle();
            await tester.tap(asset);
            await tester.pumpAndSettle();
            await tester.tap(find.text('USDX').last);
            await tester.pumpAndSettle();
          }
          final unit = choosePool ? 'USDX' : 'BNB';
          final action = find.text(chinese ? '一键清仓' : 'Liquidate all');
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          await tester.tap(action);
          await tester.pumpAndSettle();
          final dialog = find.byType(UiDialog);
          expect(dialog, findsOneWidget);
          expect(find.descendant(of: dialog, matching: find.textContaining(bscBundleTipRecipient)), findsNothing);
          expect(find.descendant(of: dialog, matching: find.textContaining(chinese ? '构建者小费' : 'Builder tip')), findsNothing);
          final minimum = find.descendant(
            of: dialog,
            matching: find.textContaining(
              chinese
                  ? '每个钱包的最低到账 $unit 数量由其卖出报价确定'
                  : 'the minimum $unit amount in that wallet’s sale quote',
            ),
          );
          expect(minimum, findsOneWidget);
          if (choosePool) {
            expect(find.descendant(of: dialog, matching: find.text(pool)), findsOneWidget);
            expect(find.textContaining('0.001 USDX'), findsOneWidget);
          }
          expect(
            tester.getRect(dialog).contains(tester.getCenter(minimum)),
            isTrue,
          );
          expect(
            find.descendant(
              of: dialog,
              matching: find.textContaining(
                chinese ? '预计到账' : 'Expected to receive',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: dialog,
              matching: find.textContaining(chinese ? '价格影响' : 'Price impact'),
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.descendant(
              of: dialog,
              matching: find.text(chinese ? '取消' : 'Cancel'),
            ),
          );
          await tester.pumpAndSettle();
          expect(node.bundles, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  test('unknown pool symbol retries on the next lookup and verifies the address', () async {
    final session = LaunchSession(platform: 'genius', token: token, symbol: 'NEW',
        dev: wallets.first, wallets: wallets, poolToken: pool);
    final api = node.api();
    addTearDown(api.http_.close);
    expect(await session.lookupPoolSymbol(api), isNull);
    node.tokenMetadata[pool] = {'token': token, 'symbol': 'WRONG', 'name': '', 'decimals': 6};
    expect(await session.lookupPoolSymbol(api), isNull);
    node.tokenMetadata[pool] = {'token': pool, 'symbol': 'CUSTOM', 'name': '', 'decimals': 6};
    expect(await session.lookupPoolSymbol(api), 'CUSTOM');
    expect(await session.lookupPoolSymbol(api), 'CUSTOM');
    expect(node.calls.where((path) => path == 'tokens/$pool'), hasLength(3));
  });

  test(
    'liquidation above the configured threshold requires a second confirmation',
    () async {
      node.adverseImpact = 22;
      final preview = await launcher.prepareLiquidation();
      expect(preview.inputTotal, BigInt.from(3000));
      expect(preview.amounts.length, 2);
      expect(preview.impact, 22);
      expect(node.bundleRouteRequests, hasLength(1));
      expect(
        node.bundleRouteRequests.single.every((r) => r['forecastOnly'] == true),
        isTrue,
      );
      await expectLater(
        launcher.liquidate(preview, 20, false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'warning',
            contains('价格影响'),
          ),
        ),
      );
      expect(node.signatures, isEmpty);
      expect(node.bundles, isEmpty);
      final done = await launcher.liquidate(preview, 20, true);
      expect(done.confirmed, 2);
      expect(node.bundles, hasLength(1));
      expect(node.bundleRouteRequests, hasLength(2));
      expect(
        node.bundleRouteRequests.last.every((r) => r['forecastOnly'] != true),
        isTrue,
      );
      for (final rows in node.bundleRouteRequests) {
        expect(rows, hasLength(2));
        expect(
          rows.every((r) => r['side'] == 'sell' && r['token'] == token),
          isTrue,
        );
        expect(
          {
            for (final r in rows)
              (r['wallet'] as String).toLowerCase(): r['amount'],
          },
          {
            wallets[1].address.toLowerCase(): '1000',
            wallets[2].address.toLowerCase(): '2000',
          },
        );
      }
      expect(node.calls, isNot(contains('routes')));
      expect(node.calls, isNot(contains('routes/batch')));
      expect(node.signatures.values.map((v) => v.$2).toSet(), {
        for (final w in wallets.skip(1)) w.address.toLowerCase(),
      });
      await expectLater(
        launcher.liquidate(preview, 20, true),
        throwsStateError,
      );
      expect(node.bundles, hasLength(1));
    },
  );

  for (final residual in [0, 1]) {
    test(
      'confirmed liquidation rereads all $residual residual units before releasing session',
      () async {
        final preview = await launcher.prepareLiquidation();
        node.afterSubmit = () {
          for (final row in node.wallets.values) {
            row['tokenBalance'] = '0';
          }
          node.wallets[wallets.last.address.toLowerCase()]!['tokenBalance'] =
              '$residual';
        };
        final done = await launcher.liquidate(preview, 20, false);
        expect(done.confirmed, 2);
        expect(launcher.session == null, residual == 0);
        expect(
          launcher.state,
          residual == 0 ? LaunchState.idle : LaunchState.launched,
        );
      },
    );
  }
  test('liquidation exactly at the configured threshold can execute', () async {
    node.adverseImpact = 15;
    final preview = await launcher.prepareLiquidation();
    expect(preview.impact, 15);
    final done = await launcher.liquidate(preview, 15, false);
    expect(done.confirmed, 2);
    expect(node.bundles, hasLength(1));
  });

  test('zero warning threshold executes only after the required confirmation', () async {
    final preview = await launcher.prepareLiquidation();
    await expectLater(launcher.liquidate(preview, 0), throwsStateError);
    expect(node.bundles, isEmpty);
    expect((await launcher.liquidate(preview, 0, true)).confirmed, 2);
  });

  test('liquidation retains token-scoped group participants and refuses stale holders or amounts', () async {
    final other = TradeWallet.import('later', 'f'.padLeft(64,'0'));
    node.wallets[other.address.toLowerCase()] = {'native':'1000000000000000000','nonce':0,'tokenBalance':'777','routerAllowance':'1000'};
    launcher.recordTradeParticipant(pool, other);
    final old = await launcher.prepareLiquidation();
    expect(old.amounts.containsKey(other.address.toLowerCase()), false);
    launcher.recordTradeParticipant(token, other);
    launcher.recordTradeParticipant(token, other);
    await expectLater(launcher.liquidate(old, 20), throwsStateError);
    final now = await launcher.prepareLiquidation();
    expect(now.amounts[other.address.toLowerCase()], BigInt.from(777));
    node.wallets[other.address.toLowerCase()]!['tokenBalance'] = '999';
    await expectLater(launcher.liquidate(now, 20), throwsStateError);
    expect(node.submitted,isEmpty);
    final confirmed = await launcher.prepareLiquidation();
    expect(confirmed.amounts.length,3);
    expect((await launcher.liquidate(confirmed)).confirmed,3);
    expect(launcher.session,isNull);
    launcher.recordTradeParticipant(token,other);
    expect(launcher.session!.liquidationWallets.length,4);
    launcher.reset();
    launcher.recordTradeParticipant(token,other);
    expect(launcher.session,isNull);
  });

  for (final rapid in [false, true]) {
    test('confirmed ${rapid ? "rapid" : "ordinary"} trader remains in this token’s liquidation after deleting its group', () async {
      final state = AppState(node.api(),MemoryKeyStore())
        ..token = const TokenMeta(token, 'Token', 'TEST', 18);
      addTearDown(state.dispose);
      state.four..session=launcher.session..state=LaunchState.launched;
      final buying = TradeWallet.import('new buyer', '42'.padLeft(64,'0'));
      node.wallets[buying.address.toLowerCase()]={'native':'1000000000000000000','nonce':0,'tokenBalance':'0','routerAllowance':'2000'};
      final group=rapid ? state.addRapidGroup() : state.addGroup();
      group.wallets=[buying];
      group.selected.add(buying.address);
      node.afterSubmit=(){node.wallets[buying.address.toLowerCase()]!['tokenBalance']='1234';};
      if(group is RapidGroup){
        group.total='1';
        group.interval='0';
        final checked=await state.prepareRapid(group);
        await state.startRapid(group,checked);
        await state.query(group);
      }else{
        final checked=await state.prepare(group);
        expect(state.four.session!.liquidationWallets.contains(buying),isFalse);
        await state.start(group,prepared:checked);
      }
      expect(node.bundles,isNotEmpty);
      state.removeGroup(group);
      final clear=await state.four.prepareLiquidation();
      expect(clear.amounts[buying.address.toLowerCase()],BigInt.from(1234));
    });
  }

  for (final underpaid in [false,true]){
    test('sell to the selected six-decimal collateral and verify wallet receipt, underpaid=$underpaid', () async {
      node.tokenMetadata[pool]={'token':pool,'symbol':'USDX','name':'USDX','decimals':6};
      launcher.session=LaunchSession(platform:'four',token:token,symbol:'TEST',dev:wallets.first,wallets:wallets,poolToken:pool);
      launcher.selectLiquidationOutput(true);
      final preview = await launcher.prepareLiquidation();
      expect(launcher.liquidationSettlement!.decimals,6);
      expect(node.bundleRouteRequests.single.every((r)=>r['settlementToken']==pool),true);
      if(underpaid){
        node.actualLiquidationOutput=BigInt.one;
        await expectLater(launcher.liquidate(preview),throwsStateError);
        expect(launcher.pendingLiquidation,true);
        await expectLater(launcher.prepareLiquidation(),throwsStateError);
        expect(node.bundles.length,1);
      }else{
        final done=await launcher.liquidate(preview);
        expect(done.settlementReceived,BigInt.from(2000));
        expect(done.nativeReceived,BigInt.zero);
        expect(done.unverifiedSettlement,isEmpty);
        expect(node.bundleRouteRequests.last.every((r)=>r['settlementToken']==pool),true);
      }
    });
  }

  for (final platform in ['four', 'flap', 'genius']) {
    test(
      '$platform signs the official inner sale for each funded liquidation wallet',
      () async {
        final trader = BatchTrader(node.api(), ExecutionLog());
        final scale = BigInt.from(10).pow(18);
        for (var i=0; i<wallets.length; i++) {
          final row = node.wallets[wallets[i].address.toLowerCase()]!;
          row['tokenBalance'] = '${BigInt.from(i*1000)*scale}';
          row['routerAllowance'] = row['tokenBalance']!;
        }
        final market = innerMarket(platform);
        node.innerQuote = (r) => innerQuote(market,r);
        final plan = TradePlan(
          token: token,
          wallets: wallets,
          market: market,
          buy: false,
          mode: SendMode.bundle,
          amount: AmountRule(
            ratio: true,
            min: BigInt.from(10000),
            max: BigInt.from(10000),
          ),
        );
        final preview = await trader.prepare(plan);
        expect(preview.inputTotal, BigInt.from(3000)*scale);
        final result = await trader.run(plan);
        expect(result.confirmed, 2);
        expect(node.bundleRouteRequests.last.map((row) => row['amount']), [
          '${BigInt.from(1000)*scale}',
          '${BigInt.from(2000)*scale}',
        ]);
        expect(
          node.signatures.values
              .map((signed) => signed.$3.to?.toLowerCase())
              .toSet(),
          {market.innerTarget!.toLowerCase()},
        );
      },
    );
  }

  test(
    'one refused UXUY wallet stops liquidation before signing for any wallet',
    () async {
      node.refuse.add(wallets.last.address.toLowerCase());
      final preview = await launcher.prepareLiquidation();
      final result = await launcher.liquidate(preview, 20, true);
      expect(result.stopped, isTrue);
      expect(node.signatures, isEmpty);
      expect(node.bundles, isEmpty);
    },
  );

  test(
    'restarting the launch session invalidates a liquidation preview',
    () async {
      final preview = await launcher.prepareLiquidation();
      launcher.reset();
      await expectLater(
        launcher.liquidate(preview, 20, true),
        throwsStateError,
      );
      expect(node.bundles, isEmpty);
      expect(node.signatures, isEmpty);
    },
  );
}
