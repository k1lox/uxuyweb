import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  for (final width in [320.0, 1440.0]) {
    testWidgets('pending launch shows the recovery action before the folded receipts at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeBackend();
      final client = api.client();
      final state = AppState(BackendClient(Uri.parse('http://fixture.test/'), client), MemoryKeyStore());
      final wallet = TradeWallet.import('test', '1'.padLeft(64, '0'));
      state.genius
        ..state = LaunchState.pending
        ..transactions = [
          for (var i = 1; i <= 298; i++)
            LaunchTx('交易 $i', wallet, wallet.address, Uint8List(0), BigInt.zero, 21000),
        ];
      addTearDown(() { state.dispose(); client.close(); });
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData.light()),
        home: Scaffold(body: LaunchPage(state: state, selectedPlatform: 2, onTrade: () {})),
      ));
      await tester.pumpAndSettle();
      final recover = find.text('查询原交易');
      final details = find.text('交易 · 298');
      expect(tester.getRect(recover).bottom, lessThan(900));
      expect(tester.getRect(recover).bottom, lessThan(tester.getRect(details).top));
      expect(find.text('交易 298'), findsNothing);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('交易 298'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(api.bundles, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'desktop launch keeps independent drafts across platform switches and resize',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = FakeBackend();
      final client = fake.client();
      final state = AppState(
        BackendClient(Uri.parse('http://fixture.test/'), client),
        MemoryKeyStore(),
      );
      final platform = ValueNotifier(1);
      addTearDown(() {
        state.dispose();
        client.close();
        platform.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: uxuyTheme(ThemeData.light()),
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: platform,
              builder: (_, selected, _) => LaunchPage(
                state: state,
                selectedPlatform: selected,
                onPlatformChanged: (value) => platform.value = value,
                onTrade: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final config = find.byKey(const ValueKey('launch-configuration'));
      final wallets = find.byKey(const ValueKey('launch-wallets'));
      expect(
        find.byKey(const ValueKey('launch-desktop-columns')),
        findsOneWidget,
      );
      expect(tester.getTopLeft(config).dy, tester.getTopLeft(wallets).dy);
      expect(
        tester.getTopLeft(wallets).dx,
        greaterThan(tester.getTopRight(config).dx),
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).first, 'Flap draft');

      platform.value = 2;
      await tester.pumpAndSettle();
      expect(find.text('Flap draft'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Genius draft');
      platform.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('Flap draft'), findsOneWidget);
      expect(find.text('Genius draft'), findsNothing);

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('launch-desktop-columns')),
        findsNothing,
      );
      expect(find.text('Flap draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      FocusManager.instance.primaryFocus?.unfocus();
      final page = tester.widget<ListView>(
        find.byKey(const PageStorageKey('launch-page-scroll')),
      );
      page.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Genius'));
      await tester.pumpAndSettle();
      expect(platform.value, 2);
      expect(find.text('Genius draft'), findsOneWidget);
      expect(fake.submitted, isEmpty);
      expect(fake.bundles, isEmpty);
      expect(fake.calls.where((path) => path.startsWith('routes')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
