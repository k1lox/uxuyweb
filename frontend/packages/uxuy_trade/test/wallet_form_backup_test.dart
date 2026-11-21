import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/wallet/wallet_backup.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/address_visibility.dart';
import 'support/fake_backend.dart';

class _TestDirectory implements WalletBackupDirectory {
  final records = <WalletBackupRecord>[];
  Completer<void>? writeGate;
  @override
  bool get supported => true;
  @override
  Future<String?> reconnect() async => null;
  @override
  Future<String?> chooseDirectory() async => 'fixture';
  @override
  Future<bool> checkAccess() async => true;
  @override
  Future<void> save(List<WalletBackupRecord> entries) async {
    await writeGate?.future;
    for (final record in entries) {
      final existing = records.indexWhere((r) => r.identity == record.identity);
      if (existing < 0) {
        records.add(record);
      } else if (records[existing].privateKey != record.privateKey) {
        throw const WalletBackupException('已有备份与当前记录不一致，已保留原文件');
      }
    }
  }
}

void main() {
  late _TestDirectory directory;
  late FakeBackend api;
  late AppState state;
  final first = '0x${'a'.padLeft(64, '0')}';
  final second = '0x${'b'.padLeft(64, '0')}';

  setUp(() {
    directory = _TestDirectory();
    api = FakeBackend();
    state = AppState(
      BackendClient(Uri.parse('http://fixture.test/'), api.client()),
      MemoryKeyStore(),
      backupDirectory: directory,
    );
  });
  tearDown(() => state.dispose());

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData()),
        home: Scaffold(body: page),
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

  Finder input() => find.descendant(
    of: find.byType(KeyEditorPage),
    matching: find.byType(TextField),
  );

  testWidgets(
    'one-to-many refuses distinct sources on save and reopens with only one copy of a duplicate source',
    (tester) async {
      await mount(tester, ToolsPage(state: state));
      await tap(tester, find.text('分发').first);
      await tap(tester, find.text('编辑'));
      await tester.enterText(input(), '$first\n$second');
      await tap(tester, find.text('仅暂存'));
      expect(find.textContaining('最多允许 1 个不同的来源钱包'), findsOneWidget);
      await tester.enterText(input(), '$first\n$first');
      await tap(tester, find.text('仅暂存'));
      expect(find.byType(KeyEditorPage), findsNothing);
      await tap(tester, find.text('编辑'));
      expect(tester.widget<TextField>(input()).controller!.text, first);
      await tap(tester, find.text('取消'));
      expect(api.bundles, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source editor preserves relay identities and restoration requires independent recipient verification',
    (tester) async {
      final recipient = TradeWallet.import('fixture', first).address;
      final relay = TradeWallet.import('fixture', second).address;
      final source = jsonEncode({
        'format': 'uagent-wallet-backup-v1',
        'category': 'tool-generated',
        'scope': '',
        'relatedAddress': null,
        'address': recipient,
        'privateKey': first,
      });
      final transit = jsonEncode({
        'format': 'uagent-wallet-backup-v1',
        'category': 'distribution-transit',
        'scope': '',
        'relatedAddress': recipient,
        'address': relay,
        'privateKey': second,
      });
      await state.walletBackup!.connect();
      await mount(tester, ToolsPage(state: state));
      await tap(tester, find.text('分发').first);
      await tap(tester, find.text('编辑'));
      await tester.enterText(input(), transit);
      await tap(tester, find.text('保存'));
      expect(find.textContaining('此备份含接收方'), findsOneWidget);
      expect(directory.records, isEmpty);
      await tester.enterText(input(), source);
      await tap(tester, find.text('保存'));
      expect(find.byType(KeyEditorPage), findsNothing);
      expect(directory.records.single.address, recipient);
      expect(
        directory.records.single.originalCategory,
        WalletBackupCategory.toolGenerated,
      );
      await tap(tester, find.text('恢复中转备份'));
      await tester.enterText(input().first, transit);
      await tester.enterText(input().last, relay);
      await tap(tester, find.text('恢复'));
      expect(find.textContaining('核对的接收地址'), findsOneWidget);
      expect(state.distributionTransits, isEmpty);
      await tester.enterText(input().last, recipient);
      await tap(tester, find.text('恢复'));
      expect(find.byType(KeyEditorPage), findsNothing);
      expect(
        state.distributionTransits[recipient.toLowerCase()]?.address,
        relay,
      );
      expect(directory.records.last.relatedAddress, recipient.toLowerCase());
      expect(
        directory.records.last.category,
        WalletBackupCategory.distributionTransit,
      );
      expect(api.bundles, isEmpty);
      expect(api.submitted, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [1440.0, 320.0]) {
    testWidgets(
      'combined JSON requires explicit ordinary use and one source in single-wallet forms at $width px',
      (tester) async {
        final third = '0x${'c'.padLeft(64, '0')}';
        final source = TradeWallet.import('fixture', first),
            other = TradeWallet.import('fixture', second);
        final relay = TradeWallet.import('fixture', third);
        Map<String, Object?> entry(
          TradeWallet w,
          String category, {
          String? to,
        }) => {
          'address': w.address,
          'privateKey': w.exportPrivateKey(),
          'purpose': '批量交易组',
          'usages': [
            {'category': category, 'scope': '', 'relatedAddress': to},
          ],
        };
        final archive = jsonEncode({
          'format': 'uagent-wallet-backup-v2',
          'wallets': [
            entry(source, 'tool-generated'),
            entry(other, 'tool-generated'),
            entry(relay, 'distribution-transit', to: source.address),
          ],
        });
        await state.walletBackup!.connect();
        await mount(tester, ToolsPage(state: state));
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        await tap(tester, find.text('分发').first);
        await tap(tester, find.text('编辑'));
        await tester.enterText(input(), archive);
        await tap(tester, find.text('保存'));
        expect(find.text('请选择本次要导入的备份用途或组别'), findsOneWidget);
        expect(directory.records, isEmpty);
        await tap(tester, find.text('选择备份用途或组别'));
        await tap(tester, find.text('工具生成钱包').last);
        await tap(tester, find.text('保存'));
        expect(find.text('请选择本次要导入的钱包'), findsOneWidget);
        expect(directory.records, isEmpty);
        await tap(tester, find.text('选择钱包地址'));
        await tap(tester, find.text(other.address).last);
        await tap(tester, find.text('保存'));
        expect(find.byType(KeyEditorPage), findsNothing);
        expect(directory.records.single.address, other.address);
        expect(
          directory.records.single.originalCategory,
          WalletBackupCategory.tradeGroup,
        );
        expect(
          directory.records.single.category,
          WalletBackupCategory.toolDistributionSource,
        );
        expect(state.distributionTransits, isEmpty);
        expect(api.submitted, isEmpty);
        expect(api.bundles, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'tool drafts retain valid keys across cancellation and connection',
    (tester) async {
      await mount(tester, ToolsPage(state: state));
      await tap(tester, find.text('分发').first);
      await tap(tester, find.text('编辑'));
      final invalid = '0x${'f' * 64}';
      await tester.enterText(
        input(),
        'source,$first\n$first\n$invalid\n$second,partial',
      );
      await tap(tester, find.text('取消'));
      expect(state.walletBackup!.pendingCount, 1);
      expect(directory.records, isEmpty);
      await state.walletBackup!.connect();
      expect(
        directory.records.single.category,
        WalletBackupCategory.toolDistributionSource,
      );
      expect(directory.records.single.privateKey, first);

      await tap(tester, find.text('归集').first);
      await tap(tester, find.text('编辑'));
      await tester.enterText(input(), second.substring(0, second.length - 1));
      expect(directory.records, hasLength(1));
      await tester.enterText(input(), second);
      await tester.pump(); // No time elapses for the 250 ms typing debounce.
      expect(directory.records.last.privateKey, second);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(directory.records, hasLength(2));
      expect(
        directory.records.last.category,
        WalletBackupCategory.toolCollectionSource,
      );
      expect(directory.records.last.privateKey, second);
      expect(find.text('未填写'), findsOneWidget);
      expect(api.submitted, isEmpty);
      expect(api.bundles, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same-length pastes are staged before reload and saving waits for disk',
    (tester) async {
      await mount(tester, ToolsPage(state: state));
      await tap(tester, find.text('归集').first);
      await tap(tester, find.text('编辑'));
      await tester.enterText(input(), first);
      await tester.enterText(input(), second);
      await tester
          .pump(); // The web unload guard already sees both pending keys.
      expect(state.walletBackup!.pendingCount, 2);

      final gate = directory.writeGate = Completer<void>();
      final connecting = state.walletBackup!.connect();
      await tester.pump();
      final third = '0x${'c'.padLeft(64, '0')}';
      await tester.enterText(input(), third.substring(0, third.length - 1));
      await tester.enterText(input(), third);
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(state.walletBackup!.pendingCount, 3);
      expect(tester.widget<TextField>(input()).readOnly, isTrue);
      gate.complete();
      await connecting;
      await tester.pumpAndSettle();
      expect(find.byType(KeyEditorPage), findsNothing);
      expect(directory.records.map((e) => e.privateKey), [
        first,
        second,
        third,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'saving unchanged input rechecks every backup and keeps the editor open on conflict',
    (tester) async {
      await mount(tester, ToolsPage(state: state));
      await tap(tester, find.text('归集').first);
      await tap(tester, find.text('编辑'));
      await tester.enterText(input(), '$first\n$second');
      await tester.pump();
      expect(find.text('仅暂存'), findsOneWidget);
      await tap(
        tester,
        find.descendant(
          of: find.byType(KeyEditorPage),
          matching: find.text('连接本地文件夹'),
        ),
      );
      expect(directory.records, hasLength(2));
      await tap(tester, find.text('保存'));
      expect(find.byType(KeyEditorPage), findsNothing);

      final original = directory.records.singleWhere(
        (r) => r.privateKey == first,
      );
      final index = directory.records.indexOf(original);
      directory.records[index] = WalletBackupRecord(
        category: original.category,
        scope: original.scope,
        address: original.address,
        relatedAddress: original.relatedAddress,
        privateKey: second,
      );
      await tap(tester, find.text('编辑'));
      expect(
        tester.widget<TextField>(input()).controller!.text,
        '$first\n$second',
      );
      await tap(tester, find.text('保存'));
      expect(find.byType(KeyEditorPage), findsOneWidget);
      expect(find.textContaining('已有备份与当前记录不一致'), findsWidgets);
      expect(find.text('仅暂存'), findsNothing);
      expect(directory.records[index].privateKey, second);

      directory.records[index] = original;
      await tap(tester, find.text('保存'));
      expect(find.byType(KeyEditorPage), findsNothing);
      expect(directory.records, hasLength(2));
      expect(api.submitted, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'launch summaries show every saved address after editing, switching and resizing',
    (tester) async {
      final platform = ValueNotifier(1);
      addTearDown(platform.dispose);
      await mount(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: platform,
          builder: (_, selected, _) => LaunchPage(
            state: state,
            selectedPlatform: selected,
            onTrade: () {},
          ),
        ),
      );
      final keys = [
        for (var i = 1; i <= 6; i++) '0x${i.toString().padLeft(64, '0')}',
      ];
      final addresses = [
        for (final key in keys) TradeWallet.import('fixture', key).address,
      ];
      Future<void> save(
        String role,
        String value, {
        bool cancel = false,
      }) async {
        await tap(tester, find.text(role));
        await tester.enterText(input(), value);
        await tap(tester, find.text(cancel ? '取消' : '仅暂存'));
        expect(find.byType(KeyEditorPage), findsNothing);
      }

      void expectNoSecrets() {
        for (final key in keys) {
          expect(
            find.textContaining(key.substring(2), findRichText: true),
            findsNothing,
          );
        }
      }

      await save('Dev 钱包', keys[0]);
      await save('Dev 钱包', keys[1], cancel: true);
      for (final width in [1440.0, 320.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        expectFullAddress(tester, addresses.first);
        expect(find.text(addresses[1]), findsNothing);
        expectNoSecrets();
        expect(tester.takeException(), isNull);
      }

      for (final selected in [0, 2, 1]) {
        platform.value = selected;
        await tester.pumpAndSettle();
        if (selected == 1) {
          expectFullAddress(tester, addresses.first);
        } else {
          for (final address in addresses) {
            expect(find.text(address), findsNothing);
          }
        }
        expectNoSecrets();
        expect(tester.takeException(), isNull);
      }
      expect(api.submitted, isEmpty);
      expect(api.bundles, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'all launch forms preserve platform and wallet role independently of trade validation',
    (tester) async {
      await state.walletBackup!.connect();
      final platform = ValueNotifier(0);
      addTearDown(platform.dispose);
      await mount(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: platform,
          builder: (_, selected, _) => LaunchPage(
            state: state,
            selectedPlatform: selected,
            onTrade: () {},
          ),
        ),
      );
      for (final (index, scope) in ['FourMeme', 'Flap', 'Genius'].indexed) {
        platform.value = index;
        await tester.pumpAndSettle();
        await tap(tester, find.text('Dev 钱包'));
        await tester.enterText(input(), '$first，bad-amount\nshort,$second');
        await tap(tester, find.text('取消'));
        final record = directory.records.last;
        expect(record.category, WalletBackupCategory.launchDev);
        expect(record.scope, scope);
        expect(record.privateKey, first);
      }
      expect(directory.records, hasLength(3));
      expect(api.submitted, isEmpty);
      expect(api.bundles, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
