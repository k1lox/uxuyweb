import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/select.dart';
import 'package:uxuy_trade/src/ui/component_theme.dart';
import 'package:uxuy_trade/src/ui/theme.dart' show uxuyTheme;
import 'package:uxuy_trade/uxuy_trade.dart';

void main() {
  testWidgets(
    'Four and offstage Flap catalogs load at startup; opening, closing and switching do not fetch',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <String>[];
      final client = MockClient((request) async {
        if (request.url.path != '/api/v1/rpc/bsc' && request.url.queryParameters['action'] != 'creationCurve') {
          requests.add(request.url.queryParameters['action'] ?? request.url.path);
        }
        final Object payload = switch (request.url.path) {
          '/api/fourmeme' => {
            'code': 0,
            'data': [
              for (final symbol in ['BNB', 'BNCB'])
                {
                  'status': 'PUBLISH',
                  'symbol': symbol,
                  'nativeSymbol': symbol,
                  'symbolAddress': symbol == 'BNB'
                      ? '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'
                      : '0x0000000000000000000000000000000000000001',
                  'totalBAmount': '18',
                  'totalAmount': 1000000000,
                  'saleRate': .8,
                },
            ],
          },
          '/api/flap' => {
            'tokens': [
              {
                'address': '0x0000000000000000000000000000000000000000',
                'symbol': 'BNB',
                'decimals': 18,
              },
              {
                'address': '0x0000000000000000000000000000000000000001',
                'symbol': 'BNCB',
                'decimals': 18,
              },
            ],
          },
          _ => throw StateError('Unexpected request: ${request.url.path}'),
        };
        return http.Response(
          jsonEncode({'ok': true, 'payload': payload}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final state = AppState(
        BackendClient(Uri.parse('http://fixture.invalid/'), client),
        MemoryKeyStore(),
      );
      final platform = ValueNotifier(0);
      addTearDown(() {
        state.dispose();
        client.close();
        platform.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: uxuyTheme(ThemeData()),
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: platform,
              builder: (_, value, _) => LaunchPage(
                state: state,
                selectedPlatform: value,
                onTrade: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests,
        unorderedEquals(['/api/fourmeme', '/api/flap', 'customCatalog']),
      );
      final initialRequests = List<String>.of(requests);

      Future<void> toggle(String label) async {
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is UiSelect<String> && widget.semanticLabel == label,
        );
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pump();
        expect(find.byKey(const ValueKey('ui-select-menu')), findsOneWidget);
        expect(requests, initialRequests);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
        expect(requests, initialRequests);
      }

      await toggle('分类');
      await toggle('底池代币');
      await toggle('底池代币');
      platform.value = 1;
      await tester.pumpAndSettle();
      await toggle('底池代币');
      expect(requests, initialRequests);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Flap keeps official options through a partial custom refresh and retries only stale source',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var customCalls = 0, officialCalls = 0;
      const zero = '0x0000000000000000000000000000000000000000',
          custom = '0x1000000000000000000000000000000000000001';
      final client = MockClient((request) async {
        Object payload;
        if (request.url.path == '/api/fourmeme') {
          payload = {'code': 0, 'data': []};
        } else if (request.url.queryParameters['action'] == 'customCatalog') {
          customCalls++;
          payload = {
            'tokens': [
              {'address': custom, 'symbol': 'STOCK', 'decimals': 6},
            ],
            if (customCalls == 1) 'stale': true,
            if (customCalls == 2) 'partial': true,
            if (customCalls == 3) 'refreshError': '测试服务不可用',
          };
        } else if (request.url.queryParameters['action'] == 'creationCurve') {
          payload = {'tokenVersion':6, 'r':'1', 'h':'1','k':'1','bondingCurveFeeRate':'1','dexSupplyThresh':'1','blockNumber':'1'};
        } else {
          officialCalls++;
          payload = {
            'tokens': [
              {'address': zero, 'symbol': 'BNB', 'decimals': 18},
            ],
          };
        }
        return http.Response(
          jsonEncode({'ok': true, 'payload': payload}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final state = AppState(
        BackendClient(Uri.parse('http://fixture.invalid'), client),
        MemoryKeyStore(),
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
          theme: uxuyTheme(ThemeData()),
          home: Scaffold(
            body: LaunchPage(state: state, selectedPlatform: 1, onTrade: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder picker() => find.byWidgetPredicate(
        (w) => w is UiSelect<String> && w.semanticLabel == '底池代币',
      );
      final original = tester.widget<UiSelect<String>>(picker());
      expect(original.options.map((option) => option.$1), [zero, custom]);
      expect(original.value, zero);
      expect(find.text('正在更新自定义底池币列表，暂用上次的列表。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect((customCalls, officialCalls), (2, 1));
      expect(find.text('自定义底池币列表中部分代币资料尚未取全，可选择已列出的币。'), findsOneWidget);
      expect(
        tester
            .widget<UiSelect<String>>(picker())
            .options
            .map((option) => option.$1),
        [zero, custom],
      );
      await tester.pump(const Duration(seconds: 6));
      expect(customCalls, 2);
      final retry = find.widgetWithText(TextButton, '重试');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect((customCalls, officialCalls), (3, 1));
      expect(find.textContaining('部分代币资料尚未取全'), findsNothing);
      final failed = find.textContaining('测试服务不可用');
      expect(tester.widget<Text>(failed).style?.color, UiStyle.negative);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect((customCalls, officialCalls), (4, 1));
      expect(failed, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
