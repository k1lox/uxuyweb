part of 'wallet.dart';

/// A verified backup. For transit files the recipient is part of the identity.
class WalletFileImport {
  WalletFileImport(
    this.category,
    this.scope,
    this.wallets,
    this.pairs, {
    this.isArchive = false,
    this.originalCategories = const {},
  });
  final bool isArchive;
  final String category, scope;
  final List<TradeWallet> wallets;
  final Map<String, TradeWallet> pairs;
  final Map<String, String> originalCategories;

  String originalCategoryFor(TradeWallet wallet) =>
      originalCategories[wallet.address.toLowerCase()] ?? category;

  List<TradeWallet> get ordinaryWallets {
    if (pairs.isNotEmpty) {
      final target = category == WalletBackupCategory.linkedTransit
          ? '关联组'
          : '分发';
      throw FormatException('此备份含接收方与中转钱包对应关系，请在$target使用「恢复中转备份」');
    }
    return wallets;
  }
}

String _backupText(String value) =>
    value.trimLeft().replaceFirst(RegExp(r'^\uFEFF'), '').trim();
bool isWalletFileInput(String value) {
  final start = _backupText(value);
  return start.startsWith('Botai 私钥备份') || start.startsWith('{');
}

typedef BackupUsageGroup = ({String category, String scope});

typedef _ArchiveWalletRow = ({
  String address,
  String key,
  String? recipient,
  String? originalCategory,
});

/// The file's ordinary-wallet groups, containing only public context labels.
class BackupUsageSelectionRequired extends FormatException {
  const BackupUsageSelectionRequired(this.groups) : super('请选择本次要导入的备份用途或组别');
  final List<BackupUsageGroup> groups;
}

String ordinaryWalletInput(String value, {BackupUsageGroup? target}) {
  if (!isWalletFileInput(value)) return value;
  return parseWalletFile(
    value,
    target: target,
  ).ordinaryWallets.map((w) => w.exportPrivateKey()).join('\n');
}

