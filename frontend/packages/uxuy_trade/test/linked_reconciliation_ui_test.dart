import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/linked_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

class _InterruptedReceiptRead extends FakeBackend {
  _InterruptedReceiptRead(this.failingBundle);
  final int failingBundle;
  var fail = true;
  var failedReads = 0;

  @override
  http.Client client() {
    final backend = super.client();
    return MockClient((req) async {
      if (fail &&
          bundles.length == failingBundle &&
          req.url.path.endsWith('/rpc/bsc') &&
          (jsonDecode(req.body) as List).every(
            (call) => call['method'] == 'eth_getTransactionReceipt',
          )) {
        failedReads++;
        return http.Response(
          '{"code":"UNAVAILABLE","message":"Test receipt outage","retryable":true}',
          503,
        );
      }
      final forwarded = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes;
      return http.Response.fromStream(await backend.send(forwarded));
    });
  }
}

void main() {
  for (final (side, language, width) in [
    ('sell', 'zh', 390.0),
    ('buy', 'en', 1440.0),
  ]) {
    testWidgets(
      '$side reconciliation warns only after silent retries, and query only reads',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final isSell = side == 'sell';
        final backend = _InterruptedReceiptRead(isSell ? 1 : 2);
        final state = AppState(backend.api(), MemoryKeyStore());
        addTearDown(state.dispose);
        await state.init();
        state.token = const TokenMeta(token, 'Test', 'TST', 18);
        final g = state.addLinkedGroup();
        TradeWallet key(int n) => TradeWallet.import(
          'T$n',
          '0x${n.toRadixString(16).padLeft(64, '0')}',
        );
        final seller = key(1), buyer = key(2), relay = key(3);
        g.sellers = [seller];
        g.buyers = [buyer];
        g.transitByBuyer[buyer.address.toLowerCase()] = relay;
        final one = BigInt.from(10).pow(18);
        void put(TradeWallet wallet, BigInt native, int units) {
          backend.wallets[wallet.address.toLowerCase()] = {
            'native': '$native',
            'nonce': 1,
            'tokenBalance': '$units',
            'routerAllowance': '${BigInt.two.pow(255)}',
          };
        }

        put(seller, one, 1000);
        put(buyer, one, 0);
        put(relay, BigInt.zero, 0);
        backend.onBundle = (_) {
          if (backend.bundles.length == 1) {
            put(seller, one + one ~/ BigInt.from(10), 500);
          } else {
            put(buyer, one - one ~/ BigInt.from(10), 500);
          }
        };
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: uxuyTheme(ThemeData(useMaterial3: true)),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: state,
                builder: (_, _) => BatchPage(state: state),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final ctx = tester.element(find.byType(LinkedGroupDetail));
        final warningText = t(ctx, '${side}_reconciliation_error');
        final cardStatus = find.textContaining(
          t(ctx, 'st_reconciliation_error'),
          findRichText: true,
        );
        final run = g.trader.run(
          LinkedPlan(
            token: token,
            market: null,
            sellers: [seller],
            buyers: [buyer],
            sizing: LinkedSizing.percent(5000),
            loop: false,
          ),
        );
        // Let the protocol polls complete. From the first failed accounting read,
        // advance the actual widget clock by each scheduled retry interval.
        for (var i = 0; i < 30 && backend.failedReads == 0; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(backend.failedReads, 1);
        for (final seconds in [1, 2]) {
          await tester.pump(Duration(seconds: seconds));
          expect(find.text(warningText), findsNothing);
          expect(cardStatus, findsNothing);
          expect(find.text(t(ctx, 'stop')), findsOneWidget);
        }
        await tester.pump(const Duration(seconds: 4));
        await run;
        await tester.pump();
        expect(backend.failedReads, 4);
        expect(find.text(warningText), findsOneWidget);
        expect(cardStatus, findsOneWidget);
        expect(find.text('${t(ctx, 'to_buy_back')} —'), findsOneWidget);
        if (isSell) {
          expect(find.text('${t(ctx, 'received_total')} —'), findsOneWidget);
        }
        final noticeRect = tester.getRect(find.text(warningText));
        expect(noticeRect.left, greaterThanOrEqualTo(0));
        expect(noticeRect.right, lessThanOrEqualTo(width));
        expect(find.text(t(ctx, 'continue_round')), findsNothing);
        expect(find.text(t(ctx, 'end_round')), findsNothing);
        expect(find.text(t(ctx, 'query_hint')), findsNothing);
        final lookup = find.text('${t(ctx, 'query_tx')} · ${g.name}');
        expect(lookup, findsOneWidget);
        final sent = backend.submitted.toList();
        backend.fail = false;
        await tester.ensureVisible(lookup);
        await tester.pumpAndSettle();
        await tester.tap(lookup);
        await tester.pumpAndSettle();
        expect(find.text(warningText), findsNothing);
        expect(find.text(t(ctx, 'continue_round')), findsOneWidget);
        expect(backend.submitted, sent);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
