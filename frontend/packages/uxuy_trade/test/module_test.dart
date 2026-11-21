import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_business_sdk/uxuy_business_sdk.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/shell.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/clipboard_fixture.dart';

class _Scope implements BusinessScope {
  final closed = Completer<void>();
  @override
  bool get isActive => !closed.isCompleted;
  @override
  Future<void> get revoked => closed.future;
  @override
  void ensureActive() {
    if (!isActive) {
      throw const BusinessException(BusinessErrorCode.scopeRevoked);
    }
  }
}

class _Host implements BusinessHost {
  @override
  final _Scope scope = _Scope();
  @override
  final context = BusinessContext(chainId: 56, supportedChainIds: {56});
  @override
  DialogHost get dialogs => throw UnimplementedError();
  @override
  IdentityHost get identity =>
      throw UnimplementedError('module does not use the host wallet');
  @override
  NavigationHost get navigation => throw UnimplementedError();
}

const cake = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';

http.Client _backend([List<String>? paths]) => MockClient((req) async {
  final path = req.url.path;
  paths?.add(path);
  Object body;
  if (path.endsWith('/config')) {
    body = {
      'ok': true,
      'router': '0x00000000000000000000000000000000000c0de1',
      'chainId': 56,
      'routeSource': 'uxuy',
      'routeEnabled': true,
      'approvalSpender': '0x00000000000000000000000000000000000c0de2',
      'maxPriceImpactPercent': 10.0,
    };
  } else if (path.contains('/tokens/')) {
    body = {
      'ok': true,
      'token': {
        'token': cake,
        'name': 'PancakeSwap Token',
        'symbol': 'Cake',
        'decimals': 18,
      },
    };
  } else if (path.endsWith('/platforms/bsc')) {
    body = {
      'ok': true,
      'result': {
        'address': cake,
        'symbol': 'Cake',
        'decimals': 18,
        'platform': 'external',
        'external': true,
        'quote': '0x0000000000000000000000000000000000000000',
        'block': 100,
      },
    };
  } else if (path.contains('/wallets/state')) {
    body = {
      'ok': true,
      'wallets': [
        for (final w in (jsonDecode(req.body) as Map)['wallets'] as List)
          {
            'wallet': w,
            'native': '1500000000000000000',
            'nonce': 0,
            'tokenBalance': '2000000000000000000',
            'routerAllowance': '0',
          },
      ],
    };
  } else {
    body = {'ok': false, 'code': 'X', 'message': 'not used'};
  }
  return http.Response(jsonEncode(body), 200);
});

