import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/launch.dart' show LaunchState;
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/batch_group_help.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/shell.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/address_visibility.dart';

const _cake = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';

/// This client handles every call in memory. No fallback to the real network.
class _Fixture {
  final paths = <String>[];
  late final client = MockClient((req) async {
    final path = req.url.path;
    paths.add(path);
    Object body;
    if (path.endsWith('/config')) {
      body = {
        'ok': true,
        'router': '0x00000000000000000000000000000000000c0de1',
        'chainId': 56,
        'routeSource': 'uxuy',
        'routeEnabled': true,
        'approvalSpender': '0x00000000000000000000000000000000000c0de2',
        'maxPriceImpactPercent': 7,
      };
    } else if (path.contains('/tokens/')) {
      body = {
        'ok': true,
        'token': {
          'token': _cake,
          'name': 'PancakeSwap Token',
          'symbol': 'CAKE',
          'decimals': 18,
        },
      };
    } else if (path.endsWith('/platforms/bsc')) {
      body = {
        'ok': true,
        'result': {
          'address': _cake,
          'symbol': 'CAKE',
          'decimals': 18,
          'platform': 'external',
          'external': true,
          'quote': '0x0000000000000000000000000000000000000000',
          'block': 100,
        },
      };
    } else if (path.endsWith('/wallets/state')) {
      body = {
        'ok': true,
        'wallets': [
          for (final wallet in (jsonDecode(req.body) as Map)['wallets'] as List)
            {
              'wallet': wallet,
              'native': '1500000000000000000',
              'nonce': 0,
              'tokenBalance': '2000000000000000000',
              'routerAllowance': '0',
            },
        ],
      };
    } else {
      body = {
        'ok': false,
        'code': 'FIXTURE_ONLY',
        'message': 'Not used in this fixture',
      };
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  late final state = AppState(
    BackendClient(Uri.parse('http://fixture.invalid/'), client),
    MemoryKeyStore(),
  );

  void dispose() {
    state.dispose();
    client.close();
  }

  void expectNoExecution() {
    expect(
      paths.where(
        (p) =>
            p.contains('/transactions') ||
            p.contains('/bundles') ||
            p.contains('/routes'),
      ),
      isEmpty,
    );
  }
}

Widget _app(AppState state) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData.light()),
  home: HomePage(state: state),
);

Future<void> _nav(WidgetTester tester, String label) async {
  final wide =
      tester.view.physicalSize.width / tester.view.devicePixelRatio >= 1000;
  final target = wide
      ? find.descendant(
          of: find.byKey(const ValueKey('desktop-sidebar')),
          matching: find.text(label),
        )
      : find.text(label).last;
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _chooseToken(WidgetTester tester, {required bool wide}) async {
  if (wide) {
    await tester.tap(find.byTooltip('选择代币'));
  } else {
    await _nav(tester, '批量买卖');
    await tester.tap(find.text('选择代币'));
  }
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(TokenSheet),
      matching: find.byType(TextField),
    ),
    _cake,
  );
  await tester.tap(find.text('确认'));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets('launch navigation unlocks batch trading after confirmation at $width', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.state.init();
      await tester.pumpWidget(_app(fixture.state));
      await tester.pumpAndSettle();
      final help = find.byType(BatchGroupHelpButton);
      fixture.state.four.state = LaunchState.pending;
      await _nav(tester, '批量买卖');
      expect(help, findsNothing);
      fixture.state.four.state = LaunchState.launched;
      await _nav(tester, '批量买卖');
      expect(help, findsOneWidget);
      if (width >= 1000) {
        await _nav(tester, 'Flap');
        expect(help, findsOneWidget);
        await _nav(tester, 'Four.meme');
        expect(help, findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [1440.0, 1024.0, 390.0, 320.0]) {
    testWidgets(
      'web shell fits ${width.toInt()} × 720 including current token and logs',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        await fixture.state.init();
        await tester.pumpWidget(_app(fixture.state));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final sidebar = tester.getSize(
          find.byKey(const ValueKey('desktop-sidebar')),
        );
        expect(sidebar.width, width >= 1000 ? 244 : 0);
        final help = find.byType(BatchGroupHelpButton);
        expect(help, findsNothing);
        await _nav(tester, '批量买卖');
        expect(help, findsOneWidget);
        final batchLabel = tester.getRect(find.text('批量买卖').last);
        final helpRect = tester.getRect(help);
        if (width <= 390) {
          expect(tester.getCenter(find.text('控盘率').last).dy, closeTo(batchLabel.center.dy, 2));
          expect(find.text('监控'), findsNothing);
        }
        final anchor = width < 360 ? tester.getRect(find.text('地址组').first) : batchLabel;
        expect(helpRect.left, inInclusiveRange(anchor.right, anchor.right + 20));
        expect(helpRect.center.dy, closeTo(anchor.center.dy, 2));
        expect(find.widgetWithText(TextButton, '价格影响设置'), findsOneWidget);
        await tester.tap(help);
        await tester.pumpAndSettle();
        expect(find.text('普通组'), findsOneWidget);
        expect(find.text('关联组'), findsOneWidget);
        await tester.tap(help);
        await tester.pumpAndSettle();
        await _chooseToken(tester, wide: width >= 1000);
        expect(fixture.state.token?.address.toLowerCase(), _cake);
        expectFullAddress(
          tester,
          fixture.state.token!.address,
          within: width >= 1000
              ? find.byKey(const ValueKey('desktop-sidebar'))
              : find.byType(TokenBar),
        );
        if (width < 1000) {
          final address = find.descendant(of: find.byType(TokenBar), matching: find.text(fixture.state.token!.address));
          expect(tester.getSize(address).width, greaterThan(width - 70));
          expect(tester.getRect(address).top, greaterThanOrEqualTo(tester.getRect(
            find.descendant(of: find.byType(TokenBar), matching: find.widgetWithText(TextButton, '更换代币')),
          ).bottom));
        }
        expect(find.text('CAKE'), findsWidgets);
        expect(tester.takeException(), isNull);
        await _nav(tester, width >= 1000 ? '生成私钥' : '工具');
        expect(help, findsNothing);
        for (final label in ['生成私钥', '分发', '归集']) {
          final inPage = find.descendant(
            of: find.byType(ToolsPage),
            matching: find.text(label),
          );
          expect(inPage, width >= 1000 ? findsNothing : findsOneWidget);
        }
        expect(find.text('生成'), findsOneWidget);
        expect(tester.takeException(), isNull);

        final ballCenter = tester.getCenter(find.byType(LogBall));
        await tester.tap(find.byType(LogBall));
        await tester.pumpAndSettle();
        expect(find.text('执行日志'), findsOneWidget);
        final logRect = tester.getRect(find.byType(LogWindow));
        expect(logRect.left, greaterThanOrEqualTo(0));
        expect(logRect.right, lessThanOrEqualTo(width));
        expect(logRect.bottom, lessThanOrEqualTo(720));
        expect(tester.getCenter(find.byType(LogBall)), ballCenter);
        await tester.tap(find.byType(LogBall));
        await tester.pumpAndSettle();
        expect(find.byType(LogWindow), findsOneWidget);
        expect(tester.widget<LogBall>(find.byType(LogBall)).morphProgress, 0);
        expect(tester.takeException(), isNull);
        fixture.expectNoExecution();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('switching between desktop and mobile preserves the node latency timer', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.state.init();
    tester.view.physicalSize = const Size(1440, 720);
    await tester.pumpWidget(_app(fixture.state));
    await tester.pumpAndSettle();
    for (final width in [390.0, 1440.0, 390.0]) {
      tester.view.physicalSize = Size(width, 720);
      await tester.pump();
    }
    expect(fixture.paths.where((path) => path.endsWith('/rpc-latency')).length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('each launchpad keeps its own builder tip in the sidebar and compact form', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.state.init();
    await tester.pumpWidget(_app(fixture.state));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
    final field = find.descendant(of: find.byType(LaunchTipField), matching: find.byType(TextField));
    String value() => tester.widget<TextField>(field).controller!.text;

    await _nav(tester, 'Flap');
    expect(find.descendant(of: sidebar, matching: find.byType(LaunchTipField)), findsOneWidget);
    await tester.enterText(field, '0.012');
    await _nav(tester, 'Genius');
    expect(value(), '0');
    await tester.enterText(field, '0.004');
    await _nav(tester, 'Flap');
    expect(value(), '0.012');
    await _nav(tester, '批量买卖');
    expect(field, findsNothing);
    await _nav(tester, 'Flap');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.descendant(of: sidebar, matching: find.byType(LaunchTipField)), findsNothing);
    expect(value(), '0.012');
    await tester.ensureVisible(field);
    await tester.enterText(field, '0.02');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(value(), '0.02');
    await _nav(tester, 'Genius');
    expect(value(), '0.004');
    expect(tester.takeException(), isNull);
    fixture.expectNoExecution();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('short desktop can scroll from navigation to the current token', (tester) async {
    tester.view.physicalSize = const Size(1024, 460);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.state.init();
    await fixture.state.loadToken(_cake);
    await tester.pumpWidget(_app(fixture.state));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
    final token = find.descendant(of: sidebar, matching: find.text(fixture.state.token!.address));
    final scrollable = find.descendant(of: sidebar, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(token, 80, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(tester.getRect(token).bottom, lessThanOrEqualTo(460));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'sidebar navigation and resize preserve launch draft and wallet group settings',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.state.init();
      await tester.pumpWidget(_app(fixture.state));
      await tester.pumpAndSettle();

      await _nav(tester, 'Flap');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('launch-configuration')),
          matching: find.byType(TextField),
        ).first,
        'Retained launch draft',
      );
      await _nav(tester, 'Genius');
      expect(find.text('Retained launch draft'), findsNothing);
      await _nav(tester, 'Flap');
      expect(find.text('Retained launch draft'), findsOneWidget);
      await _chooseToken(tester, wide: true);
      await _nav(tester, '批量买卖');
      await tester.tap(find.text('新建组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('普通组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('输入私钥'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(KeyEditorPage),
          matching: find.byType(TextField),
        ),
        '0x${'1'.padLeft(64, '0')}',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(fixture.state.groups.single.allWallets.length, 1);
      final group = fixture.state.group! as TradeGroup;
      await tester.tap(find.text('卖出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('随机'));
      await tester.pumpAndSettle();
      expect(group.buy, isFalse);
      expect(group.randomOrder, isTrue);
      expect(group.min, '100');

      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      expect(
        find.descendant(of: sidebar, matching: find.text('工具')),
        findsNothing,
      );
      final toolFields = find.descendant(
        of: find.byType(ToolsPage),
        matching: find.byType(TextField),
      );
      await _nav(tester, '生成私钥');
      await tester.enterText(toolFields.first, '7');
      await _nav(tester, '分发');
      await tester.tap(find.text('多对多'));
      await tester.pumpAndSettle();
      await _nav(tester, '归集');
      expect(find.text('开始归集'), findsOneWidget);
      await tester.enterText(toolFields.first, _cake);
      await _nav(tester, '分发');
      expect(find.text('按顺序一一对应，数量须相同。'), findsOneWidget);
      await _nav(tester, '归集');
      expect(tester.widget<TextField>(toolFields.first).controller!.text, _cake);
      fixture.state.transfers.running = true;
      await _nav(tester, '分发');
      expect(find.text('开始分发'), findsNothing);
      expect(tester.widget<TextField>(toolFields.first).controller!.text, _cake);
      fixture.state.transfers.running = false;
      await _nav(tester, 'Flap');
      expect(find.text('Retained launch draft'), findsOneWidget);
      await _nav(tester, '生成私钥');
      expect(tester.widget<TextField>(toolFields.first).controller!.text, '7');
      await _nav(tester, '批量买卖');
      for (final width in [1024.0, 390.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 720);
        await tester.pumpAndSettle();
        expect(identical(fixture.state.group, group), isTrue);
        expect(
          group.wallets.single.address,
          '0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf',
        );
        expect(group.buy, isFalse);
        expect(group.randomOrder, isTrue);
        expect(group.min, '100');
        expect(group.max, '100');
        expect(tester.takeException(), isNull);
      }
      expect(
        find.text('100'),
        findsNWidgets(2),
        reason: 'the visible amount controllers retain the selected rule',
      );
      fixture.expectNoExecution();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
