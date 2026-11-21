import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/src/ui/wallet_overlap.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

void main() {
  late FakeBackend fake;
  late AppState state;

  setUp(() {
    fake = FakeBackend();
    state = AppState(
      BackendClient(Uri.parse('http://isolated.test/'), fake.client()),
      MemoryKeyStore(),
    );
  });
  tearDown(() => state.dispose());

  Future<void> mount(WidgetTester tester, double width, Locale locale) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData()),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (_, _) => ToolsPage(state: state),
          ),
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

  testWidgets(
    'wide tools keep short inputs and actions compact while addresses stay wide',
    (tester) async {
      await mount(tester, 1920, const Locale('zh'));
      expect(tester.getSize(find.byType(TextField).first).width, 104);
      await tester.enterText(find.byType(TextField).first, '2');
      await tap(tester, find.text('生成'));
      expect(find.text('加入新组'), findsNothing);
      for (final text in ['复制所选私钥', '复制所选地址']) {
        final control = find.widgetWithText(TextButton, text);
        expect(control, findsOneWidget);
        expect(tester.getSize(control).width, lessThan(220));
      }
      expect(
        state.generated.every((wallet) => !wallet.canReceiveFunds),
        isTrue,
      );

      await tap(tester, find.text('分发').first);
      expect(tester.getRect(find.text('编辑')).left - tester.getRect(find.text('未填写')).right,
          inInclusiveRange(0, 16));
      expect(
        tester.getSize(find.byType(TextField).first).width,
        greaterThan(600),
      );
      for (final range in find.byType(RangeRow).evaluate()) {
        expect(
          tester.getSize(find.byWidget(range.widget)).width,
          lessThanOrEqualTo(360),
        );
      }
      expect(
        tester.getSize(find.widgetWithText(TextButton, '一对多')).width,
        lessThan(180),
      );
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'BNB')).width,
        lessThan(180),
      );
      expect(
        tester.getSize(find.widgetWithText(FilledButton, '开始分发')).width,
        lessThan(220),
      );
      await tap(tester, find.text('归集').first);
      expect(tester.getRect(find.text('编辑')).left - tester.getRect(find.text('未填写')).right,
          inInclusiveRange(0, 16));
      expect(
        tester.getSize(find.byType(TextField).first).width,
        greaterThan(600),
      );
      expect(
        tester.getSize(find.widgetWithText(FilledButton, '开始归集')).width,
        lessThan(220),
      );
      expect(tester.takeException(), isNull);
      expect(fake.submitted, isEmpty);
      expect(fake.bundles, isEmpty);
    },
  );

  testWidgets('recovery actions keep content widths in a wide result panel', (
    tester,
  ) async {
    final sender = TradeWallet.import('synthetic', '0x${'1'.padLeft(64, '0')}');
    const recipient = '0x0000000000000000000000000000000000000055';
    final amount = BigInt.from(1000);
    state.transfers.current = TransferRun(
      label: '归集',
      asset: TransferAsset.bnb,
      rows: [Allocation(recipient: recipient, amount: amount, sender: sender)],
      legs: [
        TransferLeg(
          row: 0,
          from: sender,
          recipient: recipient,
          to: recipient,
          data: Uint8List(0),
          value: amount,
          amount: amount,
          gasLimit: 21000,
        ),
      ],
      gasPrice: BigInt.one,
    );
    await mount(tester, 1920, const Locale('zh'));
    await tap(tester, find.text('归集').first);
    final finish = find.widgetWithText(OutlinedButton, '结束');
    final retry = find.widgetWithText(FilledButton, '重试未完成');
    expect(finish, findsOneWidget);
    expect(retry, findsOneWidget);
    expect(find.widgetWithText(TextButton, sender.address), findsOneWidget);
    expect(tester.getSize(finish).width, lessThan(220));
    expect(tester.getSize(retry).width, lessThan(220));
    expect(tester.takeException(), isNull);
    expect(fake.submitted, isEmpty);
  });

  testWidgets('both tool tabs keep the original collection query after a new task', (tester) async {
    final first = TradeWallet.import('A', '0x${'1'.padLeft(64, '0')}');
    final second = TradeWallet.import('B', '0x${'2'.padLeft(64, '0')}');
    const recipient = '0x0000000000000000000000000000000000000055';
    for (final wallet in [first, second]) {
      fake.wallets[wallet.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': 0,
        'tokenBalance': '0',
        'routerAllowance': '0',
      };
    }
    final engine = state.transfers;
    final old = await engine.prepareCollection([first], recipient, TransferAsset.bnb);
    final hash = '0x${'ab' * 32}';
    old.legs.single..hash = hash..status = TransferStatus.unknown;
    engine.current = old;
    final next = await engine.prepareCollection([second], recipient, TransferAsset.bnb);
    await engine.execute(next);
    await mount(tester, 960, const Locale('zh'));
    await tap(tester, find.text('分发').first);
    final query = find.widgetWithText(FilledButton, '查询原转账');
    expect(query, findsOneWidget);
    await tap(tester, find.text('归集').first);
    expect(query, findsOneWidget);
    final before = fake.calls.length;
    await tap(tester, query);
    expect(fake.calls.skip(before), ['transactions/bsc/$hash']);
    expect(engine.current, same(next));
    expect(old.complete, isTrue);
    expect(query, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paired distribution summary counts the skipped source', (tester) async {
    final wallet = TradeWallet.import('fixture', '1'.padLeft(64, '0'));
    state.transfers.current = TransferRun(
      label: '多对多分发',
      asset: TransferAsset.bnb,
      rows: [Allocation(recipient: '0x${'2'.padLeft(40, '0')}', amount: BigInt.zero, sender: wallet)],
      legs: [],
      gasPrice: BigInt.one,
    );
    await mount(tester, 320, const Locale('zh'));
    await tap(tester, find.text('分发').first);
    expect(find.text('已跳过 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow overlap dialog scrolls through all conflicting public addresses and cancels the action', (tester) async {
    await mount(tester, 320, const Locale('zh'));
    final addresses = List.generate(75, (i) => '0x${(i + 1).toRadixString(16).padLeft(40, '0')}');
    final hold = Completer<void>();
    final lease = state.withWalletUse(owner: Object(), label: '待确认归集', addresses: addresses,
      action: () => hold.future);
    var ran = false;
    final second = withWalletUse(tester.element(find.byType(ToolsPage)), state,
      owner: Object(), label: '分发', addresses: addresses, action: () async => ran = true);
    await tester.pumpAndSettle();
    expect(find.text(addresses.first), findsOneWidget);
    final list = find.descendant(of: find.byType(UiDialog), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text(addresses.last), 320, scrollable: list.first);
    await tap(tester, find.text('关闭'));
    await second;
    expect(ran, isFalse);
    expect(fake.submitted, isEmpty);
    expect(tester.takeException(), isNull);
    hold.complete();
    await lease;
  });

  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets('short controls wrap at 320px in ${locale.languageCode}', (
      tester,
    ) async {
      await mount(tester, 320, locale);
      final en = locale.languageCode == 'en';
      await tester.enterText(find.byType(TextField).first, '2');
      await tap(tester, find.text(en ? 'Generate' : '生成'));
      expect(tester.takeException(), isNull);
      await tap(tester, find.text(en ? 'Distribute' : '分发').first);
      await tap(tester, find.text(en ? 'Many to many' : '多对多'));
      expect(tester.takeException(), isNull);
      await tap(tester, find.text(en ? 'Collect' : '归集').first);
      expect(tester.takeException(), isNull);
      expect(fake.submitted, isEmpty);
      expect(fake.bundles, isEmpty);
    });
  }
}
