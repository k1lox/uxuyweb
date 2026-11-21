import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'wallet.dart';
import 'wallet_backup_category.dart';

export 'wallet_backup_category.dart';

@immutable
class WalletBackupRecord {
  const WalletBackupRecord({
    required this.category,
    required this.address,
    required this.privateKey,
    String? originalCategory,
    this.scope = '',
    this.relatedAddress,
  }) : originalCategory = originalCategory ?? category;

  final String category, originalCategory, scope, address, privateKey;
  final String? relatedAddress;

  String get identity => _identity(category, scope, address, relatedAddress);
}

String _identity(
  String category,
  String scope,
  String address,
  String? related,
) => jsonEncode([
  category,
  scope,
  address.toLowerCase(),
  related?.toLowerCase(),
]);

/// A successful save means every record in the batch is durable in the selected
/// local directory. Repeating a partially completed batch must be idempotent.
abstract interface class WalletBackupDirectory {
  bool get supported;
  Future<String?> reconnect();
  Future<String?> chooseDirectory();

  /// Checks the current grant without asking the user for permission.
  Future<bool> checkAccess();
  Future<void> save(List<WalletBackupRecord> records);
}

/// The ID is persisted independently of the editable display name.
class GeneratedWalletBatch {
  GeneratedWalletBatch({
    required this.id, required this.number, required this.wallets, this.storedName,
  });

  final String id;
  final int number;
  final List<TradeWallet> wallets;
  String? storedName;

  String get name => storedName ?? (id == 'legacy' ? '历史生成钱包' : '第 $number 组');
}

/// Optional for hosts that can reopen the user's local wallet archive.
abstract interface class GeneratedWalletDirectory {
  Future<List<GeneratedWalletBatch>> readGeneratedGroups();
  Future<String> saveGeneratedBatch(List<WalletBackupRecord> records);
  Future<void> renameGeneratedGroup(String id, String? expectedName, String name);
  Future<void> deleteGeneratedGroup(String id, String? expectedName);
}

/// Provides verified wallet counts during restore when supported by the host.
abstract interface class GeneratedWalletProgressDirectory implements GeneratedWalletDirectory {
  @override
  Future<List<GeneratedWalletBatch>> readGeneratedGroups({
    void Function(int checked, int total)? onProgress,
  });
}

/// Only fixed user-facing messages belong here. Never propagate an OS exception
/// or a file's contents through this boundary.
class WalletBackupException implements Exception {
  const WalletBackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WalletBackupPermissionException extends WalletBackupException {
  const WalletBackupPermissionException(super.message);
}

class _PendingWallet {
  _PendingWallet(this.record);
  final WalletBackupRecord record;
  bool confirmsGenerated = false;
}

class _GeneratedBackup {
  int pendingRecords = 0;
  final wallets = <TradeWallet>{};
}

class WalletBackupCoordinator extends ChangeNotifier {
  WalletBackupCoordinator(this._directory);

  final WalletBackupDirectory _directory;
  void Function(List<GeneratedWalletBatch>)? onGeneratedGroupsLoaded;
  void Function(String id, String name)? onGeneratedGroupSaved;
  int _selectionEpoch = 0;
  int get selectionEpoch => _selectionEpoch;
  bool _editingGeneratedGroup = false;
  final _pending = <String, _PendingWallet>{};
  // Urgent actions may flush ahead of earlier captures for the same address.
  final _originalCategories = <String, String>{};
  final _requested = <List<String>>[];
  final _unbacked = <String, _GeneratedBackup>{};
  Future<void>? _writing;
  bool _selecting = false;
  bool _loadingWalletArchive = false;
  final _walletLoadProgress = ValueNotifier<({int checked, int total})?>(null);
  bool _disposed = false;
  String? _name;
  String? _accessError;
  String? _writeError;
  bool _needsSelection = false;
  int _revision = 0;
  int? _checkingRevision;

