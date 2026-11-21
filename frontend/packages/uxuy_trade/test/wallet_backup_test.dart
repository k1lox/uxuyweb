import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/ui/folder_backup_control.dart';
import 'package:uxuy_trade/src/wallet/wallet_backup.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart' as fake;

TradeWallet key(int n) =>
    TradeWallet.import('fixture', n.toRadixString(16).padLeft(64, '0'));

class _Directory implements WalletBackupDirectory {
  @override
  bool supported = true;
  String? remembered, choice = 'local';
  final files = <String, Map<String, WalletBackupRecord>>{};
  final failures = <String>{};
  int pickCalls = 0, restoreCalls = 0, writeCalls = 0, simultaneous = 0;
  Completer<void>? gate, chooser;
  Completer<bool>? accessGate;
  bool writable = true;
  String? failCategory, lastFailedAddress;
  int accessChecks = 0;
  String? selected;

  @override
  Future<String?> reconnect() async {
    restoreCalls++;
    return selected = remembered;
  }

  @override
  Future<String?> chooseDirectory() async {
    pickCalls++;
    await chooser?.future;
    if (choice != null && !writable) {
      throw const WalletBackupPermissionException('请授予所选目录读写权限');
    }
    if (choice != null) selected = choice;
    return choice;
  }

  @override
  Future<bool> checkAccess() async {
    accessChecks++;
    return await accessGate?.future ?? (selected != null && writable);
  }

  @override
  Future<void> save(List<WalletBackupRecord> records) async {
    expect(simultaneous++, 0);
    writeCalls++;
    try {
      await gate?.future;
      if (!writable) {
        throw const WalletBackupPermissionException('备份目录授权已失效，请重新选择并授予读写权限');
      }
      final dir = files.putIfAbsent(selected!, () => {});
      for (final r in records) {
        // Emulate a partially committed batch followed by an unsafe I/O error.
        if (failCategory == r.category || failures.contains(r.address.toLowerCase())) {
          lastFailedAddress = r.address;
          throw StateError('IO: ${r.privateKey}');
        }
        final saved = dir.putIfAbsent(r.identity, () => r);
        if (saved.privateKey != r.privateKey) {
          throw const WalletBackupException('已有备份与当前记录不一致，已保留原文件');
        }
      }
    } finally {
      simultaneous--;
    }
  }
}

/// Reopens the same fake directory across separate application instances.
/// Group names live independently of the address files, just as in the bridge.
class _GroupDirectory extends _Directory implements GeneratedWalletDirectory {
  final _namesByFolder = <String, Map<String, String>>{};
  Map<String, String> get names => _namesByFolder.putIfAbsent(selected!, () => {});
  final _removedByFolder = <String, Set<String>>{};
  Set<String> get removed => _removedByFolder.putIfAbsent(selected!, () => {});
  bool rejectDelete = false;
  bool rejectRename = false;
  bool failGroupNameReadback = false;

  @override
  Future<List<GeneratedWalletBatch>> readGeneratedGroups() async {
    final groups = <String, List<TradeWallet>>{};
    for (final record in files[selected]?.values ?? const <WalletBackupRecord>[]) {
      if (record.category != WalletBackupCategory.toolGenerated) continue;
      final id = record.scope.isEmpty ? 'legacy' : record.scope;
      final members = groups.putIfAbsent(id, () => []);
      members.add(TradeWallet.import('N${members.length + 1}', record.privateKey));
    }
    final batches = <GeneratedWalletBatch>[];
    var number = 0;
    for (final entry in groups.entries) {
      number++;
      if (!removed.contains(entry.key)) {
        batches.add(GeneratedWalletBatch(
          id: entry.key, number: number, wallets: entry.value, storedName: names[entry.key],
        ));
      }
    }
    return batches;
  }

  @override
  Future<String> saveGeneratedBatch(List<WalletBackupRecord> records) async {
    final id = records.first.scope;
    expect(records.every((r) => r.scope == id && r.category == WalletBackupCategory.toolGenerated), isTrue);
    await save(records);
    final batch = (await readGeneratedGroups()).singleWhere((b) => b.id == id);
    names.putIfAbsent(id, () => batch.name);
    if (failGroupNameReadback) throw const WalletBackupException('组名回查失败');
    return names[id]!;
  }

  @override
  Future<void> deleteGeneratedGroup(String id, String? expectedName) async {
    if (rejectDelete || names[id] != expectedName) {
      throw const WalletBackupException('删除分组未通过回查');
    }
    removed.add(id);
  }

