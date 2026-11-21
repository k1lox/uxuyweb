import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/linked_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/address_visibility.dart';
import 'support/clipboard_fixture.dart';

const _token = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';
String _key(int n) => '0x${n.toRadixString(16).padLeft(64, '0')}';

/// Read-only workspace fixture. It can stop a background quote but never submits a transaction.
class _Fixture {
  final writes = <String>[];
  late final client = MockClient((req) async {
    Object body;
    if (req.url.path.endsWith('/config')) {
      body = {
        'ok': true,
        'router': '0x00000000000000000000000000000000000c0de1',
        'chainId': 56,
        'routeSource': 'uxuy',
        'routeEnabled': true,
        'fastPreflightVersion': 1,
        'approvalSpender': '0x00000000000000000000000000000000000c0de2',
        'maxPriceImpactPercent': 7.0,
      };
    } else if (req.url.path.endsWith('/gas')) {
      body = {'ok': true, 'gasPrice': '50000000', 'blockNumber': 123};
    } else if (req.url.path.endsWith('/platforms/bsc')) {
      body={'ok':true,'result':{'address':_token,'symbol':'CAKE','decimals':18,'platform':'external','external':true,'quote':'0x${'0'*40}','block':123}};
    } else if (req.url.path.endsWith('/wallets/state')) {
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
    } else if (RegExp(r'/routes(?:/batch|/bundle)?$').hasMatch(req.url.path)) {
      final request = jsonDecode(req.body) as Map;
      final orders = request['requests'] as List? ?? [request];
      final forecast = orders.isNotEmpty && orders.every((r) => r is Map && r['forecastOnly'] == true);
      if (!forecast) writes.add(req.url.path);
      body = {'ok': false, 'code': forecast ? 'NO_ROUTE' : 'NOT_ALLOWED', 'message': 'UI fixture has no price feed'};
    } else {
      writes.add(req.url.path);
      body = {'ok': false, 'code': 'NOT_ALLOWED', 'message': 'UI fixture only'};
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
  )..token = const TokenMeta(_token, 'PancakeSwap Token', 'CAKE', 18);
  void dispose() {
    state.dispose();
    client.close();
  }
}

Widget _app(AppState state) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData(useMaterial3: true)),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) => BatchPage(state: state),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _inputKeys(WidgetTester tester, int index, String text) async {
  await _tap(tester, find.text('输入私钥').at(index));
  await tester.enterText(find.descendant(of: find.byType(KeyEditorPage), matching: find.byType(TextField)), text);
  await _tap(tester, find.text('保存'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = ClipboardFixture();
  setUp(clipboard.install);
  tearDown(clipboard.uninstall);
  testWidgets('adding or switching groups keeps the active mobile card in view', (tester) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final state = fixture.state;
    await state.init();
    state.addGroup();
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      state.addGroup();
    }
    await tester.pumpAndSettle();
    for (final index in [state.groups.length - 1, 0]) {
      state.select(index);
      await tester.pumpAndSettle();
      final chip = find.ancestor(
        of: find.text(state.groups[index].name),
        matching: find.byType(InkWell),
      ).first;
      final visible = tester.getRect(chip);
      expect(visible.left, greaterThanOrEqualTo(16));
      expect(visible.right, lessThanOrEqualTo(374));
    }
    expect(tester.takeException(), isNull);
    expect(fixture.writes, isEmpty);
  });

  for (final rapid in [false, true]) {
    testWidgets('desktop ${rapid ? 'rapid' : 'ordinary'} settings survive importing the first wallet', (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final state = fixture.state;
      await state.init();
      if (rapid) {
        state.addRapidGroup();
      } else {
        state.addGroup();
      }
      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();

      Rect side({required bool settings}) {
        final columns = tester.widget<TradeColumns>(find.byType(TradeColumns));
        return tester.getRect(find.byWidget(settings ? columns.right : columns.left));
      }
      final input = rapid
          ? find.byKey(const ValueKey('每笔买入BNB'))
          : find.byType(TextField).first;
      expect(side(settings: true).top, greaterThan(side(settings: false).bottom));
      await tester.enterText(input, '0.12345');
      await _inputKeys(tester, 0, _key(3));
      expect(side(settings: true).left, greaterThan(side(settings: false).right));
      final editor = tester.widget<EditableText>(find.descendant(of: input, matching: find.byType(EditableText)).first);
      expect(editor.controller.text, '0.12345');
    });
  }

  testWidgets(
    'linked wallet detail expansion survives desktop/mobile resizing',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final s = fixture.state;
      await s.init();
      final group = s.addLinkedGroup();
      await s.setLinkedKeys(group, sellers: true, text: _key(11));
      await s.setLinkedKeys(group, sellers: false, text: _key(12));
      await tester.pumpWidget(_app(s));
      await tester.pumpAndSettle();
      final seller = find.byKey(const ValueKey('linked-seller-details'));
      final buyer = find.byKey(const ValueKey('linked-buyer-details'));
      await _tap(tester, seller);
      await _tap(tester, buyer);
      expect(tester.widget<IconButton>(seller).tooltip, '收起');
      expect(tester.widget<IconButton>(buyer).tooltip, '收起');
      for (final width in [390.0, 1440.0, 390.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        for (final wallet in [...group.sellers, ...group.buyers]) {
          expectFullAddress(tester, wallet.address);
        }
        expect(tester.widget<IconButton>(seller).tooltip, '收起');
        expect(tester.widget<IconButton>(buyer).tooltip, '收起');
        expect(tester.takeException(), isNull);
      }
      await _inputKeys(tester, 0, _key(11));
      expect(tester.widget<IconButton>(seller).tooltip, '展开');
      expect(tester.widget<IconButton>(buyer).tooltip, '收起');
      tester.view.physicalSize = const Size(1440, 1000);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(seller).tooltip, '展开');
      expect(tester.widget<IconButton>(buyer).tooltip, '收起');
      expect(fixture.writes, isEmpty);
    },
  );

  for (final width in [1440.0, 1000.0, 390.0]) {
    testWidgets(
      'normal group $width: import, settings, selection survive switching',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        final s = fixture.state;
        await s.init();
        final first = s.addGroup();
        await tester.pumpWidget(_app(s));
        await tester.pumpAndSettle();
        await _inputKeys(tester, 0, '${_key(1)}\n${_key(2)}');
        expect(first.wallets.length, 2);
        expect(first.selected.length, 2);
        await _tap(tester, find.text('卖出'));
        await _tap(tester, find.text('随机'));
        expect(first.buy, isFalse);
        expect(first.randomOrder, isTrue);
        expect(first.ratio, isTrue);
        expect(first.min, '100');
        await _tap(tester, find.text('展开'));
        expect(find.byType(Checkbox), findsWidgets);
        for (final wallet in first.wallets) {
          expectFullAddress(tester, wallet.address);
        }
        await _inputKeys(tester, 0, '${_key(1)}\n${_key(2)}');
        expect(find.text('展开'), findsOneWidget);
        expect(find.byType(Checkbox), findsOneWidget, reason: 'only the loop setting remains visible');
        first.toggle(first.wallets.last);
        await tester.pumpAndSettle();
        expect(first.selected.length, 1);
        final second = s.addGroup();
        await tester.pumpAndSettle();
        expect(find.text('${second.name} · 0 个地址'), findsOneWidget);
        await _tap(tester, find.text(first.name));
        expect(find.text('${first.name} · 2 个地址'), findsOneWidget);
        expect(first.buy, isFalse);
        expect(first.randomOrder, isTrue);
        expect(first.selected.length, 1);
        expect(find.byType(TradeColumns), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(fixture.writes, isEmpty);
      },
    );

    testWidgets(
      'linked group $width: both wallet sides, relays, and backup gate remain usable',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        final s = fixture.state;
        await s.init();
        final group = s.addLinkedGroup();
        await tester.pumpWidget(_app(s));
        await tester.pumpAndSettle();
        await _inputKeys(tester, 0, '${_key(3)}\n${_key(4)}');
        await _inputKeys(tester, 1, _key(5));
        expect(group.sellers.length, 2);
        expect(group.buyers.length, 1);
        expect(group.transits.length, 1);
        expect(group.transitsBackedUp, isFalse);
        expect(find.byType(LinkedGroupDetail), findsOneWidget);
        expect(find.textContaining('中转地址会接收资金'), findsWidgets);
        await _tap(tester, find.text('随机'));
        expect(group.randomOrder, isTrue);
        // Copy is still followed by explicit confirmation; no trading takes place.
        await _tap(tester, find.text('复制中转私钥'));
        await _tap(tester, find.text('确认'));
        expect(group.transitsBackedUp, isTrue);
        expect(clipboard.writes, hasLength(1));
        expect(
          clipboard.writes.single.split('\n'),
          [for (final wallet in group.allTransits) wallet.exportPrivateKey()],
        );
        s.addGroup();
        await tester.pumpAndSettle();
        await _tap(tester, find.text(group.name));
        expect(group.sellers.length, 2);
        expect(group.buyers.length, 1);
        expect(group.randomOrder, isTrue);
        expect(group.transitsBackedUp, isTrue);
        expect(tester.takeException(), isNull);
        expect(fixture.writes, isEmpty);
      },
    );
  }
}