  bool get supported => _directory.supported;
  bool get _canWrite => _name != null && _accessError == null;
  bool get connected => _canWrite && _writeError == null && !_selecting;
  bool get canRetry => _canWrite && _pending.isNotEmpty && _writeError != null;
  bool get selecting => _selecting;
  bool get loadingWalletArchive => _loadingWalletArchive;
  ValueListenable<({int checked, int total})?> get walletLoadProgress => _walletLoadProgress;
  bool get hasSelectedDirectory => _name != null || _needsSelection;
  String? get directoryName => _name;
  int get pendingCount => _pending.length;
  bool get hasPendingChanges => _editingGeneratedGroup || _pending.isNotEmpty;
  bool get busy => _selecting || _editingGeneratedGroup || _writing != null;
  bool get hasError => errorMessage != null;
  String? get errorMessage => _accessError ?? _writeError;
  Set<String> get unbackedAddresses => Set.unmodifiable(_unbacked.keys);

  static const _connectFirst = '请先连接本地备份目录';
  static const _permissionLost = '文件夹读写权限已失效，请重新连接并允许读写。';
  static const _connectionFailure = '无法访问备份文件夹，请重新选择可写的文件夹。';
  static const _writeFailure = '私钥尚未写入本地目录。请检查目录权限和可用空间后重试。';
  static const _inProgress = '本地备份正在处理，请稍后重试';

  Future<void> restore() => _select(interactive: false);
  Future<void> connect() => _select(interactive: true);

  Future<void> checkAccess() async {
    if (_disposed || busy || _name == null || _needsSelection) return;
    final revision = _revision;
    if (_checkingRevision == revision) return;
    _checkingRevision = revision;
    String? error;
    try {
      if (!await _directory.checkAccess()) error = _permissionLost;
    } on WalletBackupException catch (e) {
      error = e.message;
    } catch (_) {
      error = _connectionFailure;
    } finally {
      if (_checkingRevision == revision) _checkingRevision = null;
    }
    // A newer selection or actual write has more current information.
    if (_disposed || revision != _revision || _accessError == error) return;
    _accessError = error;
    _notify();
    if (error == null) await flushIfConnected();
  }

  Future<void> _select({required bool interactive}) async {
    if (_disposed) return;
    if (!supported) {
      if (interactive) throw const WalletBackupException('当前浏览器不支持本地目录备份');
      return;
    }
    if (busy) {
      if (interactive) throw const WalletBackupException(_inProgress);
      return;
    }
    _revision++;
    final epoch = ++_selectionEpoch;
    _selecting = true;
    _notify();
    try {
      // Invoke the picker synchronously from the initiating user gesture.
      final name = await (interactive
          ? _directory.chooseDirectory()
          : _directory.reconnect());
      if (_disposed) return;
      if (name != null) {
        if (_directory case final GeneratedWalletDirectory history) {
          try {
            _loadingWalletArchive = true;
            _notify();
            final batches = history is GeneratedWalletProgressDirectory
                ? await history.readGeneratedGroups(onProgress: (checked, total) {
                    if (_disposed || !_loadingWalletArchive || _selectionEpoch != epoch) return;
                    _walletLoadProgress.value = (checked: checked, total: total);
                  })
                : await history.readGeneratedGroups();
            if (_disposed) return;
            onGeneratedGroupsLoaded?.call(batches);
          } catch (_) {
            if (!_disposed) onGeneratedGroupsLoaded?.call([]);
            rethrow;
          }
        }
        _name = name;
        _accessError = null;
        _writeError = null;
        _needsSelection = false;
      }
    } catch (error) {
      if (_disposed) return;
      // Never resume writes to an old choice after the new choice failed.
      _needsSelection = true;
      _accessError = error is WalletBackupException
          ? error.message
          : _connectionFailure;
      if (interactive) throw WalletBackupException(_accessError!);
    } finally {
      _selecting = false;
      _loadingWalletArchive = false;
      if (!_disposed) _walletLoadProgress.value = null;
      _notify();
    }
    await flushIfConnected();
  }

  Future<void> renameGeneratedBatch(GeneratedWalletBatch batch, String name) =>
      _editGeneratedGroup((history) => history.renameGeneratedGroup(batch.id, batch.storedName, name));

