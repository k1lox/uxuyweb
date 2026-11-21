import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/secp256k1.dart';
import '../evm/evm.dart';
import 'wallet_backup_category.dart';

part 'wallet_import.dart';

/// A module-owned wallet. The private key never leaves this object except through [exportPrivateKey],
/// which the UI calls only for an explicit user backup. `toString` never includes the key.
class TradeWallet {
  TradeWallet._(
    this.label,
    this._key,
    this.address, {
    required this.generated,
    this.backedUp = false,
  });

  final String label;
  final Uint8List _key;
  final String address;

  /// Generated inside the module (not imported by the user): must be backed up before receiving funds.
  final bool generated;
  bool backedUp;

  factory TradeWallet.generate(String label, {Random? random}) {
    final rnd = random ?? Random.secure();
    while (true) {
      final key = Uint8List.fromList(
        List<int>.generate(32, (_) => rnd.nextInt(256)),
      );
      if (Secp256k1.isValidPrivateKey(bytesToBigInt(key))) {
        return TradeWallet._(
          label,
          key,
          addressFromPrivateKey(key),
          generated: true,
        );
      }
    }
  }

  factory TradeWallet.import(String label, String privateKeyHex) {
    final hex = privateKeyHex.trim();
    if (!_privateKeyField.hasMatch(hex)) {
      throw const FormatException('私钥格式无效');
    }
    final key = hexToBytes(hex);
    if (!Secp256k1.isValidPrivateKey(bytesToBigInt(key))) {
      throw const FormatException('私钥无效');
    }
    return TradeWallet._(
      label,
      key,
      addressFromPrivateKey(key),
      generated: false,
      backedUp: true,
    );
  }

  factory TradeWallet.restoreGenerated(
    String label, String privateKey, String expectedAddress,
  ) {
    final wallet = TradeWallet.import(label, privateKey);
    if (wallet.address.toLowerCase() != expectedAddress.toLowerCase()) {
      throw const FormatException('备份地址与私钥不匹配');
    }
    return TradeWallet._(label, wallet._key, wallet.address, generated: true, backedUp: true);
  }

  bool get canReceiveFunds => !generated || backedUp;

  SignedTx sign(LegacyTx tx) => tx.sign(_key);

  /// personal_sign (EIP-191): r ++ s ++ v (27/28), hex. Used for launchpad logins and upload authorisations.
  String signMessage(String message) {
    final sig = Secp256k1.sign(
      personalMessageHash(message),
      bytesToBigInt(_key),
    );
    return bytesToHex([
      ...toBytes32(sig.r),
      ...toBytes32(sig.s),
      27 + sig.recId,
    ]);
  }

  String exportPrivateKey() => bytesToHex(_key);

  @override
  String toString() => 'TradeWallet($label, $address)';
}

/// Storage boundary. Persistent encrypted storage needs a platform plugin that UXUY must approve first;
/// until then wallets live in memory for the session only.
abstract interface class KeyStore {
  Future<List<TradeWallet>> load();
  Future<void> save(List<TradeWallet> wallets);
  bool get persistent;
}

class MemoryKeyStore implements KeyStore {
  List<TradeWallet> _wallets = const [];

  @override
  bool get persistent => false;

  @override
  Future<List<TradeWallet>> load() async => List.of(_wallets);

  @override
  Future<void> save(List<TradeWallet> wallets) async =>
      _wallets = List.of(wallets);
}

final _privateKeyField = RegExp(r'^(?:0x)?[0-9a-fA-F]{64}$');
final _inputColumns = RegExp(r'[,，;；]');
final _inputSpace = RegExp(r'\s+');

/// Reads one pasted row. Older exports used address,key and launch buyers may
/// specify key,amount. A second key must never be consumed as a label or amount.
({String key, String? label, String? amount}) parseWalletKeyLine(
  String line, {
  bool allowAmount = false,
}) {
  final text = line.trim();
  if (_privateKeyField.hasMatch(text)) {
    return (key: text, label: null, amount: null);
  }
  final fields = _inputColumns.hasMatch(text)
      ? text.split(_inputColumns).map((s) => s.trim()).toList()
      : text.split(_inputSpace);
  if (fields.length == 2) {
    final first = fields.first, last = fields.last;
    if (_privateKeyField.hasMatch(last) &&
        first.isNotEmpty &&
        (!allowAmount || isAddress(first)) &&
        !first.split(_inputSpace).any(_privateKeyField.hasMatch)) {
      if (first.toLowerCase().startsWith('0x')) {
        if (!isAddress(first) ||
            TradeWallet.import('', last).address.toLowerCase() !=
                first.toLowerCase()) {
          throw const FormatException('备份地址与私钥派生地址不一致');
        }
      }
      return (key: last, label: first, amount: null);
    }
    if (allowAmount &&
        _privateKeyField.hasMatch(first) &&
        !_privateKeyField.hasMatch(last)) {
      // A completed key can be backed up while its amount is still being typed.
      // Saving the launch form validates the amount at the token's precision.
      return (key: first, label: null, amount: last);
    }
  }
  throw const FormatException('私钥格式无效，请一行输入一个私钥');
}

/// Parse a block of private keys (one per line, optional "label,key" form). Duplicates are skipped.
List<TradeWallet> parsePrivateKeys(
  String text, {
  required Set<String> existing,
  required int startIndex,
  int? maxCount,
  bool rejectDuplicates = false,
}) {
  final out = <TradeWallet>[];
  final seen = {...existing.map((e) => e.toLowerCase())};
  var index = startIndex;
  var lineNumber = 0;
  for (final raw in const LineSplitter().convert(ordinaryWalletInput(text))) {
    lineNumber++;
    final line = raw.trim();
    if (line.isEmpty) continue;
    late final TradeWallet wallet;
    try {
      final row = parseWalletKeyLine(line);
      wallet = TradeWallet.import(row.label ?? 'W${index + 1}', row.key);
    } on FormatException catch (e) {
      throw FormatException('第 $lineNumber 行：${e.message}');
    }
    if (seen.add(wallet.address.toLowerCase())) {
      if (maxCount != null && out.length >= maxCount) {
        throw FormatException('第 $lineNumber 行：最多允许 $maxCount 个不同的来源钱包');
      }
      out.add(wallet);
      index++;
    } else if (rejectDuplicates) {
      throw FormatException('第 $lineNumber 行：分发方私钥重复，请按顺序一一对应');
    }
  }
  return out;
}