  @override
  Future<void> renameGeneratedGroup(String id, String? expectedName, String name) async {
    if (rejectRename || names[id] != expectedName) {
      throw const WalletBackupException('无法保存组名');
    }
    names[id] = name;
  }
}

class _PausedHistory extends _GroupDirectory implements GeneratedWalletProgressDirectory {
  var result = Completer<List<GeneratedWalletBatch>>();
  void Function(int, int)? report;

  @override
  Future<List<GeneratedWalletBatch>> readGeneratedGroups({
    void Function(int, int)? onProgress,
  }) {
    report = onProgress;
    return result.future;
  }
}

void main() {
  late _Directory dir;
  late fake.FakeBackend backend;
  late AppState state;
  late WalletBackupCoordinator backup;
  final backupError = isA<WalletBackupException>();
  setUp(() {
    dir = _Directory();
    backend = fake.FakeBackend();
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: dir);
    backup = state.walletBackup!;
  });
  tearDown(() {
    state.dispose();
    state.api.http_.close();
  });

  testWidgets('folder loading shows verified counts and resets after failure and empty restore', (tester) async {
    final folder = _PausedHistory()
      ..chooser = Completer<void>()
      ..remembered = 'local';
    final coordinator = WalletBackupCoordinator(folder);
    addTearDown(coordinator.dispose);
    var folderUpdates = 0;
    coordinator.addListener(() => folderUpdates++);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SizedBox(width: 224, child: FolderBackupControl(backup: coordinator)),
    )));
    final bars = find.byType(LinearProgressIndicator);
    double? value() => tester.widget<LinearProgressIndicator>(bars).value;

    await tester.tap(find.text('连接本地文件夹'));
    await tester.pump();
    expect(find.text('正在验证文件夹是否可写…'), findsOneWidget);
    expect(value(), isNull);
    folder.chooser!.complete();
    await tester.pump();
    expect(find.text('正在读取钱包列表…'), findsOneWidget);
    expect(value(), isNull);

    final updatesBeforeCounting = folderUpdates;
    folder.report!(0, 73);
    await tester.pump();
    expect(find.text('正在载入钱包'), findsOneWidget);
    expect(value(), 0);
    folder.report!(32, 73);
    await tester.pump();
    expect(find.textContaining('32 / 73'), findsOneWidget);
    expect(find.text('43%'), findsOneWidget);
    expect(find.byTooltip('选择私人文件夹，明文备份到 UAgent-wallets/wallets.json'), findsNothing);
    expect(value(), closeTo(32 / 73, .00001));
    expect(folderUpdates, updatesBeforeCounting);
    expect(coordinator.connected, isFalse);

    final reportPreviousLoad = folder.report!;
    folder.result.completeError(const WalletBackupException('钱包备份校验失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('钱包备份校验失败'), findsOneWidget);
    expect(bars, findsNothing);
    expect(coordinator.connected, isFalse);

    folder.result = Completer<List<GeneratedWalletBatch>>();
    final restored = coordinator.restore();
    await tester.pump();
    reportPreviousLoad(72, 73);
    expect(coordinator.walletLoadProgress.value, isNull);
    folder.report!(0, 0);
    await tester.pump();
    expect(find.text('正在读取钱包列表…'), findsOneWidget);
    expect(value(), isNull);
    expect(find.textContaining('/ 73'), findsNothing);
    folder.result.complete([]);
    await restored;
    await tester.pump();
    expect(find.text('已连接 · UAgent-wallets'), findsOneWidget);
    expect(bars, findsNothing);
    expect(coordinator.connected, isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
    'offline imported and generated wallets backfill; new relays wait for a writable folder',
    () async {
      final normal = state.addGroup(), linked = state.addLinkedGroup();
      final seller = key(1), buyer = key(2);
      await state.setKeys(normal, seller.exportPrivateKey());
      await state.setLinkedKeys(linked, sellers: true, text: seller.exportPrivateKey());
      await expectLater(state.setLinkedKeys(linked, sellers: false, text: buyer.exportPrivateKey()), throwsA(backupError));
      await expectLater(state.transitsFor([buyer.address]), throwsA(backupError));
      expect(linked.buyers, isEmpty);
      expect(linked.allTransits, isEmpty);
      expect(state.distributionTransits, isEmpty);
      final generated = (await state.generate(1)).single;
      final intoGroup = state.addGroup();
      await state.setKeys(intoGroup, generated.exportPrivateKey());
      expect(dir.writeCalls, 0);
      state.exportKeys([generated]);
      expect(generated.canReceiveFunds, isFalse);
      await expectLater(state.transfers.prepareCollection([buyer], generated.address, TransferAsset.bnb), throwsA(backupError));
      await expectLater(state.transfers.prepareDistribution(
        [Allocation(recipient: generated.address, amount: BigInt.one)], TransferAsset.bnb, source: seller,
      ), throwsA(backupError));
      expect(backend.submitted, isEmpty);
      await backup.connect();
      dir.gate = Completer<void>();
      final applying = state.setLinkedKeys(linked, sellers: false, text: buyer.exportPrivateKey());
      final distributing = state.transitsFor([buyer.address]);
      await Future<void>.delayed(Duration.zero);
      expect(linked.allTransits, isEmpty);
      expect(state.distributionTransits, isEmpty);
      dir.gate!.complete();
      await applying;
      final relay = linked.transits.single;
      final distribution = (await distributing).values.single;
      await state.setLinkedKeys(linked, sellers: false, text: '');
      state.removeGroup(linked);
      state.removeGroup(normal);
      final records = dir.files['local']!.values;
      expect(records.length, 7);
      expect(backup.pendingCount, 0);
      final associated = records.where((r) => r.relatedAddress != null);
      expect(associated.map((r) => r.relatedAddress!.toLowerCase()).toSet(), {
        buyer.address.toLowerCase(),
      });
      expect(associated.map((r) => r.category).toSet(), {
        WalletBackupCategory.linkedTransit,
        WalletBackupCategory.distributionTransit,
      });
      expect(
        records
            .where((r) => r.address == seller.address)
            .map((r) => r.scope)
            .toSet(),
        {normal.name, linked.name},
      );
      for (final r in records) {
        expect(TradeWallet.import('', r.privateKey).address, r.address);
      }
      expect(state.unbackedAddresses, isEmpty);
      expect(
        [relay, distribution, generated].every((w) => w.canReceiveFunds),
        isTrue,
      );
      expect(dir.pickCalls, 1);
    },
  );

  test('offline generation appends batches in order and backfills every wallet', () async {
    final first = await state.generate(2);
    final second = await state.generate(1);
    await expectLater(state.generate(0), throwsFormatException);
    expect(state.generated, orderedEquals(second));
    expect(first.map((w) => w.label), ['N1', 'N2']);
    expect(second.single.label, 'N1');
    expect(state.generatedBatches.map((b) => b.wallets), [first, second]);
    expect(state.generatedBatches.map((b) => b.name), ['第 1 组', '第 2 组']);
    expect(state.generatedBatches.map((b) => b.id).toSet(), hasLength(2));
    final all = [...first, ...second];
    final addresses = all.map((w) => w.address.toLowerCase()).toSet();
    expect(addresses, hasLength(3));
    expect(backup.pendingCount, 3);
    expect(state.unbackedAddresses, addresses);
    for (final wallet in all) {
      expect(() => state.requireReceivable([wallet.address]), throwsA(backupError));
    }
    expect(state.groups, isEmpty);
    await backup.connect();
    expect(dir.files['local']!.values.map((r) => r.address.toLowerCase()).toSet(), addresses);
    expect(state.generated, orderedEquals(second));
    expect(state.generatedBatches.map((b) => b.wallets), [first, second]);
    expect(all.every((w) => w.canReceiveFunds), isTrue);
  });

  test('late writes and retries preserve both displayed batches and their order', () async {
    await backup.connect();
    dir.gate = Completer<void>();
    final creatingFirst = state.generate(2);
    final first = List.of(state.generated);
    dir.failures.add(first.last.address.toLowerCase());
    await Future<void>.delayed(Duration.zero);
    expect(dir.simultaneous, 1);
    final creatingSecond = state.generate(1);
    final second = state.generated.single;
    dir.gate!.complete();
    await Future.wait([creatingFirst, creatingSecond]);
    expect(state.generated.single, same(second));
    expect(state.unbackedAddresses, contains(first.last.address.toLowerCase()));
    dir.failures.clear();
    await backup.retry();
    expect(state.generated.single, same(second));
    expect(state.generatedBatches.map((b) => b.wallets), [first, [second]]);
    expect(dir.files['local'], hasLength(3));
    expect([...first, second].every((w) => w.canReceiveFunds), isTrue);
    expect(backup.pendingCount, 0);
  });

  test('stopping before the first key leaves the previous group and backup intact', () async {
    await backup.connect();
    final first = await state.generate(1);
    final writes = dir.writeCalls;
    final generation = state.generate(5000);
    expect(state.generatingWallets, isTrue);
    expect(state.generatedWalletCount, 0);
    expect(state.generationTarget, 5000);
    state.stopGeneratingWallets();
    state.stopGeneratingWallets();
    expect(await generation, isEmpty);
    expect(state.generatingWallets, isFalse);
    expect(state.generatedBatches.single.wallets, first);
    expect(dir.writeCalls, writes);
    final next = await state.generate(2);
    expect(next, hasLength(2));
    expect(state.generatedBatches.map((g) => g.wallets), [first, next]);
  });

  test('a stopped batch saves just its finished wallets and stays locked until readback', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory()..remembered = 'local';
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    final coordinator = state.walletBackup!;
    await coordinator.connect();
    folder.gate = Completer<void>();
    folder.failGroupNameReadback = true;
    int? stoppedAt;
    final queued = Completer<void>();
    void observe() {
      if (state.generatingWallets && state.generatedWalletCount > 0 && stoppedAt == null) {
        stoppedAt = state.generatedWalletCount;
        state.stopGeneratingWallets();
      }
      if (!state.generatingWallets && coordinator.pendingCount > 0 && !queued.isCompleted) {
        queued.complete();
      }
    }
    state.addListener(observe);
    final generation = state.generate(256);
    await queued.future.timeout(const Duration(seconds: 10));
    state.removeListener(observe);
    final wallets = state.generatedBatches.single.wallets;
    expect(stoppedAt, inInclusiveRange(1, 255));
    expect(wallets, hasLength(stoppedAt!));
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    await expectLater(state.deleteGeneratedBatch(state.generatedBatches.single), throwsA(backupError));
    // A delayed second click must leave the pending disk write alone.
    state.stopGeneratingWallets();
    folder.gate!.complete();
    expect(await generation, orderedEquals(wallets));
    final addresses = wallets.map((w) => w.address).toList();
    expect(folder.files['local']!.values.map((r) => r.address), addresses);
    expect(coordinator.canRetry, isTrue);
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    folder.failGroupNameReadback = false;
    await coordinator.retry();
    expect(wallets.every((w) => w.canReceiveFunds), isTrue);
    await coordinator.connect();
    expect(state.generatedBatches.single.wallets.map((w) => w.address), addresses);
    expect(backend.submitted, isEmpty);
  });

  test('deleting a generated group waits for disk, retains its keys and survives reselecting the folder', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory()..remembered = 'local';
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    final coordinator = state.walletBackup!;
    await coordinator.connect();
    final old = await state.generate(2);
    final keep = await state.generate(1);
    final deletedId = state.generatedBatches.first.id;
    final keptId = state.generatedBatches.last.id;
    folder.rejectDelete = true;
    await expectLater(state.deleteGeneratedBatch(state.generatedBatches.first), throwsA(backupError));
    expect(folder.removed, isEmpty);
    expect(state.generatedBatches.map((b) => b.id), [deletedId, keptId]);

    folder.rejectDelete = false;
    await coordinator.connect();
    await state.deleteGeneratedBatch(state.generatedBatches.first);
    expect(folder.removed, {deletedId});
    expect(state.generatedBatches.single.id, keptId);
    final records = folder.files['local']!.values;
    for (final wallet in [...old, ...keep]) {
      final record = records.singleWhere((r) => r.address == wallet.address);
      expect(record.privateKey == wallet.exportPrivateKey(), isTrue);
    }
    state.dispose();
    state.api.http_.close();
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    await state.walletBackup!.restore();
    expect(state.generatedBatches.single.name, '第 2 组');
    await state.generate(1);
    expect(state.generatedBatches.map((g) => g.name), ['第 2 组', '第 3 组']);
  });

  test('verified group names survive a new app instance and a failed rename keeps the confirmed name', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory()..remembered = 'local';
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    await state.walletBackup!.connect();
    final first = await state.generate(2);
    final second = await state.generate(1);
    final original = state.generatedBatches.first;
    final id = original.id;
    final secondId = state.generatedBatches.last.id;
    expect(folder.names, {id: '第 1 组', secondId: '第 2 组'});
    final diskRecords = folder.files['local']!.values;
    expect(diskRecords.where((r) => r.scope == id).map((r) => r.address), first.map((w) => w.address));
    expect(diskRecords.where((r) => r.scope == secondId).single.address, second.single.address);
    await state.renameGeneratedBatch(original, '内盘钱包');
    expect(folder.names[id], '内盘钱包');
    expect(state.generatedBatches.map((b) => b.name), ['内盘钱包', '第 2 组']);
    folder.rejectRename = true;
    await expectLater(state.renameGeneratedBatch(state.generatedBatches.first, '未保存名称'), throwsA(backupError));
    expect(state.generatedBatches.first.name, '内盘钱包');
    expect(folder.names[id], '内盘钱包');
    folder.rejectRename = false;

    state.dispose();
    state.api.http_.close();
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    await state.walletBackup!.restore();
    expect(state.generatedBatches.map((b) => b.id), [id, secondId]);
    expect(state.generatedBatches.map((b) => b.name), ['内盘钱包', '第 2 组']);
    expect(state.generatedBatches.first.wallets.map((w) => w.address), first.map((w) => w.address));
    expect(state.generatedBatches.last.wallets.single.address, second.single.address);
    await state.walletBackup!.connect();
    expect(state.generatedBatches.map((b) => b.id), [id, secondId]);
    final third = await state.generate(1);
    expect(state.generatedBatches.map((b) => b.name), ['内盘钱包', '第 2 组', '第 3 组']);
    expect(state.generatedBatches.last.wallets.single.address, third.single.address);
  });

  test('a second window uses the verified directory name even when its local group count is stale', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory()..remembered = 'local';
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    final other = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    addTearDown(() {
      other.dispose();
      other.api.http_.close();
    });
    await state.walletBackup!.connect();
    await other.walletBackup!.restore();
    expect(other.generatedBatches, isEmpty);
    final firstAddress = (await state.generate(1)).single.address;
    final laterAddress = (await other.generate(1)).single.address;
    final later = other.generatedBatches.singleWhere((b) => b.wallets.single.address == laterAddress);
    expect(folder.names[firstAddress.toLowerCase()], '第 1 组');
    expect(folder.names[later.id], '第 2 组');
    expect(later.storedName, '第 2 组');
    expect(later.name, '第 2 组');
    // The directory requires the actual persisted name for its rename check.
    await other.renameGeneratedBatch(later, '后生成的钱包');
    await state.walletBackup!.connect();
    expect(state.generatedBatches.map((b) => b.name), ['第 1 组', '后生成的钱包']);
    expect(state.generatedBatches.map((b) => b.wallets.single.address), [firstAddress, laterAddress]);
  });

  test('a failed default-name readback keeps only that batch pending until a verified retry', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory();
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    final coordinator = state.walletBackup!;
    await coordinator.connect();
    final first = (await state.generate(1)).single;
    folder.failGroupNameReadback = true;
    final second = (await state.generate(1)).single;
    expect(folder.files['local']!.values.map((r) => r.address), [first.address, second.address]);
    expect(coordinator.connected, isFalse);
    expect(coordinator.canRetry, isTrue);
    expect(first.canReceiveFunds, isTrue);
    expect(second.canReceiveFunds, isFalse);
    folder.failGroupNameReadback = false;
    await coordinator.retry();
    expect(coordinator.connected, isTrue);
    expect(second.canReceiveFunds, isTrue);
    expect(state.generatedBatches.last.storedName, '第 2 组');
    expect(folder.files['local'], hasLength(2));
  });

  test('old ungrouped records remain accessible in the legacy group after generating and renaming', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory()..remembered = 'local';
    final previous = [key(86), key(87)];
    final legacy = [
      for (final wallet in previous)
        WalletBackupRecord(
          category: WalletBackupCategory.toolGenerated,
          address: wallet.address,
          privateKey: wallet.exportPrivateKey(),
        ),
    ];
    folder.files['local'] = {for (final record in legacy) record.identity: record};
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    await state.walletBackup!.restore();
    final archived = state.generatedBatches.single;
    expect(archived.name, '历史生成钱包');
    expect(archived.wallets.map((w) => w.address), previous.map((w) => w.address));
    final current = await state.generate(1);
    await state.renameGeneratedBatch(archived, '旧版钱包');
    await state.walletBackup!.connect();
    expect(state.generatedBatches.first.name, '旧版钱包');
    expect(state.generatedBatches.first.wallets.map((w) => w.address), previous.map((w) => w.address));
    expect(state.generatedBatches.last.wallets.single.address, current.single.address);
    expect(folder.files['local'], hasLength(3));
  });

  test('switching folders displays only the groups saved in the selected directory', () async {
    state.dispose();
    state.api.http_.close();
    final folder = _GroupDirectory();
    state = AppState(backend.api(), MemoryKeyStore(), backupDirectory: folder);
    await state.walletBackup!.connect();
    final original = (await state.generate(1)).single;
    await state.renameGeneratedBatch(state.generatedBatches.single, '目录 A');

    folder.choice = 'other';
    await state.walletBackup!.connect();
    expect(state.generatedBatches, isEmpty);
    expect(folder.files['other'], isNull);
    final next = (await state.generate(1)).single;
    expect(state.generatedBatches.single.wallets.single.address, next.address);
    expect(folder.files['other']!.values.map((r) => r.address), [next.address]);

    folder.choice = 'local';
    await state.walletBackup!.connect();
    expect(state.generatedBatches.single.name, '目录 A');
    expect(state.generatedBatches.single.wallets.single.address, original.address);
    expect(folder.files['local']!.values.map((r) => r.address), [original.address]);
  });

  test('write completion unlocks exact generated wallets; partial errors redact and retry', () async {
    await backup.connect();
    dir.gate = Completer<void>();
    final creating = state.generate(2);
    final wallets = List.of(state.generated);
    dir.failures.add(wallets.last.address.toLowerCase());
    final recipient = key(4);
    final savingRelay = state.transitsFor([recipient.address]);
    final savingAgain = state.transitsFor([recipient.address.toLowerCase()]);
    await Future<void>.delayed(Duration.zero);
    expect(dir.simultaneous, 1);
    await expectLater(backup.connect(), throwsA(backupError));
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    expect(state.distributionTransits, isEmpty);
    dir.gate!.complete();
    await creating;
    final relay = (await savingRelay).values.single;
    expect((await savingAgain).values.single, same(relay));
    expect(backup.hasError, isTrue);
    expect(backup.pendingCount, 2);
    expect(state.generated, wallets);
    expect(wallets.every((w) => !w.canReceiveFunds), isTrue);
    expect(relay.canReceiveFunds, isTrue);
    expect(backup.connected, isFalse);
    // Read/write permission can remain granted even when a file write fails.
    // Only a successful retry can acknowledge these pending records.
    await backup.checkAccess();
    expect(backup.connected, isFalse);
    expect(backup.hasError, isTrue);
    expect(backup.pendingCount, 2);
    final secret = wallets.last.exportPrivateKey();
    expect(backup.errorMessage, isNot(contains(secret)));
    expect(
      state.log.entries.map((e) => e.text).join(' '),
      isNot(contains(secret)),
    );
    await expectLater(backup.retry(), throwsA(backupError));
    dir.failures.clear();
    await backup.retry();
    expect(backup.connected, isTrue);
    expect(backup.hasError, isFalse);
    expect(backup.pendingCount, 0);
    expect(wallets.every((w) => w.canReceiveFunds), isTrue);
    expect(dir.files['local'], hasLength(3));
    expect(state.generated, wallets);
  });

  test(
    'permission loss is visible before a write and pending wallets survive reconnection',
    () async {
      await backup.connect();
      expect(backup.connected, isTrue);
      dir.writable = false;
      await backup.checkAccess();
      expect(backup.connected, isFalse);
      expect(backup.hasError, isTrue);
      expect(dir.writeCalls, 0);
      expect(dir.pickCalls, 1);

      final wallet = (await state.generate(1)).single;
      expect(backup.pendingCount, 1);
      expect(wallet.canReceiveFunds, isFalse);
      await expectLater(backup.connect(), throwsA(backupError));
      expect(backup.connected, isFalse);
      expect(backup.pendingCount, 1);

      dir.writable = true;
      await backup.connect();
      expect(backup.connected, isTrue);
      expect(backup.hasError, isFalse);
      expect(backup.pendingCount, 0);
      expect(dir.files['local']!.values.single.address, wallet.address);
      expect(wallet.canReceiveFunds, isTrue);
    },
  );

  test(
    'write denial overrides an earlier access check and a restored grant flushes pending wallets',
    () async {
      await backup.connect();
      final oldGrant = dir.accessGate = Completer<bool>();
      final checking = backup.checkAccess();
      await Future<void>.delayed(Duration.zero);
      dir.accessGate = null;

      dir.writable = false;
      final wallet = (await state.generate(1)).single;
      expect(backup.connected, isFalse);
      expect(backup.canRetry, isFalse);
      expect(backup.pendingCount, 1);
      oldGrant.complete(true);
      await checking;
      expect(backup.connected, isFalse);
      expect(wallet.canReceiveFunds, isFalse);
      expect(dir.writeCalls, 1);

      dir.writable = true;
      await backup.checkAccess();
      expect(dir.pickCalls, 1);
      expect(backup.connected, isTrue);
      expect(backup.hasError, isFalse);
      expect(backup.pendingCount, 0);
      expect(wallet.canReceiveFunds, isTrue);
      expect(dir.files['local']!.values.single.address, wallet.address);
    },
  );

  test(
    'late permission result for an old directory cannot invalidate a new choice',
    () async {
      await backup.connect();
      final checks = dir.accessChecks;
      final gate = dir.accessGate = Completer<bool>();
      final oldCheck = backup.checkAccess();
      await Future<void>.delayed(Duration.zero);
      expect(dir.accessChecks, checks + 1);
      dir.accessGate = null;
      dir.choice = 'second';
      await backup.connect();
      gate.complete(false);
      await oldCheck;
      expect(backup.directoryName, 'second');
      expect(backup.connected, isTrue);
      expect(backup.hasError, isFalse);
    },
  );

  test(
    'unrelated drafts in the same role do not block active wallet',
    () async {
      final a = key(8), b = key(9);
      const category = WalletBackupCategory.launchDev;
      dir.failures.add(a.address.toLowerCase());
      await backup.capture(category, [a, b], scope: 'Flap');
      await backup.connect();
      expect(backup.pendingCount, 2);
      await backup.requireStoredIfConnected(category, [b], scope: 'Flap');
      expect(backup.pendingCount, 1);
      expect(dir.files['local']!.values.single.address, b.address);
      await expectLater(
        backup.requireStoredIfConnected(category, [a], scope: 'Flap'),
        throwsA(backupError),
      );
      expect(backup.hasError, isTrue);
    },
  );

  test('first captured purpose survives priority writes and later reuse', () async {
    await backup.connect();
    final wallet = key(83);
    const first = WalletBackupCategory.toolGenerated;
    const urgent = WalletBackupCategory.tradeGroup;
    const later = WalletBackupCategory.toolCollectionSource;

    final draft = backup.capture(first, [wallet]);
    final required = backup.requireStoredIfConnected(urgent, [wallet]);
    await Future.wait([draft, required]);
    await backup.capture(later, [wallet]);

    final records = dir.files['local']!.values;
    expect(records.map((record) => record.category), [urgent, first, later]);
    expect(records.map((record) => record.originalCategory), everyElement(first));
  });

  test(
    'switch only writes pending and explicitly reused wallets in new directory',
    () async {
      dir.remembered = 'first';
      await backup.restore();
      expect(dir.pickCalls, 0);
      expect(dir.writeCalls, 0);
      final a = key(20), b = key(21);
      await backup.capture(WalletBackupCategory.tradeGroup, [a]);
      final writes = dir.writeCalls;
      await backup.capture(WalletBackupCategory.tradeGroup, [a, a]);
      expect(dir.writeCalls, writes + 1); // Recheck the single distinct record.
      dir.choice = null;
      await backup.connect();
      expect(backup.directoryName, 'first');
      expect(dir.writeCalls, writes + 1);
      dir.choice = 'second';
      await backup.connect();
      expect(dir.files['second'], isNull);
      await backup.capture(WalletBackupCategory.toolCollectionSource, [b]);
      expect(dir.files['second']!.values.map((r) => r.address), [b.address]);
      await backup.capture(WalletBackupCategory.tradeGroup, [a]);
      expect(dir.files['second']!.length, 2);
      expect(dir.files['first']!.length, 1);
    },
  );

  test(
    'capture during the directory picker follows the final choice',
    () async {
      final wallet = key(30);
      await backup.connect();
      await backup.capture(WalletBackupCategory.launchDev, [wallet]);
      dir.choice = 'new';
      dir.chooser = Completer<void>();
      final choosing = backup.connect();
      await backup.capture(WalletBackupCategory.launchDev, [wallet]);
      expect(backup.pendingCount, 1);
      expect(dir.writeCalls, 1);
      dir.chooser!.complete();
      await choosing;
      expect(dir.files['new']!.values.single.address, wallet.address);
      expect(backup.pendingCount, 0);
    },
  );

  test('overlapping callers share a disk check, a later save rechecks', () async {
    await backup.connect();
    const category = WalletBackupCategory.launchDev;
    final w = key(74);
    await Future.wait([
      backup.requireStoredIfConnected(category, [w]),
      backup.requireStoredIfConnected(category, [w]),
    ]);
    expect(dir.writeCalls, 1);
    await backup.requireStoredIfConnected(category, [w]);
    expect(dir.writeCalls, 2);
    expect(dir.files['local'], hasLength(1));
  });

  test('a different verified backup cannot unlock a failed required record', () async {
    await backup.connect();
    final w = (await state.generate(1)).single;
    final files = dir.files['local']!;
    final original = files.values.single;
    files[original.identity] = WalletBackupRecord(
      category: original.category, scope: original.scope, address: w.address,
      privateKey: key(75).exportPrivateKey(),
    );
    final failed = backup.requireStoredIfConnected(original.category, [w], scope: original.scope);
    expect(w.canReceiveFunds, isFalse);
    await expectLater(failed, throwsA(backupError));
    await backup.capture(WalletBackupCategory.linkedTransit, [w], relatedAddress: key(76).address);
    expect(w.canReceiveFunds, isFalse);
    expect(() => state.requireReceivable([w.address]), throwsA(backupError));
    expect(backup.pendingCount, 1);
    files.remove(original.identity);
    await backup.retry();
    expect(files[original.identity]!.privateKey, original.privateKey);
    expect(w.canReceiveFunds, isTrue);
    expect(backup.pendingCount, 0);
  });

  test(
    'linked funding holds for its failed relay and retry reuses the same pair',
    () async {
      state.token = const TokenMeta(fake.token, 'Fixture', 'CAKE', 18);
      final g = state.addLinkedGroup();
      final seller = key(31), buyer = key(32);
      await backup.connect();
      await state.setLinkedKeys(g, sellers: true, text: seller.exportPrivateKey());
      dir.failCategory = WalletBackupCategory.linkedTransit;
      await expectLater(state.setLinkedKeys(g, sellers: false, text: buyer.exportPrivateKey()), throwsA(backupError));
      final failed = dir.lastFailedAddress;
      expect(failed, isNotNull);
      expect(g.transits, isEmpty);
      expect(g.buyers, isEmpty);
      expect(backend.submitted, isEmpty);
      dir.failCategory = null;
      await state.setLinkedKeys(g, sellers: false, text: buyer.exportPrivateKey());
      expect(g.transits.single.address, failed);
      expect(g.transitsBackedUp, isTrue);
      expect(backend.submitted, isEmpty);
    },
  );

  test(
    'trade confirmation rejects a changed backup in the same selected folder',
    () async {
      state.token = const TokenMeta(fake.token, 'Fixture', 'CAKE', 18);
      final w = key(41);
      backend.wallets[w.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': 0,
        'tokenBalance': '1000000000000000000',
        'routerAllowance': '0',
      };
      await backup.connect();
      final g = state.addGroup();
      await state.setKeys(g, w.exportPrivateKey());
      final preview = await state.prepare(g);
      final selectedFolder = dir.files['local']!;
      final saved = selectedFolder.values.single;
      final altered = WalletBackupRecord(
        category: saved.category, scope: saved.scope,
        address: saved.address, privateKey: key(42).exportPrivateKey(),
      );
      selectedFolder[saved.identity] = altered;
      await expectLater(
        state.start(g, prepared: preview, impactConfirmed: true),
        throwsA(backupError),
      );
      expect(state.groupOperationBusy(g), isFalse);
      expect(backend.submitted, isEmpty);
      expect(backup.pendingCount, 1);
      expect(selectedFolder[saved.identity], same(altered));
    },
  );

  test(
    'host without directory still accepts confirmed manual exports',
    () async {
      final host = AppState(backend.api(), MemoryKeyStore());
      addTearDown(() {
        host.dispose();
        host.api.http_.close();
      });
      final generated = (await host.generate(1)).single;
      expect(generated.canReceiveFunds, isFalse);
      final next = (await host.generate(1)).single;
      expect(host.generated.single, same(next));
      expect(host.unbackedAddresses, contains(generated.address.toLowerCase()));
      expect(host.exportKeys([generated]), generated.exportPrivateKey());
      expect(generated.canReceiveFunds, isTrue);
      expect(host.unbackedAddresses, {next.address.toLowerCase()});
    },
  );
}
