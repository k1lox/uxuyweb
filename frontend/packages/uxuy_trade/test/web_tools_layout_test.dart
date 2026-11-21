import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/generated_wallet_list.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/src/wallet/wallet_backup.dart' show WalletBackupException;
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/address_visibility.dart';
import 'support/fake_backend.dart';
import 'support/clipboard_fixture.dart';

class _HeldBalanceClient extends BackendClient {
  _HeldBalanceClient(FakeBackend fake)
      : super(Uri.parse('http://isolated.test/'), fake.client());

  final response = Completer<List<WalletState>>();
  int reads = 0;

  @override
  Future<TokenMeta> token(String address) async =>
      TokenMeta(address, 'Fixture', 'FIX', 0);

  @override
  Future<List<WalletState>> transferWalletStates(
    List<String> wallets, {
    String? token,
    bool refresh = false,
  }) {
    reads++;
    return response.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = ClipboardFixture();
  setUp(clipboard.install);
  tearDown(clipboard.uninstall);
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

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
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
    'desktop generation puts results below the controls; export still needs confirmation',
    (tester) async {
      await mount(tester, const Size(1440, 1000));
      await tester.enterText(find.byType(TextField), '3');
      await tap(tester, find.text('生成'));
      expect(state.generated.length, 3);
      expect(state.generated.every((w) => !w.canReceiveFunds), isTrue);
      expect(
        tester.getTopLeft(find.text('已生成 3')).dy,
        greaterThan(tester.getBottomLeft(find.widgetWithText(FilledButton, '生成')).dy),
      );
      expect(tester.takeException(), isNull);

      await tap(tester, find.text('复制所选私钥'));
      expect(state.generated.every((w) => !w.canReceiveFunds), isTrue);
      await tap(tester, find.text('取消'));
      expect(state.generated.every((w) => !w.canReceiveFunds), isTrue);
      expect(clipboard.writes, isEmpty);
      await tap(tester, find.text('复制所选私钥'));
      await tap(tester, find.text('确认'));
      expect(state.generated.every((w) => w.canReceiveFunds), isTrue);
      expect(clipboard.writes, hasLength(1));
      expect(
        clipboard.writes.single.split('\n'),
        [for (final wallet in state.generated) wallet.exportPrivateKey()],
      );
      expect(fake.submitted, isEmpty);
      expect(fake.bundles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stop generation keeps the current count and allows generating another group', (tester) async {
    await state.generate(1);
    await mount(tester, const Size(1440, 1000));
    final first = state.generatedBatches.single;
    await tester.enterText(find.byType(TextField), '5000');
    await tester.tap(find.text('生成'));
    await tester.pump();
    final stop = find.text('停止生成');
    expect(stop, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    final completed = state.generatedWalletCount;
    expect(completed, inInclusiveRange(1, 4999));
    expect(find.text('已生成 $completed / 5000'), findsOneWidget);
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(stop, findsNothing);
    expect(state.generatedBatches.first, same(first));
    expect(state.generatedBatches.last.wallets, hasLength(completed));
    expect(find.text('第 2 组'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1');
    await tap(tester, find.text('生成'));
    expect(state.generatedBatches.map((b) => b.wallets.length), [1, completed, 1]);
    expect(fake.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting a backed-up group requires confirming the selected group', (tester) async {
    final old = await state.generate(1);
    final retained = await state.generate(1);
    final group = state.generatedBatches.first;
    await expectLater(state.deleteGeneratedBatch(group), throwsA(isA<WalletBackupException>()));
    expect(state.generatedBatches, hasLength(2));
    state.markKeysCopied(old);
    await mount(tester, const Size(1440, 1000));
    final pendingPanel = find.byKey(ObjectKey(state.generatedBatches.last.wallets));
    final pendingDelete = find.descendant(
      of: pendingPanel,
      matching: find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除组'),
    );
    expect(tester.widget<IconButton>(pendingDelete).onPressed, isNull);
    final panel = find.byKey(ObjectKey(group.wallets));
    final remove = find.descendant(of: panel, matching: find.byTooltip('删除组'));
    await tap(tester, remove);
    final confirm = find.byType(UiDialog);
    expect(find.descendant(of: confirm, matching: find.text('删除钱包组')), findsOneWidget);
    await tap(tester, find.descendant(of: confirm, matching: find.text('取消')));
    expect(state.generatedBatches, hasLength(2));
    await tap(tester, remove);
    await tap(tester, find.descendant(of: confirm, matching: find.text('确认删除')));
    expect(find.text('第 1 组'), findsNothing);
    expect(find.text('第 2 组'), findsOneWidget);
    expect(state.generatedBatches.single.wallets, retained);
    await tester.enterText(find.byType(TextField), '1');
    await tap(tester, find.text('生成'));
    expect(state.generatedBatches.map((b) => b.name), ['第 2 组', '第 3 组']);
    expect(tester.takeException(), isNull);
  });

  // Workspace widths after the desktop sidebar has taken its share.
  for (final workspaceWidth in [780.0, 1196.0]) {
    testWidgets('desktop wallet groups fill equal columns in generation order below the toolbar at $workspaceWidth', (tester) async {
      await tester.runAsync(() async {
        for (final count in [1, 4, 3, 1, 1]) {
          await state.generate(count);
        }
      });
      // Keep the full grid mounted so all panel bounds use the same viewport.
      await mount(tester, Size(workspaceWidth, 1800));
      Finder card(int number) =>
          find.ancestor(of: find.text('第 $number 组'), matching: find.byType(Panel));

      final generate = tester.getRect(find.widgetWithText(FilledButton, '生成'));
      final count = tester.getRect(find.byType(TextField));
      final bounds = [for (var i = 1; i <= 5; i++) tester.getRect(card(i))];
      final [first, second, third, fourth, fifth] = bounds;

      expect(generate.center.dy, closeTo(count.center.dy, 1));
      expect(first.top, greaterThan(generate.bottom));
      expect(second.top, closeTo(first.top, 1));
      expect(second.left, greaterThan(first.right));
      for (final rect in bounds.skip(1)) {
        expect(rect.width, closeTo(first.width, 1));
      }
      expect(third.left, closeTo(first.left, 1));
      expect(fourth.left, closeTo(second.left, 1));
      expect(fourth.top, closeTo(third.top, 1));
      expect(third.top, greaterThan(first.bottom));
      expect(third.top, greaterThan(second.bottom));
      expect(fifth.left, closeTo(first.left, 1));
      expect(fifth.top, greaterThan(third.bottom));
      expect(fifth.top, greaterThan(fourth.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  Finder selectedWallet(TradeWallet wallet) =>
      find.byKey(ValueKey('generated-select-${wallet.address}'));
  testWidgets('selected address TXT excludes every key; private TXT requires explicit confirmation', (tester) async {
    state.dispose();
    final files=<(String,String)>[];
    state=AppState(fake.api(),MemoryKeyStore(),downloadText:(name,contents)=>files.add((name,contents)));
    await mount(tester,const Size(1440,1000));
    await tester.enterText(find.byType(TextField),'2');
    await tap(tester,find.text('生成'));
    await tap(tester,find.byTooltip('下载 TXT'));
    await tap(tester,find.text('下载公开地址 TXT'));
    expect(files.single.$2.trim().split('\n'),[for(final w in state.generated)w.address]);
    expect(files.single.$2.contains(state.generated.first.exportPrivateKey()),false);
    await tap(tester,find.byTooltip('下载 TXT'));
    await tap(tester,find.text('下载私钥 TXT'));
    await tap(tester,find.text('取消'));expect(files,hasLength(1));
    await tap(tester,find.byTooltip('下载 TXT'));
    await tap(tester,find.text('下载私钥 TXT'));
    await tap(tester,find.text('确认'));
    expect(files.last.$2.trim().split('\n'),[for(final w in state.generated)w.exportPrivateKey()]);
    expect(state.generated.every((w)=>!w.canReceiveFunds),true,reason:'a browser download is not verified directory backup');
  });

  final selectAll = find.byKey(const ValueKey('generated-select-all'));

  testWidgets('exports exactly the selected rows in display order', (tester) async {
    await mount(tester, const Size(1440, 1000));
    await tester.enterText(find.byType(TextField), '3');
    await tap(tester, find.text('生成'));
    final wallets = state.generated;
    expect(tester.widget<Checkbox>(selectAll).value, isTrue);
    expect(find.text('已选 3/3'), findsOneWidget);
    await tap(tester, selectedWallet(wallets[1]));
    expect(tester.widget<Checkbox>(selectAll).value, isNull);
    expect(find.text('已选 2/3'), findsOneWidget);
    final subset = [wallets.first, wallets.last];
    await tap(tester, find.text('复制所选地址'));
    expect(clipboard.writes.single, subset.map((w) => w.address).join('\n'));
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    await tap(tester, find.text('复制所选私钥'));
    await tap(tester, find.text('确认'));
    expect(clipboard.writes.last, subset.map((w) => w.exportPrivateKey()).join('\n'));
    expect(wallets.map((w) => w.canReceiveFunds), [true, false, true]);

    await tap(tester, selectAll);
    expect(tester.widget<Checkbox>(selectAll).value, isTrue);
    await tap(tester, find.text('全选'));
    expect(tester.widget<Checkbox>(selectAll).value, isFalse);
    expect(find.text('已选 0/3'), findsOneWidget);
    for (final label in ['复制所选地址', '复制所选私钥']) {
      final control = find.widgetWithText(TextButton, label);
      expect(tester.widget<TextButton>(control).onPressed, isNull);
      await tap(tester, control);
    }
    expect(find.text('确认'), findsNothing);
    expect(clipboard.writes, hasLength(2));
    await tap(tester, selectAll);
    await tap(tester, find.text('复制所选地址'));
    expect(clipboard.writes.last, wallets.map((w) => w.address).join('\n'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('generation appends groups; each group keeps its own selection, export and backup status', (tester) async {
    state.dispose();
    final downloads = <String>[];
    state = AppState(fake.api(), MemoryKeyStore(), downloadText: (_, text) => downloads.add(text));
    await mount(tester, const Size(1440, 1000));
    await tester.enterText(find.byType(TextField), '3');
    await tap(tester, find.text('生成'));
    final first = List.of(state.generated);
    await tap(tester, selectedWallet(first[1]));
    await tap(tester, find.byTooltip('查看私钥').first);
    expect(find.text(first.first.exportPrivateKey()), findsOneWidget);
    await tap(tester, find.text('生成'));
    final second = List.of(state.generated);
    expect(second.map((w) => w.label), ['N1', 'N2', 'N3']);
    final firstHeading = find.text('第 1 组');
    final secondHeading = find.text('第 2 组');
    expect(tester.getTopLeft(firstHeading).dy, closeTo(tester.getTopLeft(secondHeading).dy, 1));
    expect(tester.getTopRight(firstHeading).dx, lessThan(tester.getTopLeft(secondHeading).dx));
    expect(find.text('已选 2/3'), findsOneWidget);
    expect(find.text('已选 3/3'), findsOneWidget);

    for (final batch in [first, second]) {
      for (var i = 0; i < batch.length; i++) {
        final row = find.byKey(ValueKey(batch[i].address));
        expect(find.descendant(of: row, matching: find.text('${i + 1}')), findsOneWidget);
        expect(find.text(batch[i].exportPrivateKey()), findsNothing);
      }
    }
    final oldSelected = [first.first, first.last];
    await tap(tester, find.text('复制所选地址').first);
    expect(clipboard.writes.single, oldSelected.map((w) => w.address).join('\n'));
    // Selecting all of the old group must not alter the new group's selection.
    await tap(tester, selectedWallet(second.first));
    await tap(tester, find.text('全选').first);
    expect(tester.widget<Checkbox>(selectedWallet(second.first)).value, isFalse);
    expect(tester.widget<Checkbox>(selectedWallet(first[1])).value, isTrue);
    await tap(tester, find.byTooltip('下载 TXT').last);
    await tap(tester, find.text('下载公开地址 TXT'));
    expect(downloads.single.trim().split('\n'), second.skip(1).map((w) => w.address));
    await tap(tester, find.text('复制所选私钥').first);
    await tap(tester, find.text('确认'));
    expect(clipboard.writes.last, first.map((w) => w.exportPrivateKey()).join('\n'));
    expect(first.every((w) => w.canReceiveFunds), isTrue);
    expect(second.every((w) => !w.canReceiveFunds), isTrue);
    await tap(tester, find.text('分发').first);
    await tap(tester, find.text('生成私钥').first);
    expect(firstHeading, findsOneWidget);
    expect(secondHeading, findsOneWidget);
    expect(tester.widget<Checkbox>(selectedWallet(second.first)).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming one generated group preserves its wallets and the next group', (tester) async {
    await mount(tester, const Size(1440, 1000));
    await tester.enterText(find.byType(TextField), '1');
    await tap(tester, find.text('生成'));
    await tap(tester, find.text('生成'));
    final first = state.generatedBatches.first;
    final second = state.generatedBatches.last;
    final firstAddress = first.wallets.single.address;
    await tap(tester, find.byTooltip('修改组名').first);
    final nameField = find.descendant(of: find.byType(UiDialog), matching: find.byType(TextField));
    await tester.enterText(nameField, '临时输入');
    await tap(tester, find.text('取消'));
    expect(find.text('第 1 组'), findsOneWidget);
    await tap(tester, find.byTooltip('修改组名').first);
    await tester.enterText(nameField, '首买钱包');
    await tap(tester, find.text('保存'));
    expect(find.text('首买钱包'), findsOneWidget);
    expect(find.text('第 1 组'), findsNothing);
    expect(find.text('第 2 组'), findsOneWidget);
    expect(state.generatedBatches.map((b) => b.id), [first.id, second.id]);
    expect(state.generatedBatches.first.wallets.single.address, firstAddress);
    expect(tester.takeException(), isNull);
  });

  testWidgets('individual keys reveal on demand and copy only that wallet', (
    tester,
  ) async {
    await mount(tester, const Size(390, 844));
    await tester.enterText(find.byType(TextField), '3');
    await tap(tester, find.text('生成'));
    final wallets = state.generated;
    final first = wallets[0].exportPrivateKey();
    final second = wallets[1].exportPrivateKey();
    expect(find.text(first), findsNothing);
    expect(find.text(second), findsNothing);
    await tap(tester, find.byTooltip('查看私钥').first);
    expect(find.text(first), findsOneWidget);
    expect(clipboard.writes, isEmpty);
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    await tap(tester, find.byTooltip('查看私钥').first);
    expect(find.text(first), findsNothing);
    expect(find.text(second), findsOneWidget);
    await tap(tester, find.byTooltip('隐藏私钥'));
    expect(find.text(second), findsNothing);
    await tap(tester, selectedWallet(wallets[1]));
    await tap(tester, find.byTooltip('复制地址').at(1));
    expect(clipboard.writes.single, wallets[1].address);
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    await tap(tester, find.byTooltip('复制私钥').at(1));
    expect(clipboard.writes, [wallets[1].address, second]);
    expect(wallets.map((w) => w.canReceiveFunds), [false, true, false]);
    expect(find.text(second), findsNothing);
    expect(fake.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revealed key is hidden after navigating away and returning', (
    tester,
  ) async {
    final wallet = TradeWallet.import('sample', '1'.padLeft(64, '0'));
    final page = ValueNotifier(0);
    addTearDown(page.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: page,
          builder: (_, index, list) => IndexedStack(
            index: index,
            children: [list!, const SizedBox.shrink()],
          ),
          child: GeneratedWalletList(wallets: [wallet], onKeyCopied: (_) {}),
        ),
      ),
    ));
    await tap(tester, find.byTooltip('Show private key'));
    expect(find.text(wallet.exportPrivateKey()), findsOneWidget);
    page.value = 1;
    await tester.pumpAndSettle();
    page.value = 0;
    await tester.pumpAndSettle();
    expect(find.text(wallet.exportPrivateKey()), findsNothing);
  });

  testWidgets('failed single-wallet clipboard write keeps backup pending', (
    tester,
  ) async {
    await mount(tester, const Size(1440, 1000));
    await tester.enterText(find.byType(TextField), '2');
    await tap(tester, find.text('生成'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'isolated_clipboard_denied');
          }
          return null;
        });
    await tap(tester, find.byTooltip('复制私钥').first);
    expect(state.generated.every((w) => !w.canReceiveFunds), isTrue);
    expect(clipboard.writes, isEmpty);
    expect(find.textContaining('复制失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long generated list lazily renders and can copy its last key', (
    tester,
  ) async {
    await tester.runAsync(() => state.generate(120));
    await mount(tester, const Size(320, 640));
    expect(find.byTooltip('复制私钥').evaluate().length, lessThan(30));
    final list = find.ancestor(
      of: find.byTooltip('复制私钥').first, matching: find.byType(Scrollable),
    ).first;
    tester.state<ScrollableState>(list).position.jumpTo(
      tester.state<ScrollableState>(list).position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    final last = state.generated.last;
    final row = find.byKey(ValueKey(last.address));
    await tap(tester, find.descendant(of: row, matching: find.byTooltip('查看私钥')));
    expect(find.text(last.exportPrivateKey()), findsOneWidget);
    await tap(tester, find.descendant(of: row, matching: find.byTooltip('复制私钥')));
    expect(clipboard.writes, [last.exportPrivateKey()]);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '2');
    await tap(tester, find.text('生成'));
    final fresh = state.generated;
    expect(fresh, hasLength(2));
    final newList = find.ancestor(
      of: selectedWallet(fresh.first), matching: find.byType(Scrollable),
    ).first;
    expect(tester.state<ScrollableState>(newList).position.pixels, 0);
    expect(state.generatedBatches.first.wallets.last, same(last));
    expect(find.text(last.exportPrivateKey()), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop distribution blocks unbacked relays without sending', (
    tester,
  ) async {
    await mount(tester, const Size(1440, 1000));
    await tap(tester, find.text('分发').first);
    await tap(tester, find.text('编辑'));
    final keyField = find.descendant(
      of: find.byType(KeyEditorPage),
      matching: find.byType(TextField),
    );
    final key = '0x${'1'.padLeft(64, '0')}';
    final source = TradeWallet.import('fixture', key).address;
    const destination = '0x0000000000000000000000000000000000000055';
    await tester.enterText(keyField, key);
    await tap(tester, find.text('保存'));
    expectFullAddress(tester, source);
    await tester.enterText(find.byType(TextField).first, destination);
    final amounts = find.descendant(
      of: find.byType(RangeRow).first,
      matching: find.byType(TextField),
    );
    await tester.enterText(amounts.at(0), '0.01');
    await tester.enterText(amounts.at(1), '0.01');
    await tap(tester, find.text('使用'));
    expect(state.distributionTransits.length, 1);
    expect(state.distributionTransits.values.single.canReceiveFunds, isFalse);
    expect(find.textContaining('分发明细 · 1'), findsOneWidget);
    final details = find.ancestor(
      of: find.textContaining('分发明细 · 1'),
      matching: find.byType(Column),
    ).first;
    for (final width in [1440.0, 390.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pumpAndSettle();
      expectFullAddress(tester, source);
      expectFullAddress(tester, destination, within: details);
      expect(find.textContaining(key.substring(2), findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tap(tester, find.text('开始分发'));
    expect(find.text('中转地址会接收资金，请先复制保存本次中转私钥'), findsOneWidget);
    expect(fake.submitted, isEmpty);
    expect(fake.bundles, isEmpty);
    expect(tester.takeException(), isNull);
  });

  Future<void> editToolSource(WidgetTester tester, int keyIndex) async {
    final key = keyIndex.toRadixString(16).padLeft(64, '0');
    final address = TradeWallet.import('fixture', key).address.toLowerCase();
    fake.wallets[address] = {
      'native': (BigInt.from(keyIndex) * BigInt.from(10).pow(18)).toString(),
      'nonce': 0,
    };
    await tap(tester, find.text('编辑'));
    final editor = find.descendant(
      of: find.byType(KeyEditorPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(editor, key);
    await tap(tester, find.text('保存'));
  }

  for (final assetText in [
    '',
    '   ',
    'BNB',
    'not-an-address',
    '0x0000000000000000000000000000000000000000',
  ]) {
    testWidgets('ERC20 collection refuses a non-contract input [$assetText]', (
      tester,
    ) async {
      await mount(tester, const Size(1440, 1000));
      await tap(tester, find.text('归集').first);
      await editToolSource(tester, 1);
      await tester.enterText(
        find.byType(TextField).first,
        '0x0000000000000000000000000000000000000055',
      );
      await tap(tester, find.text('代币'));
      await tester.enterText(find.byType(TextField).last, assetText);
      final start = find.text('开始归集');
      await tester.ensureVisible(start);
      await tester.tap(start);
      // The underlying action remains busy while its confirmation dialog is open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.bundles, isEmpty);
      final nativeTotal = find.descendant(
        of: find.byType(UiDialog),
        matching: find.textContaining(RegExp(r'合计.*BNB')),
      );
      expect(
        tester.widgetList<Text>(nativeTotal).map((t) => t.data),
        isEmpty,
        reason: 'In ERC20 mode no input may prepare a native-currency sweep',
      );
      expect(find.textContaining('请输入有效的代币地址'), findsOneWidget);
      expect(fake.calls.where((p) => p == 'wallets/state'), isEmpty);
    });
  }

  testWidgets('distribution requires a contract when token mode is selected', (
    tester,
  ) async {
    await mount(tester, const Size(1440, 1000));
    await tap(tester, find.text('分发').first);
    await editToolSource(tester, 1);
    await tester.enterText(
      find.byType(TextField).first,
      '0x0000000000000000000000000000000000000055',
    );
    await tap(tester, find.text('代币'));
    final amounts = find.descendant(
      of: find.byType(RangeRow).first,
      matching: find.byType(TextField),
    );
    await tester.enterText(amounts.first, '0.01');
    await tester.enterText(amounts.at(1), '0.01');
    await tap(tester, find.text('使用'));
    expect(fake.bundles, isEmpty);
    expect(
      find.textContaining('分发明细 · 1'),
      findsNothing,
      reason: 'An empty ERC20 address must not prepare a BNB allocation',
    );
    expect(find.textContaining('请输入有效的代币地址'), findsOneWidget);
  });

  testWidgets('replacing collection wallets invalidates the previous balance', (
    tester,
  ) async {
    final group = state.addGroup()
      ..wallets = [TradeWallet.import('Fixture', '1'.padLeft(64, '0'))];
    await mount(tester, const Size(1440, 1000));
    await tap(tester, find.text('归集').first);
    await editToolSource(tester, 1);
    await tap(tester, find.text('刷新余额'));
    expect(find.text('余额 1 BNB'), findsOneWidget);
    await editToolSource(tester, 2);
    expect(
      find.text('余额 1 BNB'),
      findsNothing,
      reason: 'The displayed balance belonged to the previous selection',
    );
    expect(fake.calls.where((p) => p == 'wallets/state'), hasLength(1));
    await tap(tester, find.text('刷新余额'));
    expect(find.text('余额 2 BNB'), findsOneWidget);
    await tap(tester, find.text('载入组'));
    await tap(tester, find.text('${group.name} · 1'));
    expect(find.text('余额 2 BNB'), findsNothing);
    expect(fake.calls.where((p) => p == 'wallets/state'), hasLength(2));
    await tap(tester, find.text('刷新余额'));
    expect(find.text('余额 1 BNB'), findsOneWidget);
    expect(fake.bundles, isEmpty);
  });

  for (final fails in [false, true]) {
    testWidgets('an edited collection ignores its late refresh (failure: $fails)', (tester) async {
      state.dispose();
      final api = _HeldBalanceClient(fake);
      state = AppState(api, MemoryKeyStore());
      await mount(tester, const Size(1440, 1000));
      await tap(tester, find.text('归集').first);
      await editToolSource(tester, 1);
      await tap(tester, find.text('代币'));
      final field = find.byType(TextField).last;
      const address = '0x0000000000000000000000000000000000000011';
      await tester.enterText(field, address);
      await tester.tap(find.text('刷新余额'));
      await tester.pump();
      expect(api.reads, 1);
      await tester.enterText(field, '0x0000000000000000000000000000000000000022');
      await tester.enterText(field, address);
      if (fails) {
        api.response.completeError(StateError('过期刷新失败'));
      } else {
        api.response.complete([WalletState(address, BigInt.zero, 0, BigInt.one, null)]);
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('余额 1 FIX'), findsNothing);
      expect(find.textContaining('过期刷新失败'), findsNothing);
      expect(api.reads, 1);
    });
  }

  for (final tool in ['分发', '归集']) {
    testWidgets('$tool refresh reads the current chain balance on every click', (tester) async {
      final key = '1'.padLeft(64, '0');
      final address = TradeWallet.import('Fixture', key).address.toLowerCase();
      final row = fake.wallets[address] = {
        'native': '1000000000000000000',
        'nonce': 0,
      };
      await mount(tester, const Size(1440, 1000));
      await tap(tester, find.text(tool).first);
      await tap(tester, find.text('编辑'));
      final editor = find.descendant(
        of: find.byType(KeyEditorPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(editor, key);
      await tap(tester, find.text('保存'));
      final refreshButton = find.text('刷新余额');
      int balanceReads() =>
          fake.calls.where((path) => path == 'wallets/state').length;
      expect(balanceReads(), 0);
      await tap(tester, refreshButton);
      expect(find.text('余额 1 BNB'), findsOneWidget);
      expect(balanceReads(), 1);
      // Refreshing alone must never increase the balance.
      await tap(tester, refreshButton);
      expect(find.text('余额 1 BNB'), findsOneWidget);
      expect(balanceReads(), 2);
      row['native'] = '2000000000000000000';
      await tap(tester, refreshButton);
      expect(find.text('余额 2 BNB'), findsOneWidget);
      expect(balanceReads(), 3);
      row['nonce'] = -1;
      await tap(tester, refreshButton);
      expect(find.textContaining('钱包余额或授权读取不完整'), findsOneWidget);
      expect(find.text('余额 2 BNB'), findsNothing);
      expect(balanceReads(), 4);
      // The user explicitly retries after a failed read. Only the simulated
      // chain balance changes. The local wallet and app state stay mounted.
      row['nonce'] = 1;
      row['native'] = '1500000000000000000';
      await tap(tester, refreshButton);
      expect(find.text('余额 1.5 BNB'), findsOneWidget);
      expect(balanceReads(), 5);
      expect(fake.submitted, isEmpty);
      expect(fake.bundles, isEmpty);
    });
  }

  for (final width in [390.0, 820.0]) {
    testWidgets('tools remain usable at width $width without overflow', (
      tester,
    ) async {
      await mount(tester, Size(width, 1000));
      await tester.enterText(find.byType(TextField), '2');
      await tap(tester, find.text('生成'));
      expect(find.text('已生成 2'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('已生成 2')).dy,
        greaterThan(tester.getTopLeft(find.text('数量')).dy),
      );
      await tap(tester, find.text('分发').first);
      await tap(tester, find.text('多对多'));
      expect(find.text('按顺序一一对应，数量须相同。'), findsOneWidget);
      expect(find.text('中转分发'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('归集').first);
      expect(find.text('归集方私钥'), findsOneWidget);
      await tester.ensureVisible(find.text('开始归集'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(fake.submitted, isEmpty);
    });
  }
}