WalletFileImport parseWalletFile(
  String value, {
  BackupUsageGroup? target,
  Set<String>? recipients,
}) {
  final body = _backupText(value);
  final wallets = <TradeWallet>[], pairs = <String, TradeWallet>{};
  final addresses = <String>{}, originalCategories = <String, String>{};
  void add(
    Object? address,
    Object? key, [
    Object? recipient,
    String? originalCategory,
  ]) {
    if (address is! String || !isAddress(address) || key is! String) {
      throw const FormatException('备份钱包地址或私钥格式无效');
    }
    final wallet = TradeWallet.import('W${wallets.length + 1}', key);
    final id = wallet.address.toLowerCase();
    if (id != address.toLowerCase()) {
      throw const FormatException('备份地址与私钥派生地址不一致');
    }
    if (!addresses.add(id)) throw const FormatException('备份包含重复钱包地址');
    if (recipient != null) {
      if (recipient is! String ||
          !isAddress(recipient) ||
          BigInt.parse(recipient.substring(2), radix: 16) == BigInt.zero) {
        throw const FormatException('备份接收方地址无效');
      }
      final to = recipient.toLowerCase();
      if (pairs.containsKey(to)) throw const FormatException('备份包含重复接收方');
      pairs[to] = wallet;
    }
    wallets.add(wallet);
    if (originalCategory != null) originalCategories[id] = originalCategory;
  }

  late String category, scope;
  var isArchive = false;
  if (body.startsWith('{')) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const FormatException('钱包备份 JSON 格式无效');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('请选择 UXUY 钱包备份 JSON');
    }
    if (json['format'] == 'uagent-wallet-backup-v2') {
      isArchive = true;
      final archive = json['wallets'];
      if (archive is! List || archive.isEmpty) {
        throw const FormatException('钱包备份中没有记录');
      }
      final groups = <BackupUsageGroup, List<_ArchiveWalletRow>>{};
      final recorded = <String>{};
      for (final entry in archive) {
        if (entry is! Map<String, dynamic> ||
            entry['address'] is! String ||
            !isAddress(entry['address']) ||
            entry['privateKey'] is! String ||
            !_privateKeyField.hasMatch(entry['privateKey']) ||
            entry['purpose'] is! String ||
            (entry['purpose'] as String).trim().isEmpty ||
            entry['usages'] is! List ||
            (entry['usages'] as List).isEmpty) {
          throw const FormatException('钱包备份记录无效');
        }
        if (!recorded.add((entry['address'] as String).toLowerCase())) {
          throw const FormatException('备份包含重复钱包地址');
        }
        final originalCategory = WalletBackupCategory.byLabel[entry['purpose']];
        for (final usage in entry['usages']) {
          if (usage is! Map<String, dynamic> ||
              !WalletBackupCategory.values.contains(usage['category']) ||
              usage['scope'] is! String ||
              (usage['scope'] as String).length > 256 ||
              !usage.containsKey('relatedAddress')) {
            throw const FormatException('钱包备份用途无效');
          }
          final kind = usage['category'] as String;
          final recipient = usage['relatedAddress'];
          if (WalletBackupCategory.isTransit(kind)
              ? recipient is! String || !isAddress(recipient)
              : recipient != null) {
            throw const FormatException('备份用途与接收方信息不匹配');
          }
          final group = (category: kind, scope: usage['scope'] as String);
          (groups[group] ??= []).add((
            address: entry['address'] as String,
            key: entry['privateKey'] as String,
            recipient: recipient as String?,
            originalCategory: originalCategory,
          ));
        }
      }
      // Never flatten an archive across purposes or group scopes: an editor
      // must know its destination, or the user must choose one source group.
      final selected =
          target ?? (groups.length == 1 ? groups.keys.single : null);
      final selectedRows = groups[selected];
      if (selected == null || selectedRows == null) {
        if (target != null && WalletBackupCategory.isTransit(target.category)) {
          throw const FormatException('备份用途或关联组编号与当前位置不同');
        }
        final ordinary = groups.keys
            .where((g) => !WalletBackupCategory.isTransit(g.category))
            .toList();
        if (ordinary.isEmpty) {
          throw const FormatException('此备份含接收方与中转钱包对应关系，请使用「恢复中转备份」');
        }
        throw BackupUsageSelectionRequired(ordinary);
      }
      category = selected.category;
      scope = selected.scope;
      for (final row in selectedRows) {
        if (recipients != null &&
            !recipients.contains(row.recipient?.toLowerCase()))
          continue;
        add(row.address, row.key, row.recipient, row.originalCategory);
      }
    } else {
      if (json['format'] != 'uagent-wallet-backup-v1' ||
          json['scope'] is! String ||
          json['category'] is! String) {
        throw const FormatException('请选择 UXUY 钱包备份 JSON');
      }
      category = json['category'] as String;
      scope = json['scope'] as String;
      if (!WalletBackupCategory.values.contains(category) ||
          WalletBackupCategory.isTransit(category) !=
              (json['relatedAddress'] != null)) {
        throw const FormatException('备份用途与接收方信息不匹配');
      }
      add(json['address'], json['privateKey'], json['relatedAddress']);
    }
  } else {
    final lines = const LineSplitter()
        .convert(body)
        .map((l) => l.trim())
        .toList();
    if (lines.isEmpty || lines.first != 'Botai 私钥备份 v1') {
      throw const FormatException('请输入完整的 BotAI 私钥备份 TXT 或 UXUY 钱包备份 JSON');
    }
    String header(String field) {
      final matches = lines.where((l) => l.startsWith('$field：')).toList();
      if (matches.length != 1) throw FormatException('备份缺少或重复了$field');
      return matches.single.substring(field.length + 1).trim();
    }

    if (header('链').toUpperCase() != 'BSC')
      throw const FormatException('仅支持 BSC 钱包备份');
    final purpose = header('用途'), count = int.tryParse(header('数量'));
    final linked = RegExp(r'^关联组中转 · 组 (\d+)$').firstMatch(purpose);
    category = switch (purpose) {
      '主动生成' => WalletBackupCategory.toolGenerated,
      '分发中转' => WalletBackupCategory.distributionTransit,
      _ when linked != null => WalletBackupCategory.linkedTransit,
      _ => throw const FormatException('不支持的备份用途'),
    };
    scope = linked == null ? '' : '关联组${linked.group(1)!.padLeft(2, '0')}';
    final transit = category != WalletBackupCategory.toolGenerated;
    final columns = transit ? '接收地址\t中转地址\t中转私钥' : '地址\t私钥';
    final index = lines.indexOf(columns);
    if (index < 0 || count == null || count < 1 || count > 10000) {
      throw const FormatException('备份表头或声明数量无效');
    }
    for (var i = index + 1; i < lines.length; i++) {
      if (lines[i].isEmpty) continue;
      final row = lines[i].split('\t');
      if (row.length != (transit ? 3 : 2))
        throw FormatException('第 ${i + 1} 行的备份列数无效');
      try {
        add(row[row.length - 2], row.last, transit ? row.first : null);
      } on FormatException catch (e) {
        throw FormatException('第 ${i + 1} 行：${e.message}');
      }
    }
    if (count != wallets.length) throw const FormatException('备份声明数量与实际记录数不同');
  }
  if (pairs.keys.any(addresses.contains))
    throw const FormatException('中转地址不能同时作为接收方');
  return WalletFileImport(
    category,
    scope,
    wallets,
    pairs,
    isArchive: isArchive,
    originalCategories: originalCategories,
  );
}
