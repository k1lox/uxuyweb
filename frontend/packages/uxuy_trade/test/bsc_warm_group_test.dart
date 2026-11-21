import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  late AppState state;
  late FakeBackend backend;
  late TradeGroup g;
  late TradeWallet w;
  var now = DateTime(2026);
  setUp(() {
    now = DateTime(2026);
    backend = FakeBackend();
    state = AppState(
      backend.api(),
      MemoryKeyStore(),
      groupQuoteClock: () => now,
    )..token = const TokenMeta(token, 'PancakeSwap Token', 'CAKE', 18);
    w = TradeWallet.import('fixture', '1'.padLeft(64, '0'));
    backend.wallets[w.address.toLowerCase()] = {
      'native': '1000000000000000000',
      'tokenBalance': '10000',
      'routerAllowance': '0',
      'nonce': 0,
    };
    g = state.addGroup()
      ..wallets = [w]
      ..selected.add(w.address);
  });
  tearDown(() => state.dispose());
  test('a warm check is read only, binds all editable inputs, and expires 15 seconds after the first read', () async {
    final quote = await state.warmGroupQuote(g);
    expect(backend.signatures, isEmpty);
    expect(backend.bundles, isEmpty);
    g.min = '0.005';
    await expectLater(state.prepare(g, warmed: quote), throwsStateError);
    g.min = '0.01';
    now = now.add(const Duration(seconds: 15));
    await expectLater(state.prepare(g, warmed: quote), throwsStateError);
    g.min = 'bad input';
    final reads = backend.calls.length;
    await expectLater(state.warmGroupQuote(g), throwsFormatException);
    expect(backend.calls.length, reads);
    expect(backend.signatures, isEmpty);
    expect(backend.bundles, isEmpty);
  });
  test('a low-impact authorized sale cannot become an approval if allowance is revoked before check or execution', () async {
    g.setBuy(false);
    final row = backend.wallets[w.address.toLowerCase()]!;
    row['routerAllowance'] = '10000';
    final first = await state.warmGroupQuote(g);
    expect(first.needsApproval, isFalse);
    row['routerAllowance'] = '0';
    await expectLater(state.prepare(g, warmed: first), throwsStateError);
    expect(backend.signatures, isEmpty);
    row['routerAllowance'] = '10000';
    final next = await state.warmGroupQuote(g);
    final prepared = await state.prepare(g, warmed: next);
    row['routerAllowance'] = '0';
    final stopped = await state.start(g, prepared: prepared);
    expect(stopped.stopped, isTrue);
    expect(backend.signatures, isEmpty);
    expect(backend.bundles, isEmpty);
  });
  test('a linked warm check preserves the shown tranche, checks and confirms exact allowance only after the user acts', () async {
    final linked = state.addLinkedGroup(),
        buyer = TradeWallet.import('buyer', '2'.padLeft(64, '0')),
        relay = TradeWallet.import('relay', '3'.padLeft(64, '0'));
    linked.sellers = [w];
    linked.buyers = [buyer];
    linked.transitByBuyer[buyer.address.toLowerCase()] = relay;
    linked.min = '5';
    linked.max = '10';
    final preview = await state.warmGroupQuote(linked);
    expect(preview.needsApproval, isTrue);
    expect(backend.signatures, isEmpty);
    expect(backend.bundles, isEmpty);
    final checked = await state.prepareLinked(linked, warmed: preview);
    expect(checked.tranche, preview.linked!.tranche);
    expect(backend.bundles.single, hasLength(1));
    expect(
      backend.wallets[w.address.toLowerCase()]!['routerAllowance'],
      checked.total.toString(),
    );
    expect(linked.trader.progress, isNull);
    state.cancelPreparation(linked);
    expect(backend.bundles, hasLength(1));
  });
  test(
    'a confirmed snapshot cannot outlive its displayed amount, token or time',
    () async {
      final warm = await state.warmGroupQuote(g),
          ready = await state.prepare(g, warmed: warm);
      now = now.add(const Duration(seconds: 16));
      await expectLater(state.start(g, prepared: ready), throwsStateError);
      expect(backend.signatures, isEmpty);
    },
  );
  for (final sell in [true, false]) {
    testWidgets(
      'displayed ${sell ? 'sell' : 'buy'} quote needs the matching user action and no background signatures',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 1200);
        addTearDown(tester.view.reset);
        if (sell) g.setBuy(false);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: ListenableBuilder(
                listenable: state,
                builder: (_, _) => BatchPage(state: state),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await tester.pumpAndSettle();
        final proceeds = '0.000000000000001 ${sell ? 'BNB' : 'CAKE'}';
        final proceedsRow = find.ancestor(of: find.text('首笔预计到账'), matching: find.byType(Row)).first;
        expect(find.descendant(of: proceedsRow, matching: find.text(proceeds)), findsOneWidget);
        expect(backend.signatures, isEmpty);
        expect(backend.bundles, isEmpty);
        final action = find.text(sell ? '检查授权' : '确认买入');
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        if (sell) {
          expect(find.byType(UiDialog), findsOneWidget);
          expect(find.text('0.00000000000001 CAKE'), findsOneWidget);
          expect(find.text(proceeds), findsOneWidget);
          expect(backend.bundles.single, hasLength(1));
          expect(
            backend.wallets[w.address.toLowerCase()]!['routerAllowance'],
            '10000',
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(backend.bundles, hasLength(1));
        } else {
          expect(find.byType(UiDialog), findsNothing);
          expect(backend.bundles.single, hasLength(1));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
