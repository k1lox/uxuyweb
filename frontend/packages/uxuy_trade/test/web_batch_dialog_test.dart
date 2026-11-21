import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/impact_settings.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

String _key(int n) => '0x${n.toRadixString(16).padLeft(64, '0')}';

void main() {
  late FakeBackend backend;
  late AppState state;

  setUp(() {
    backend = FakeBackend();
    state = AppState(
      backend.api(),
      MemoryKeyStore(),
    )..token = const TokenMeta(token, 'PancakeSwap Token', 'CAKE', 18);
  });
  tearDown(() => state.dispose());

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    double width = 1440,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.init();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData(useMaterial3: true)),
        home: Scaffold(
          body: ListenableBuilder(listenable: state, builder: (_, _) => child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<TradeGroup> addFundedGroup(int n) async {
    final w = TradeWallet.import('Test $n', _key(n));
    backend.wallets[w.address.toLowerCase()] = {
      'native': '1000000000000000000',
      'nonce': 1,
      'tokenBalance': '1000000000000000000',
      'routerAllowance': '0',
    };
    final g = state.addGroup();
    await state.setKeys(g, _key(n));
    return g;
  }

  for (final width in [1440.0, 390.0]) {
    testWidgets(
      'group picker $width: dismissal, ordinary and linked results are distinct',
      (tester) async {
        await mount(tester, BatchPage(state: state), width: width);
        await tap(tester, find.text('新建组'));
        expect(find.byType(UiDialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(state.groups, isEmpty);
        await tap(tester, find.text('新建组'));
        await tap(tester, find.text('普通组'));
        expect(state.groups.single, isA<TradeGroup>());
        await tap(tester, find.text('新建组'));
        await tap(tester, find.text('关联组'));
        expect(state.groups, hasLength(2));
        expect(state.groups.last, isA<LinkedGroup>());
        expect(tester.takeException(), isNull);
        expect(backend.submitted, isEmpty);
      },
    );
  }

  testWidgets(
    'price limit keeps invalid text inline and commits only a valid confirmation',
    (tester) async {
      state.addGroup();
      await mount(tester, BatchPage(state: state), width: 390);
      final line = find.widgetWithText(TextButton, '价格影响设置');
      expect(find.text('价格影响设置'), findsOneWidget);
      expect(find.textContaining('服务费'), findsNothing);
      await tap(tester, line);
      final field = find
          .descendant(
            of: find.byType(UiDialog),
            matching: find.byType(TextField),
          )
          .first;
      for (final value in ['-1', '101', 'invalid', 'NaN', 'Infinity']) {
        await tester.enterText(field, value);
        await tap(tester, find.text('确认'));
        expect(find.byType(UiDialog), findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, value);
        expect(find.text('价格影响上限需在 0–100% 之间'), findsOneWidget);
        expect(state.impactSettings.bundle, 20);
      }
      await tap(tester, find.text('取消'));
      expect(state.impactSettings.bundle, 20);
      await tap(tester, line);
      expect(tester.widget<TextField>(field).controller!.text, '20');
      await tester.enterText(field, '12.5');
      await tap(tester, find.text('确认'));
      expect(state.impactSettings.bundle, 12.5);
      expect(state.impactSettings.intervalStart, 10);
      expect(state.impactSettings.intervalLive, 20);
      expect(find.byType(UiDialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(backend.submitted, isEmpty);
    },
  );

  testWidgets(
    'interval warning requires explicit fresh confirmation, cancel signs nothing',
    (tester) async {
      backend.adverseImpact = 14.25;
      final group = await addFundedGroup(64);
      await mount(tester, BatchPage(state: state));
      await tap(tester, find.text('开始执行'));
      final handle = state.operationHandle(group);
      final review = state.preparedImpact(group)!;
      expect(review.threshold, 10);
      expect(review.ceiling(true), 20);
      await expectLater(state.start(group), throwsStateError);
      await tap(tester, find.text('确认执行'));
      expect(find.text('确认价格影响风险'), findsOneWidget);
      expect(backend.submitted, isEmpty);
      await tap(tester, find.text('取消'));
      expect(state.operationHandle(group), isNull);
      expect(handle, isNotNull);
      expect(backend.submitted, isEmpty);
      expect(backend.bundles, isEmpty);
    },
  );

  test('impact boundaries use strict greater-than and interval execution has its own cap', () {
    const settings = ImpactSettings();
    expect(
      const ImpactReview(SendMode.bundle, 20, settings).needsConfirmation,
      isFalse,
    );
    expect(
      const ImpactReview(SendMode.interval, 10, settings).needsConfirmation,
      isFalse,
    );
    final bundle = const ImpactReview(SendMode.bundle, 20.01, settings);
    expect(() => bundle.ceiling(false), throwsStateError);
    expect(bundle.ceiling(true), 20.01);
    final interval = const ImpactReview(SendMode.interval, 31, settings);
    expect(interval.ceiling(true), 20);
    expect(
      const ImpactReview(SendMode.bundle, null, settings).needsConfirmation,
      isTrue,
    );
  });

  testWidgets('zero thresholds apply only after a verified save, also on unchanged resave', (tester) async {
    var deny=true, attempts=0;
    final settingsState = AppState(backend.api(),MemoryKeyStore(),persistImpactSettings: (_) {
      attempts++;
      if(deny) throw StateError('设置回读失败');
    });
    addTearDown(settingsState.dispose);
    await mount(tester,Builder(builder:(context)=>TextButton(
      onPressed:()=>editImpactSettings(context,settingsState), child:const Text('编辑阈值'),
    )));
    await tap(tester,find.text('编辑阈值'));
    for(var i=0;i<3;i++){await tester.enterText(find.byType(TextField).at(i),'0');}
    await tap(tester, find.text('确认'));
    expect(find.textContaining('设置回读失败'),findsOneWidget);
    expect(settingsState.impactSettings.bundle,20);
    deny=false;
    await tap(tester,find.text('确认'));
    expect(settingsState.impactSettings.intervalLive,0);
    await tap(tester,find.text('编辑阈值'));
    expect(tester.widgetList<TextField>(find.byType(TextField)).map((w)=>w.controller!.text),['0','0','0']);
    await tap(tester,find.text('确认'));
    expect(attempts,3);
    expect(backend.bundles,isEmpty);
  });

  testWidgets('high bundle impact sends only after the second approval', (
    tester,
  ) async {
    backend.adverseImpact = 28;
    final group = await addFundedGroup(65);
    group.update((g) => g.mode = SendMode.bundle);
    await mount(tester, BatchPage(state: state));
    await tap(tester, find.text('开始执行'));
    expect(backend.bundles, isEmpty);
    await tap(tester, find.text('确认执行'));
    expect(find.text('确认价格影响风险'), findsOneWidget);
    expect(backend.bundles, isEmpty);
    await tap(tester, find.text('确认风险并继续'));
    expect(backend.bundles.length, 1);
    expect(state.operationHandle(group), isNull);
  });

  for (final buy in [false, true]) {
    testWidgets('six-wallet interval preview checks every wallet and presents the first ${buy ? 'buy' : 'sell'}', (tester) async {
      final group = await addFundedGroup(70);
      final first = group.wallets.first.address.toLowerCase();
      final keys = [for (var i = 70; i < 76; i++) _key(i)];
      for (final key in keys.skip(1)) {
        final address = TradeWallet.import('Fixture', key).address.toLowerCase();
        backend.wallets[address] = Map.of(backend.wallets[first]!);
      }
      await state.setKeys(group, keys.join('\n'));
      group.setBuy(buy);
      backend.adverseImpact = 12;
      await mount(tester, BatchPage(state: state), width: buy ? 390 : 1440);
      await tap(tester, find.text(buy?'开始执行':'检查授权'));

      expect(backend.calls.where((p) => {'routes', 'routes/batch', 'routes/bundle'}.contains(p)), ['routes/batch']);
      expect(backend.routeBodies.where((r) => r['forecastOnly'] == true).map((r) => r['wallet'].toLowerCase()), group.wallets.map((w) => w.address.toLowerCase()));
      final preview = backend.routeBodies.first;
      expect(preview['forecastOnly'], true);
      expect((preview['wallet'] as String).toLowerCase(), first);
      expect(find.text(buy ? '本轮计划支付' : '本轮卖出'), findsOneWidget);
      expect(find.text('首笔交易'), findsOneWidget);
      expect(find.text('首笔预计到账'), findsOneWidget);
      expect(find.text('钱包中最大价格影响'), findsOneWidget);
      await tap(tester, find.text('确认执行'));
      expect(find.textContaining('最大单笔预计价格影响'), findsOneWidget);
      await tap(tester, find.text('取消'));
      if (buy) {
        expect(backend.bundles, isEmpty);
      } else {
        final onlyApprovals = backend.bundles.single;
        expect(onlyApprovals, hasLength(6));
        for (final raw in onlyApprovals) {
          expect(bytesToHex(backend.signatures[raw]!.$3.data.sublist(0, 4)), '0x095ea7b3');
        }
      }
    });
  }

  testWidgets('trade and removal dialogs do not act on cancel or Escape', (
    tester,
  ) async {
    final g = await addFundedGroup(61);
    g.update((x) => x.loop = false);
    await mount(tester, BatchPage(state: state));
    await tap(tester, find.text('开始执行'));
    expect(find.text('确认执行'), findsOneWidget);
    expect(backend.routeBodies, isNotEmpty);
    expect(backend.submitted, isEmpty);
    await tap(tester, find.text('取消'));
    expect(backend.submitted, isEmpty);
    expect(g.trader.running, isFalse);
    await tap(tester, find.byTooltip('删除'));
    expect(find.byType(UiDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(state.groups.single, same(g));
    expect(g.wallets, hasLength(1));
    expect(backend.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tool group menu imports addresses for distribution and keys for collection',
    (tester) async {
      final g = await addFundedGroup(62);
      await mount(tester, ToolsPage(state: state), width: 390);
      await tap(tester, find.text('分发').first);
      await tap(tester, find.text('载入组'));
      await tap(tester, find.text('${g.name} · 1'));
      final receiver = tester.widget<TextField>(find.byType(TextField).first);
      expect(receiver.controller!.text, g.wallets.single.address);
      expect(receiver.controller!.text, isNot(_key(62)));
      await tap(tester, find.text('归集').first);
      await tap(tester, find.text('载入组'));
      await tap(tester, find.text('${g.name} · 1'));
      expect(find.text('1 个私钥'), findsOneWidget);
      await tap(tester, find.text('编辑'));
      final editor = find.descendant(
        of: find.byType(KeyEditorPage),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(editor).controller!.text, _key(62));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(backend.submitted, isEmpty);
      expect(backend.bundles, isEmpty);
    },
  );
}
