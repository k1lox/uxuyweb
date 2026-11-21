import 'dart:convert';
import 'dart:js_interop';

import 'package:uxuy_trade/uxuy_trade.dart' show TradeWallet;
import 'package:uxuy_trade/web_workspace.dart';

@JS('uagentWalletBackup')
external _BackupBridge? get _bridge;

extension type _BackupBridge(JSObject _) implements JSObject {
  external bool get supported;
  external bool get hasPendingLogs;
  external JSPromise<JSString> recordLog(JSString text, JSString level, JSNumber time);
  external JSPromise<JSString> history();
  external JSPromise<JSString> flushHistory();
  external JSPromise<JSString> reconnect();
  external JSPromise<JSString> chooseDirectory();
  external JSPromise<JSString> checkAccess();
  external JSPromise<JSString> save(JSString records);
  external JSPromise<JSString> generatedGroups();
  external JSPromise<JSString> saveGeneratedBatch(JSString records);
  external JSPromise<JSString> renameGeneratedGroup(JSString id, JSString expectedName, JSString name);
  external JSPromise<JSString> deleteGeneratedGroup(JSString id, JSString expectedName);
}

class BrowserWalletBackup implements WalletBackupDirectory, GeneratedWalletProgressDirectory {
  Future<void> recordLog(String message, String level, DateTime time) async {
    await _call((b) => b.recordLog(message.toJS, level.toJS, time.millisecondsSinceEpoch.toJS));
  }
  bool get hasPendingLogs => _bridge?.hasPendingLogs ?? false;

  Future<void> flushHistory() async {
    await _call((bridge) => bridge.flushHistory());
  }
  Future<String> history() async => (await _call((b) => b.history())) as String;

  @override
  bool get supported => _bridge?.supported ?? false;

  Future<dynamic> _call(
    JSPromise<JSString> Function(_BackupBridge) operation,
  ) async {
    final bridge = _bridge;
    if (bridge == null || !bridge.supported) {
      throw WalletBackupException('请使用支持目录写入的桌面浏览器，并通过 HTTPS 或本机地址打开');
    }
    try {
      final raw = (await operation(bridge).toDart).toDart;
      final response = jsonDecode(raw) as Map<String, dynamic>;
      if (response['error'] case final String error) {
        if (response['code'] == 'permission') {
          throw WalletBackupPermissionException(error);
        }
        throw WalletBackupException(error);
      }
      return response['value'];
    } on WalletBackupException {
      rethrow;
    } catch (_) {
      // Parsing/interoperability errors can contain excerpts of a record.
      throw WalletBackupException('无法完成本机备份，请检查备份目录并重试');
    }
  }

  @override
  Future<String?> reconnect() async {
    if (!supported) return null;
    return await _call((bridge) => bridge.reconnect()) as String?;
  }

  @override
  Future<String?> chooseDirectory() async =>
      await _call((bridge) => bridge.chooseDirectory()) as String?;

  @override
  Future<bool> checkAccess() async =>
      await _call((bridge) => bridge.checkAccess()) as bool;

  @override
  Future<List<GeneratedWalletBatch>> readGeneratedGroups({
    void Function(int checked, int total)? onProgress,
  }) async {
    final records = await _call((bridge) => bridge.generatedGroups());
    final groups = <GeneratedWalletBatch>[];
    final seen = <String>{};
    try {
      final rawGroups = records as List;
      final total = rawGroups.fold<int>(0, (sum, group) => sum + (group['wallets'] as List).length);
      onProgress?.call(0, total);
      final slice = Stopwatch()..start();
      for (final group in rawGroups) {
        final wallets = <TradeWallet>[];
        for (final entry in group['wallets'] as List) {
          final address = entry['address'] as String;
          if (!seen.add(address.toLowerCase())) throw const FormatException();
          wallets.add(TradeWallet.restoreGenerated(
            'N${wallets.length + 1}', entry['privateKey'] as String, address,
          ));
          // Give Chrome a chance to paint even when address derivation is slow.
          if (seen.length < total && (seen.length % 32 == 0 || slice.elapsedMilliseconds >= 60)) {
            onProgress?.call(seen.length, total);
            await Future<void>.delayed(Duration.zero);
            slice.reset();
          }
        }
        groups.add(GeneratedWalletBatch(
          id: group['id'] as String,
          number: groups.length + 1,
          storedName: group['name'] as String?,
          wallets: wallets,
        ));
      }
      if (total > 0) onProgress?.call(total, total);
    } catch (_) {
      throw const WalletBackupException('生成钱包组的地址或私钥校验失败，请检查本地备份');
    }
    return groups;
  }

  @override
  Future<void> renameGeneratedGroup(String id, String? expectedName, String name) async {
    await _call((bridge) => bridge.renameGeneratedGroup(id.toJS, (expectedName ?? '').toJS, name.toJS));
  }

  @override
  Future<void> deleteGeneratedGroup(String id, String? expectedName) async {
    await _call((bridge) => bridge.deleteGeneratedGroup(id.toJS, (expectedName ?? '').toJS));
  }

  JSString _encoded(List<WalletBackupRecord> records) => jsonEncode([
    for (final record in records)
      {
        'category': record.category,
        'originalCategory': record.originalCategory,
        'scope': record.scope,
        'address': record.address,
        'relatedAddress': record.relatedAddress,
        'privateKey': record.privateKey,
      },
  ]).toJS;

  @override
  Future<String> saveGeneratedBatch(List<WalletBackupRecord> records) async =>
      await _call((bridge) => bridge.saveGeneratedBatch(_encoded(records))) as String;

  @override
  Future<void> save(List<WalletBackupRecord> records) async {
    if (records.isNotEmpty) await _call((bridge) => bridge.save(_encoded(records)));
  }
}
