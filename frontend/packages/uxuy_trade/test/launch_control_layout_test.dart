import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/address_visibility.dart';

void main() {
  for (final width in [1440.0, 1000.0, 390.0, 320.0]) {
    testWidgets(
      'launch controls fit content at $width; long fields retain width across all platforms',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <String>[];
        final devKey = '1'.padLeft(64, '0');
        final devAddress = TradeWallet.import('fixture', devKey).address;
        final client = MockClient((request) async {
          requests.add(
            request.url.queryParameters['action'] ?? request.url.path,
          );
          if (request.url.path == '/api/v1/wallets/state') {
            return http.Response(jsonEncode({
              'ok': true,
              'wallets': [
                {'wallet': devAddress, 'native': '1000000000000000000', 'nonce': 0}
              ],
            }), 200);
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
            theme: componentTheme(uxuyTheme(ThemeData())),
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
        Finder select(String name) => find.byWidgetPredicate(
          (widget) =>
              widget is UiSelect<String> && widget.semanticLabel == name,
        );
        Finder input(String label) {
          final text = find.text(label).first;
          final column = find
              .ancestor(of: text, matching: find.byType(Column))
              .first;
          return find
              .descendant(of: column, matching: find.byType(TextField))
              .first;
        }

        Future<void> reveal(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
        }

        void inside(Finder finder) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }

        for (final selected in [0, 1, 2]) {
          platform.value = selected;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final wallets = find.byKey(const ValueKey('launch-wallets'));
          Finder walletText(String name) => find.descendant(of: wallets, matching: find.text(name));
          final innerMode = walletText('仅内盘首买');
          final externalMode = find.widgetWithText(TextButton, '内外盘首买');
          expect(walletText('钱包'), findsNothing);
          expect(walletText('模式'), findsNothing);
          final dev = walletText('Dev 钱包');
          final emptyDev = walletText('未填写');
          final editDev = walletText('编辑');
          await reveal(innerMode);
          if (selected != 0) {
            expect(tester.getCenter(innerMode).dy, closeTo(tester.getCenter(externalMode).dy, 3));
            await tester.tap(externalMode);
            await tester.pumpAndSettle();
            expect(walletText('外盘购买钱包 · 0'), findsOneWidget);
            await tester.tap(innerMode);
            await tester.pumpAndSettle();
            expect(walletText('外盘购买钱包 · 0'), findsNothing);
          }
          await reveal(dev);
          final title = tester.getRect(dev);
          final empty = tester.getRect(emptyDev);
          final edit = tester.getRect(editDev);
          expect(title.center.dy, closeTo(edit.center.dy, 3));
          expect(empty.left - title.right, inInclusiveRange(0, 28));
          expect(edit.left - empty.right, inInclusiveRange(0, 28));
          final devAmount = find.byKey(const ValueKey('launch-dev-amount'));
          expect(tester.getSize(devAmount).width, lessThanOrEqualTo(180));
          expect(tester.getCenter(walletText('Dev 首买')).dy, closeTo(tester.getCenter(devAmount).dy, 3));
          inside(devAmount);

          final imageTitle = find.text('代币图片');
          final imageButton = find.widgetWithText(TextButton, '选择图片');
          await reveal(imageButton);
          expect(
            tester.getRect(imageButton).left - tester.getRect(imageTitle).right,
            closeTo(10, 1),
          );
          // Short choice groups keep label-sized buttons instead of stretching.
          final choices = find.byType(OptionPair<bool>);
          for (final element in choices.evaluate().toList()) {
            final buttons = find.descendant(
              of: find.byWidget(element.widget),
              matching: find.byType(TextButton),
            );
            for (final button in buttons.evaluate()) {
              final finder = find.byWidget(button.widget);
              expect(tester.getSize(finder).width, lessThanOrEqualTo(180));
            }
          }
          if (selected != 2) {
            final pool = select('底池代币');
            await reveal(pool);
            expect(tester.getSize(pool).width, lessThanOrEqualTo(280));
            inside(pool);
          }
          if (selected == 0) {
            final category = select('分类');
            await reveal(category);
            expect(tester.getSize(category).width, lessThanOrEqualTo(280));
            final pool = select('底池代币');
            if (width >= 1000)
              expect(
                tester.getTopLeft(category).dy,
                tester.getTopLeft(pool).dy,
              );
            expect(externalMode, findsNothing);
            final taxMode = find.widgetWithText(TextButton, '税币');
            await reveal(taxMode);
            await tester.tap(taxMode);
            await tester.pumpAndSettle();
            await reveal(externalMode);
            await tester.tap(externalMode);
            await tester.pumpAndSettle();
            final inner = find.widgetWithText(TextButton, '内盘购买钱包 · 0');
            final outer = find.widgetWithText(TextButton, '外盘购买钱包 · 0');
            await reveal(outer);
            inside(inner);
            inside(outer);
            final first = tester.getRect(inner);
            final second = tester.getRect(outer);
            if (width <= 390) {
              expect(first.height, greaterThanOrEqualTo(40));
              expect(second.height, greaterThanOrEqualTo(40));
            }
            final card = tester.getRect(wallets);
            final available = card.width - 2 * (first.left - card.left);
            if (first.width + second.width + 12 <= available) {
              expect(first.center.dy, closeTo(second.center.dy, 2));
              expect(second.left - first.right, inInclusiveRange(0, 20));
            }
            await tester.tap(outer);
            await tester.pumpAndSettle();
            expect(find.descendant(of: find.byType(KeyEditorPage), matching: find.text('外盘购买钱包')), findsOneWidget);
            await tester.tap(find.widgetWithText(TextButton, '取消'));
            await tester.pumpAndSettle();
            final normal = find.widgetWithText(TextButton, '普通币');
            await reveal(normal);
            await tester.tap(normal);
            await tester.pumpAndSettle();
            expect(find.text('外盘购买钱包 · 0'), findsNothing);
            expect(externalMode, findsNothing);
            await tester.tap(taxMode);
            await tester.pumpAndSettle();
          }
          if (selected != 2) {
            final tax = selected == 0 ? select('买入税 %') : input('买入税 %');
            await reveal(tax);
            expect(tester.getSize(tax).width, lessThanOrEqualTo(140));
            inside(tax);
          } else {
            final quote = select('Genius 底池目录');
            const customLabel = '底池币地址（留空为 BNB）';
            await reveal(quote);
            inside(quote);
            if (width >= 1000) {
              expect(tester.getSize(quote).width, greaterThan(280));
            }
            expect(find.text(customLabel), findsNothing);
            await tester.tap(quote);
            await tester.pumpAndSettle();
            final menu = find.byKey(const ValueKey('ui-select-menu'));
            await tester.enterText(
              find.descendant(of: menu, matching: find.byType(TextField)),
              '自定义',
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('自定义底池币'));
            await tester.pumpAndSettle();
            expect(find.text(customLabel), findsOneWidget);
            final recipient = input('收益地址');
            await reveal(recipient);
            expect(find.text('Genius m5.2'), findsOneWidget);
            final tax = input('创作者买税');
            expect(
              tester.getSize(input('创作者卖税')).width,
              lessThanOrEqualTo(160),
            );
            expect(tester.getSize(tax).width, lessThanOrEqualTo(160));
            expect(
              tester.getSize(recipient).width,
              greaterThan(tester.getSize(tax).width),
            );
          }
          final amount = input('贿赂费');
          await reveal(amount);
          expect(tester.getSize(amount).width, lessThanOrEqualTo(200));
          inside(amount);
          if (selected == 1) {
            await reveal(editDev);
            await tester.tap(editDev);
            await tester.pumpAndSettle();
            final editor = find.byType(KeyEditorPage);
            await tester.enterText(find.descendant(of: editor, matching: find.byType(TextField)), devKey);
            await tester.tap(find.descendant(of: editor, matching: find.widgetWithText(TextButton, '保存')));
            await tester.pumpAndSettle();
            expect(editor, findsNothing);
            await reveal(walletText(devAddress));
            expectFullAddress(tester, devAddress, within: wallets);
          }
          expect(tester.takeException(), isNull);
        }
        expect(
          requests.where((r) => r != '/api/v1/rpc/bsc' && r != '/api/v1/wallets/state' && r != 'creationCurve'),
          unorderedEquals(['/api/fourmeme', '/api/flap', 'customCatalog']),
        );
        expect(requests, contains('/api/v1/rpc/bsc'));
        expect(requests, contains('creationCurve'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
