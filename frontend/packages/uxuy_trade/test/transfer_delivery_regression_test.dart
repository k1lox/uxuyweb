import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

TradeWallet _testWallet(int index) => TradeWallet.import(
  'synthetic-$index',
  (420 + index).toRadixString(16).padLeft(64, '0'),
);

void _fund(FakeBackend b, TradeWallet w, {int units = 0}) {
  b.wallets[w.address.toLowerCase()] = {
    'nonce': 5,
    'native': '1000000000000000000',
    'tokenBalance': '$units',
    'routerAllowance': '0',
  };
}

class _NoTransferEvent extends FakeBackend {
  @override
  http.Client client() {
    final upstream = super.client();
    return MockClient((request) async {
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      final response = await http.Response.fromStream(
        await upstream.send(copy),
      );
      if (!request.url.path.endsWith('/bundles')) return response;
      // An ERC20 that returns false can produce a status-1 receipt without moving tokens.
      for (final raw in jsonDecode(request.body)['transactions'] as List) {
        chainReceipts[signatures[raw]!.$1]!['logs'] = [];
      }
      return response;
    });
  }
}

void main() {
  test('continuing an excluded interval distribution advances nonce for the next recipient', () async {
    final b = FakeBackend();
    final sender = _testWallet(1);
    _fund(b, sender);
    final recipients = [_testWallet(2).address, _testWallet(3).address];
    final log = ExecutionLog();
    final engine = TransferEngine(b.api(), log, sleep: (_) async {});
    final allocation = engine.drawOneToMany(
      sender,
      recipients,
      BigInt.one,
      BigInt.one,
    );
    final run = await engine.prepareDistribution(
      allocation,
      TransferAsset.bnb,
      source: sender,
      intervalMin: 1,
      intervalMax: 1,
    );
    b.onBundle = (_) { if (b.bundles.length == 3) engine.stop(); };
    b.receipts.addAll(List.filled(3, 'not_included'));
    await engine.execute(run);
    expect(run.statusOf(0), TransferStatus.notIncluded);
    expect(run.statusOf(1), TransferStatus.waiting);
    final original = run.legs.first.raw;
    await engine.execute(run);
    expect(run.legs.first.raw, original);
    expect(run.legs.first.status, TransferStatus.confirmed);
    expect(run.legs.map((leg) => leg.nonce), [
      5,
      6,
    ], reason: log.entries.map((l) => l.text).join('\n'));
    expect(run.complete, true);
  });

  test('a successful EVM receipt without token delivery cannot mark collection complete', () async {
    final b = _NoTransferEvent();
    final sender = _testWallet(11);
    _fund(b, sender, units: 73);
    final api = b.api();
    final engine = TransferEngine(api, ExecutionLog(), sleep: (_) async {});
    final run = await engine.prepareCollection(
      [sender],
      _testWallet(12).address,
      const TransferAsset(token, 'Synthetic', 6),
    );
    await engine.execute(run);
    expect(run.legs.single.hash, isNotNull);
    expect(
      run.complete,
      false,
      reason: 'The receipt contains no Transfer, balances remain unchanged and the requested delivery cannot be proved.',
    );
  });

  testWidgets(
    'final distribution confirmation displays a nonzero amount below six decimal places',
    (tester) async {
      final b = FakeBackend();
      final state = AppState(b.api(), MemoryKeyStore());
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: uxuyTheme(ThemeData()),
          home: Scaffold(body: ToolsPage(state: state)),
        ),
      );
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final source = _testWallet(31);
      _fund(b, source);
      await tap(find.text('分发').first);
      await tap(find.text('编辑'));
      await tester.enterText(
        find.descendant(
          of: find.byType(KeyEditorPage),
          matching: find.byType(TextField),
        ),
        source.exportPrivateKey(),
      );
      await tap(find.text('保存'));
      await tester.enterText(
        find.byType(TextField).first,
        _testWallet(32).address,
      );
      final amounts = find.descendant(
        of: find.byType(RangeRow).first,
        matching: find.byType(TextField),
      );
      await tester.enterText(amounts.at(0), '0.00000001');
      await tester.enterText(amounts.at(1), '0.00000001');
      await tap(find.byType(Checkbox).first);
      await tap(find.text('使用'));
      final startButton = find.text('开始分发');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final dialog = find.byType(UiDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('合计 0 BNB')),
        findsNothing,
        reason: '0.00000001 BNB is nonzero and must not be shown as a zero total in the final confirmation.',
      );
      expect(b.submitted, isEmpty);
    },
  );
}