  Future<void> deleteGeneratedBatch(GeneratedWalletBatch batch) =>
      _editGeneratedGroup((history) => history.deleteGeneratedGroup(batch.id, batch.storedName));

  Future<void> _editGeneratedGroup(Future<void> Function(GeneratedWalletDirectory) edit) async {
    final history = _directory;
    if (history is! GeneratedWalletDirectory) {
      throw const WalletBackupException('当前备份目录不支持修改钱包组');
    }
    if (_disposed || !connected || busy) {
      throw WalletBackupException(errorMessage ?? (busy ? _inProgress : _connectFirst));
    }
    _editingGeneratedGroup = true;
    _revision++;
    _notify();
    try {
      await edit(history as GeneratedWalletDirectory);
    } on WalletBackupPermissionException catch (e) {
      _accessError = e.message;
      rethrow;
    } catch (error) {
      _writeError = error is WalletBackupException ? error.message : '钱包组变更未能写入并回查，请重新连接文件夹后重试';
      throw WalletBackupException(_writeError!);
    } finally {
      _editingGeneratedGroup = false;
      _notify();
    }
  }

  /// Use the recorded purpose when a verified wallet is restored into a new folder.
  void rememberOriginalCategory(String address, String category) {
    if (!_disposed && WalletBackupCategory.values.contains(category)) {
      _originalCategories.putIfAbsent(address.toLowerCase(), () => category);
    }
  }

  /// Queue the private key while it is still available, including before the
  /// user has picked a directory. No write or read uses the network.
  Future<void> capture(
    String category,
    Iterable<TradeWallet> wallets, {
    String scope = '',
    String? relatedAddress,
  }) => _capture(category, wallets.map((w) => (w, relatedAddress)), scope);

  Future<void> captureTransits(
    String category,
    Map<String, TradeWallet> transits, {
    String scope = '',
  }) =>
      _capture(category, transits.entries.map((e) => (e.value, e.key)), scope);

  Future<void> _capture(
    String category,
    Iterable<(TradeWallet, String?)> entries,
    String scope,
  ) {
    if (_disposed) return Future.value();
    final confirmsGenerated =
        category == WalletBackupCategory.toolGenerated ||
        category == WalletBackupCategory.linkedTransit ||
        category == WalletBackupCategory.distributionTransit;
    var changed = false;
    var needsWrite = false;
    for (final (wallet, related) in entries) {
      final id = _identity(category, scope, wallet.address, related);
      needsWrite = true;
      final entry = _pending.putIfAbsent(id, () {
        changed = true;
        return _PendingWallet(
          WalletBackupRecord(
            category: category,
            originalCategory: _originalCategories.putIfAbsent(
              wallet.address.toLowerCase(),
              () => category,
            ),
            scope: scope,
            address: wallet.address,
            privateKey: wallet.exportPrivateKey(),
            relatedAddress: related,
          ),
        );
      });
      if (confirmsGenerated && wallet.generated) {
        final proof = _unbacked.putIfAbsent(
          wallet.address.toLowerCase(),
          _GeneratedBackup.new,
        );
        if (!entry.confirmsGenerated) {
          entry.confirmsGenerated = true;
          proof.pendingRecords++;
        }
        proof.wallets.add(wallet);
        wallet.backedUp = false;
      }
    }
    if (changed) _notify();
    return needsWrite ? flushIfConnected() : Future.value();
  }

  /// A failed category stays pending and does not prevent the others from being
  /// committed. Captures arriving during a write join the same drain.
  Future<void> flushIfConnected() {
    if (_disposed || !_canWrite || _selecting || _pending.isEmpty) {
      return Future.value();
    }
    final writing = _writing;
    if (writing != null) return writing;
    _revision++;
    final future = _writing = Future.microtask(_drain);
    _notify();
    return future;
  }