Widget _app(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = ClipboardFixture();
  setUp(clipboard.install);
  tearDown(clipboard.uninstall);
  test('manifest declares only what the module uses', () {
    final m = UxuyTradeModule(
      endpoint: Uri.parse('http://b/'),
      clientFactory: _backend,
    ).manifest;
    expect(m.id, 'uxuy.trade');
    expect(m.sdkMajor, businessSdkMajor);
    expect(m.capabilities, {BusinessCapability.dialogs});
  });

  test(
    'without an explicit endpoint the module uses its configured default',
    () async {
      final hosts = <String>{};
      final session = UxuyTradeModule(
        clientFactory: () => MockClient((req) async {
          hosts.add(req.url.origin);
          return http.Response(
            jsonEncode({'ok': false, 'code': 'X', 'message': 'not used'}),
            200,
          );
        }),
      ).createSession(_Host());
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      expect(hosts, {Uri.parse(uxuyTradeEndpoint).origin});
    },
  );

  testWidgets('token → group → keys → wallet details → log', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final host = _Host();
    final session = UxuyTradeModule(
      endpoint: Uri.parse('http://backend.test/'),
      clientFactory: _backend,
    ).createSession(host);
    await tester.pumpWidget(_app(session.buildEntry()));
    await tester.pumpAndSettle();

    expect(find.text('发射台'), findsOneWidget);
    expect(find.text('Four.meme'), findsOneWidget);
    await tester.tap(find.text('批量买卖'));
    await tester.pumpAndSettle();
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('尚未选择'), findsOneWidget);
    expect(find.text('添加地址组后开始配置。'), findsOneWidget);

    // token is chosen once, at the top, for every page
    await tester.tap(find.text('选择代币'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(TokenSheet),
        matching: find.byType(TextField),
      ),
      cake,
    );
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('Cake'), findsOneWidget);

    // a group owns its keys and settings
    await tester.tap(find.text('新建组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通组'));
    await tester.pumpAndSettle();
    expect(find.text('组01'), findsOneWidget);
    expect(find.text('请先输入私钥'), findsOneWidget);
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
    expect(find.text('组01 · 1 个地址'), findsOneWidget);
    expect(
      find.text('1.5'),
      findsOneWidget,
      reason: 'BNB total from the batch balance read',
    );

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(find.text('0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf'), findsOneWidget);

    // BSC trades are sent privately: no slippage setting, only the price-impact limit.
    expect(find.text('滑点'), findsNothing);
    expect(find.text('%'), findsNothing, reason: 'buy amounts are in BNB');

    // direction switch resets the amount rule (sell defaults to 100% by ratio)
    await tester.ensureVisible(find.text('卖出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('卖出'));
    await tester.pumpAndSettle();
    expect(find.text('按启动时余额计算'), findsOneWidget);
    expect(find.text('%'), findsOneWidget, reason: 'range unit switches to %');

    // floating log window
    await tester.tap(find.bySemanticsLabel('打开日志'));
    await tester.pumpAndSettle();
    expect(find.text('执行日志'), findsOneWidget);
    expect(find.textContaining('组01 已导入 1 个钱包'), findsOneWidget);

    host.scope.closed.complete();
    session.dispose();
  });

  testWidgets(
    'linked group: sellers, buyers, one relay per buyer, relay backup before start',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final session = UxuyTradeModule(
        endpoint: Uri.parse('http://backend.test/'),
        clientFactory: _backend,
      ).createSession(_Host());
      await tester.pumpWidget(_app(session.buildEntry()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量买卖'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择代币'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(TokenSheet),
          matching: find.byType(TextField),
        ),
        cake,
      );
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('新建组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联组'));
      await tester.pumpAndSettle();
      expect(find.text('关联组01 · 先卖后买'), findsOneWidget);
      expect(find.text('请先输入卖方和买方私钥'), findsOneWidget);

      Future<void> keys(int index, String text) async {
        final open = find.text('输入私钥').at(index);
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(KeyEditorPage),
            matching: find.byType(TextField),
          ),
          text,
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
      }

      await keys(0, '0x${'1'.padLeft(64, '0')}\n0x${'2'.padLeft(64, '0')}');
      await keys(1, '0x${'3'.padLeft(64, '0')}');
      await tester.dragFrom(const Offset(200, 450), const Offset(0, 750));
      await tester.pumpAndSettle();
      expect(find.text('卖方 2 / 买方 1'), findsOneWidget);
      expect(
        find.textContaining('中转地址 · 1', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('中转地址会接收资金，开始前请先复制保存中转私钥。'), findsWidgets);

      // the same key cannot be a seller and a buyer
      await keys(1, '0x${'1'.padLeft(64, '0')}');
      expect(find.text('买卖两侧的钱包不能重复'), findsOneWidget);
      Navigator.of(tester.element(find.byType(KeyEditorPage))).pop();
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('复制中转私钥'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制中转私钥'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      final start = find.widgetWithText(FilledButton, '检查授权');
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      expect(clipboard.writes, hasLength(1));
      session.dispose();
    },
  );

  testWidgets(
    'tools: generate, copy with confirmation, distribute modes, collect',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final session = UxuyTradeModule(
        endpoint: Uri.parse('http://backend.test/'),
        clientFactory: _backend,
      ).createSession(_Host());
      await tester.pumpWidget(_app(session.buildEntry()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('工具'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '3');
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      expect(find.text('已生成 3'), findsOneWidget);
      expect(find.text('3 个未备份'), findsOneWidget);
      await tester.tap(find.text('复制所选私钥'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('已备份'), findsOneWidget);
      expect(clipboard.writes, hasLength(1));
      expect(clipboard.writes.single.split('\n'), hasLength(3));

      await tester.tap(find.text('分发'));
      await tester.pumpAndSettle();
      expect(find.text('一对多'), findsOneWidget);
      expect(find.text('中转分发'), findsOneWidget);
      expect(find.text('请先点“使用”生成分发明细'), findsOneWidget);
      await tester.tap(find.text('多对多'));
      await tester.pumpAndSettle();
      expect(find.text('按顺序一一对应，数量须相同。'), findsOneWidget);
      expect(find.text('每个钱包分发'), findsOneWidget);

      await tester.tap(find.text('归集').first);
      await tester.pumpAndSettle();
      expect(find.text('归集方私钥'), findsOneWidget);
      expect(find.text('开始归集'), findsOneWidget);
      session.dispose();
    },
  );

  testWidgets(
    'Four launch follows the official API: blocked shows why, a later check brings the form back',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      var blocked = true;
      final base = _backend();
      final session = UxuyTradeModule(
        endpoint: Uri.parse('http://backend.test/'),
        clientFactory: () => MockClient((req) async {
          if (req.url.path != '/api/fourmeme') {
            return http.Response.fromStream(await base.send(req));
          }
          // Exactly what the backend's Four gate answers while Four challenges the server, then after recovery.
          final body = blocked
              ? {
                  'ok': false,
                  'code': 'FOUR_API_CHALLENGED',
                  'message': 'Four 官方接口限制本服务器访问，发币暂不可用',
                  'retryable': false,
                  'data': {'retryAfterSeconds': 300, 'service': 'four'},
                }
              : {
                  'ok': true,
                  'payload': {
                    'code': 0,
                    'data': [
                      {
                        'status': 'PUBLISH',
                        'symbol': 'BNB',
                        'nativeSymbol': 'BNB',
                        'symbolAddress':
                            '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
                        'totalBAmount': '18',
                        'totalAmount': 1000000000,
                        'saleRate': 0.8,
                      },
                    ],
                  },
                };
          return http.Response(
            jsonEncode(body),
            blocked ? 503 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ).createSession(_Host());
      await tester.pumpWidget(_app(session.buildEntry()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发射台'));
      await tester.pumpAndSettle();
      expect(find.text('Four.meme · 暂不可用'), findsOneWidget);
      expect(find.text('Four.meme 发币暂不可用'), findsOneWidget);
      expect(find.text('Four 官方接口限制本服务器访问，发币暂不可用'), findsOneWidget);
      expect(find.textContaining('已发行的 Four 代币买卖不受影响'), findsOneWidget);

      blocked = false; // Four answers the backend again
      await tester.tap(find.text('重新检测'));
      await tester.pumpAndSettle();
      expect(find.text('Four.meme'), findsOneWidget);
      expect(find.text('Four.meme 发币暂不可用'), findsNothing);
      expect(find.text('重新检测'), findsNothing);
      expect(
        find.text('基本信息'),
        findsOneWidget,
        reason: 'the launch form is back',
      );
      session.dispose();
    },
  );

  testWidgets('english locale', (tester) async {
    final session = UxuyTradeModule(
      endpoint: Uri.parse('http://backend.test/'),
      clientFactory: _backend,
    ).createSession(_Host());
    await tester.pumpWidget(
      _app(session.buildEntry(), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Batch trade'), findsWidgets);
    session.dispose();
  });

  group('group rules', () {
    late AppState state;
    setUp(
      () => state = AppState(
        BackendClient(Uri.parse('http://backend.test/'), _backend()),
        MemoryKeyStore(),
      ),
    );
    tearDown(() => state.dispose());

    test('idle groups can share a wallet', () async {
      final a = state.addGroup();
      final b = state.addGroup();
      await state.setKeys(a, '0x${'1'.padLeft(64, '0')}');
      await state.setKeys(b, '0x${'1'.padLeft(64, '0')}');
      expect(b.wallets.single.address, a.wallets.single.address);
      expect(state.walletOverlaps(a, [a.wallets.single.address]), isEmpty);
    });

    test('plan validation', () async {
      final g = state.addGroup();
      await state.setKeys(g, '0x${'1'.padLeft(64, '0')}');
      g.setBuy(false);
      g.max = '120';
      expect(() => g.plan(cake, 18), throwsFormatException);
      g
        ..min = '50'
        ..max = '20';
      expect(() => g.plan(cake, 18), throwsFormatException);
      g
        ..min = '50'
        ..max = '80';
      final plan = g.plan(cake, 18);
      expect(plan.amount.ratio, isTrue);
      expect(plan.amount.min, BigInt.from(5000));
      expect(plan.amount.max, BigInt.from(8000));
      g.setRatio(false);
      expect(
        () => g.plan(cake, null),
        throwsFormatException,
        reason: 'unknown decimals: amount mode refused, never assumes 18',
      );
    });
  });
}
