import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../crypto/secp256k1.dart';

const bscChainId = 56;

// ------------------------------------------------------------------ hex

Uint8List hexToBytes(String hex) {
  var h = hex.startsWith('0x') || hex.startsWith('0X') ? hex.substring(2) : hex;
  if (h.length.isOdd) h = '0$h';
  if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(h)) {
    throw const FormatException('invalid hex');
  }
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes, {bool prefix = true}) {
  final b = StringBuffer(prefix ? '0x' : '');
  for (final x in bytes) {
    b.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

Uint8List _bigToMinimal(BigInt v) {
  if (v == BigInt.zero) return Uint8List(0);
  final h = v.toRadixString(16);
  return hexToBytes(h.length.isOdd ? '0$h' : h);
}

// ------------------------------------------------------------------ addresses

final _addressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');

bool isAddress(String s) => _addressPattern.hasMatch(s);

/// EIP-55 checksum form.
String checksumAddress(String address) {
  if (!isAddress(address)) throw const FormatException('invalid address');
  final lower = address.substring(2).toLowerCase();
  final hash = bytesToHex(keccak256(lower.codeUnits), prefix: false);
  final out = StringBuffer('0x');
  for (var i = 0; i < 40; i++) {
    final c = lower[i];
    out.write(int.parse(hash[i], radix: 16) >= 8 ? c.toUpperCase() : c);
  }
  return out.toString();
}

String addressFromPrivateKey(Uint8List privateKey) {
  final pub = Secp256k1.publicKey(bytesToBigInt(privateKey));
  final hash = keccak256(pub);
  return checksumAddress(bytesToHex(hash.sublist(12)));
}

// ------------------------------------------------------------------ RLP

Uint8List rlpEncode(Object item) {
  // Uint8List is also a List<int>: test for byte strings before lists.
  if (item is! Uint8List && item is List<Object>) {
    final body = <int>[for (final e in item) ...rlpEncode(e)];
    return Uint8List.fromList([..._rlpLength(body.length, 0xc0), ...body]);
  }
  final bytes = switch (item) {
    final Uint8List b => b,
    final BigInt v => _bigToMinimal(v),
    final int v => _bigToMinimal(BigInt.from(v)),
    _ => throw ArgumentError('unsupported RLP item'),
  };
  if (bytes.length == 1 && bytes[0] < 0x80) return bytes;
  return Uint8List.fromList([..._rlpLength(bytes.length, 0x80), ...bytes]);
}

List<int> _rlpLength(int len, int offset) {
  if (len < 56) return [offset + len];
  final l = _bigToMinimal(BigInt.from(len));
  return [offset + 55 + l.length, ...l];
}

// ------------------------------------------------------------------ transactions

/// Legacy (type 0) EIP-155 transaction; accepted on BSC.
class LegacyTx {
  const LegacyTx({
    required this.nonce,
    required this.gasPrice,
    required this.gasLimit,
    required this.to,
    required this.value,
    required this.data,
    this.chainId = bscChainId,
  });

  /// Contract deployment transaction.
  LegacyTx.deploy({
    required this.nonce,
    required this.gasPrice,
    required this.gasLimit,
    required this.data,
    this.chainId = bscChainId,
  }) : to = null,
       value = BigInt.zero;

  final int nonce;
  final BigInt gasPrice;
  final int gasLimit;

  /// Recipient; null deploys a contract (CREATE).
  final String? to;
  final BigInt value;
  final Uint8List data;
  final int chainId;

  List<Object> _fields() => [
    nonce,
    gasPrice,
    gasLimit,
    to == null ? Uint8List(0) : hexToBytes(to!),
    value,
    data,
  ];

  Uint8List signingHash() =>
      keccak256(rlpEncode([..._fields(), chainId, 0, 0]));

  SignedTx sign(Uint8List privateKey) {
    if (to != null && !isAddress(to!)) {
      throw const FormatException('invalid recipient');
    }
    final sig = Secp256k1.sign(signingHash(), bytesToBigInt(privateKey));
    final v = BigInt.from(chainId * 2 + 35 + sig.recId);
    final raw = rlpEncode([..._fields(), v, sig.r, sig.s]);
    return SignedTx(bytesToHex(raw), bytesToHex(keccak256(raw)), nonce);
  }
}

/// Raw signed transaction. Never logged; only the hash is shown to users.
class SignedTx {
  const SignedTx(this.raw, this.hash, this.nonce);
  final String raw;
  final String hash;
  final int nonce;
}

// ------------------------------------------------------------------ ABI (only what the module signs itself)

Uint8List _word(BigInt v) => toBytes32(v);
Uint8List _addrWord(String a) => Uint8List(32)..setRange(12, 32, hexToBytes(a));

Uint8List erc20Approve(String spender, BigInt amount) => Uint8List.fromList([
  ...hexToBytes('0x095ea7b3'),
  ..._addrWord(spender),
  ..._word(amount),
]);

Uint8List erc20Transfer(String to, BigInt amount) => Uint8List.fromList([
  ...hexToBytes('0xa9059cbb'),
  ..._addrWord(to),
  ..._word(amount),
]);

final maxUint256 = (BigInt.one << 256) - BigInt.one;

// ------------------------------------------------------------------ units (no floating point)

/// "1.25" with 18 decimals -> 1250000000000000000. Rejects more decimals than the token has.
BigInt parseUnits(String text, int decimals) {
  final s = text.trim();
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) {
    throw const FormatException('金额格式无效');
  }
  final parts = s.split('.');
  final frac = parts.length == 2 ? parts[1] : '';
  if (frac.length > decimals) throw const FormatException('小数位过多');
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(decimals) +
      (frac.isEmpty ? BigInt.zero : BigInt.parse(frac.padRight(decimals, '0')));
}

String formatUnits(BigInt value, int decimals, {int maxFraction = 6}) {
  final neg = value.isNegative;
  final v = value.abs();
  final base = BigInt.from(10).pow(decimals);
  final whole = v ~/ base;
  var frac = (v % base).toString().padLeft(decimals, '0');
  if (frac.length > maxFraction) frac = frac.substring(0, maxFraction);
  frac = frac.replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
}

/// Address of a contract deployed by [sender] at [nonce] (CREATE).
String createAddress(String sender, int nonce) => checksumAddress(
  bytesToHex(keccak256(rlpEncode([hexToBytes(sender), nonce])).sublist(12)),
);

/// CREATE2: keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:].
String create2Address(
  String deployer,
  Uint8List salt,
  Uint8List initCodeHash,
) => checksumAddress(
  bytesToHex(
    keccak256(
      Uint8List.fromList([
        0xff,
        ...hexToBytes(deployer),
        ...salt,
        ...initCodeHash,
      ]),
    ).sublist(12),
  ),
);

const pancakeV2Factory = '0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73';
final _pancakeV2InitCodeHash = hexToBytes(
  '0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5',
);

/// PancakeSwap V2 pair address for two tokens (exists or not): used for pools that a launch bundle creates.
String pancakeV2Pair(String tokenA, String tokenB) {
  final a = hexToBytes(tokenA), b = hexToBytes(tokenB);
  final aFirst = bytesToBigInt(a) < bytesToBigInt(b);
  final salt = keccak256(
    Uint8List.fromList([...(aFirst ? a : b), ...(aFirst ? b : a)]),
  );
  return create2Address(pancakeV2Factory, salt, _pancakeV2InitCodeHash);
}

/// EIP-191 personal_sign digest.
Uint8List personalMessageHash(String message) {
  final bytes = utf8Encode(message);
  return keccak256(
    Uint8List.fromList([
      ...utf8Encode('\x19Ethereum Signed Message:\n${bytes.length}'),
      ...bytes,
    ]),
  );
}

Uint8List utf8Encode(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80) {
      out.add(r);
    } else if (r < 0x800) {
      out.addAll([0xc0 | (r >> 6), 0x80 | (r & 0x3f)]);
    } else if (r < 0x10000) {
      out.addAll([
        0xe0 | (r >> 12),
        0x80 | ((r >> 6) & 0x3f),
        0x80 | (r & 0x3f),
      ]);
    } else {
      out.addAll([
        0xf0 | (r >> 18),
        0x80 | ((r >> 12) & 0x3f),
        0x80 | ((r >> 6) & 0x3f),
        0x80 | (r & 0x3f),
      ]);
    }
  }
  return Uint8List.fromList(out);
}