  Future<void> _drain() async {
    final attempted = <_PendingWallet>{};
    try {
      while (!_disposed && _canWrite) {
        final batches = <List<MapEntry<String, _PendingWallet>>>[];
        // An action may require only part of a category. A damaged unrelated
        // file must not prevent that subset from being acknowledged.
        for (final keys in _requested) {
          final batch = [
            for (final id in keys)
              if (_pending[id] case final item?) MapEntry(id, item),
          ];
          if (batch.isNotEmpty) {
            batches.add(batch);
            attempted.addAll(batch.map((e) => e.value));
          }
        }
        _requested.clear();
        final others =
            <(String, String), List<MapEntry<String, _PendingWallet>>>{};
        for (final e in _pending.entries) {
          if (attempted.add(e.value)) {
            final r = e.value.record;
            (others[(r.category, r.scope)] ??= []).add(e);
          }
        }
        batches.addAll(others.values);
        if (batches.isEmpty) break;
        for (final batch in batches) {
          if (_disposed) return;
          // Two callers can require overlapping groups. Only submit entries
          // that still belong to this batch after an earlier group completed.
          final active = [
            for (final e in batch)
              if (identical(_pending[e.key], e.value)) e,
          ];
          if (active.isEmpty) continue;
          try {
            final records = [for (final e in active) e.value.record];
            final first = records.first;
            if (_directory case final GeneratedWalletDirectory history
                when first.category == WalletBackupCategory.toolGenerated && first.scope.isNotEmpty) {
              final name = await history.saveGeneratedBatch(records);
              if (!_disposed) onGeneratedGroupSaved?.call(first.scope, name);
            } else {
              await _directory.save(records);
            }
          } on WalletBackupPermissionException catch (error) {
            _accessError = error.message;
            _notify();
            break;
          } catch (error) {
            _writeError = error is WalletBackupException
                ? error.message
                : _writeFailure;
            _notify();
            continue;
          }
          if (_disposed) return;
          for (final e in active) {
            _pending.remove(e.key);
            if (e.value.confirmsGenerated) {
              final address = e.value.record.address.toLowerCase();
              final proof = _unbacked[address]!;
              if (--proof.pendingRecords == 0) {
                for (final w in proof.wallets) {
                  w.backedUp = true;
                }
                _unbacked.remove(address);
              }
            }
          }
        }
      }
      if (_pending.isEmpty) _writeError = null;
    } finally {
      _writing = null;
      _notify();
    }
  }

  Future<void> retry() async {
    if (_pending.isEmpty) return;
    if (!_canWrite) throw WalletBackupException(_accessError ?? _connectFirst);
    await flushIfConnected();
    if (_pending.isNotEmpty) {
      throw WalletBackupException(errorMessage ?? _inProgress);
    }
  }

  /// Only the wallets used by this action need to have reached disk; unrelated
  /// drafts may still be pending. Imported wallets stay usable before setup.
  Future<void> requireStoredIfConnected(
    String category,
    Iterable<TradeWallet> wallets, {
    String scope = '',
  }) async {
    final list = [for (final w in wallets) (w, null)];
    await _requireStored(category, list, scope);
  }

  Future<void> requireTransitsStoredIfConnected(
    String category,
    Map<String, TradeWallet> transits, {
    String scope = '',
  }) => _requireStored(category, [
    for (final e in transits.entries) (e.value, e.key),
  ], scope);

  Future<void> _requireStored(
    String category,
    List<(TradeWallet, String?)> list,
    String scope,
  ) async {
    final write = _capture(category, list, scope);
    if (_selecting) throw const WalletBackupException(_inProgress);
    if (!hasSelectedDirectory) return;
    final ids = [
      for (final (w, related) in list)
        _identity(category, scope, w.address, related),
    ];
    final required = ids.where(_pending.containsKey).toList();
    if (required.isEmpty) return;
    if (!_canWrite) throw WalletBackupException(_accessError ?? _connectFirst);
    _requested.add(required);
    await write;
    if (_disposed || required.any(_pending.containsKey)) {
      throw WalletBackupException(errorMessage ?? _inProgress);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _walletLoadProgress.dispose();
    _pending.clear();
    _originalCategories.clear();
    _requested.clear();
    _unbacked.clear();
    super.dispose();
  }
}
