import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;

/// secp256k1 ECDSA for Ethereum transactions: deterministic nonces (RFC 6979), low-s, recovery id.
/// Pure Dart with BigInt; validated against published vectors in test/crypto_test.dart.
class Secp256k1 {
  static final BigInt p = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );
  static final BigInt n = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16,
  );
  static final BigInt _halfN = n >> 1;
  static final _Point _g = _Point(
    BigInt.parse(
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      radix: 16,
    ),
    BigInt.parse(
      '483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8',
      radix: 16,
    ),
  );

  static bool isValidPrivateKey(BigInt d) => d > BigInt.zero && d < n;

  /// Uncompressed public key without the 0x04 prefix (64 bytes).
  static Uint8List publicKey(BigInt d) {
    if (!isValidPrivateKey(d)) throw ArgumentError('invalid private key');
    final q = _mul(_g, d)!;
    return Uint8List.fromList([...toBytes32(q.x), ...toBytes32(q.y)]);
  }

  /// Sign a 32-byte hash. Returns r, s (low-s) and the recovery id (0/1).
  static Signature sign(Uint8List hash32, BigInt d) {
    if (hash32.length != 32) throw ArgumentError('hash must be 32 bytes');
    if (!isValidPrivateKey(d)) throw ArgumentError('invalid private key');
    final z = bytesToBigInt(hash32);
    final nonces = _Rfc6979(toBytes32(d), hash32);
    while (true) {
      final k = nonces.next();
      final r1 = _mul(_g, k)!;
      final r = r1.x % n;
      if (r == BigInt.zero) continue;
      var s = (k.modInverse(n) * (z + r * d)) % n;
      if (s == BigInt.zero) continue;
      var recId = (r1.y.isOdd ? 1 : 0) | (r1.x >= n ? 2 : 0);
      if (s > _halfN) {
        s = n - s;
        recId ^= 1;
      }
      if (recId > 1) {
        continue; // x overflow: astronomically rare, Ethereum cannot encode it
      }
      return Signature(r, s, recId);
    }
  }
}

class Signature {
  const Signature(this.r, this.s, this.recId);
  final BigInt r;
  final BigInt s;
  final int recId;
}

class _Point {
  const _Point(this.x, this.y);
  final BigInt x;
  final BigInt y;
}

/// Jacobian coordinates (X, Y, Z) for fewer inversions.
class _Jac {
  const _Jac(this.x, this.y, this.z);
  final BigInt x;
  final BigInt y;
  final BigInt z;
  bool get infinity => z == BigInt.zero;
}

final BigInt _p = Secp256k1.p;

_Jac _double(_Jac a) {
  if (a.infinity || a.y == BigInt.zero) return _inf;
  final ysq = (a.y * a.y) % _p;
  final s = (BigInt.from(4) * a.x * ysq) % _p;
  final m = (BigInt.from(3) * a.x * a.x) % _p;
  final nx = (m * m - BigInt.two * s) % _p;
  final ny = (m * (s - nx) - BigInt.from(8) * ysq * ysq) % _p;
  final nz = (BigInt.two * a.y * a.z) % _p;
  return _Jac(nx, ny, nz);
}

_Jac _add(_Jac a, _Jac b) {
  if (a.infinity) return b;
  if (b.infinity) return a;
  final z1z1 = (a.z * a.z) % _p;
  final z2z2 = (b.z * b.z) % _p;
  final u1 = (a.x * z2z2) % _p;
  final u2 = (b.x * z1z1) % _p;
  final s1 = (a.y * b.z * z2z2) % _p;
  final s2 = (b.y * a.z * z1z1) % _p;
  if (u1 == u2) {
    return s1 == s2 ? _double(a) : _inf;
  }
  final h = (u2 - u1) % _p;
  final r = (s2 - s1) % _p;
  final h2 = (h * h) % _p;
  final h3 = (h * h2) % _p;
  final u1h2 = (u1 * h2) % _p;
  final nx = (r * r - h3 - BigInt.two * u1h2) % _p;
  final ny = (r * (u1h2 - nx) - s1 * h3) % _p;
  final nz = (h * a.z * b.z) % _p;
  return _Jac(nx, ny, nz);
}

final _Jac _inf = _Jac(BigInt.one, BigInt.one, BigInt.zero);

_Point? _mul(_Point pt, BigInt k) {
  var result = _Jac(BigInt.one, BigInt.one, BigInt.zero);
  var addend = _Jac(pt.x, pt.y, BigInt.one);
  var e = k;
  while (e > BigInt.zero) {
    if (e.isOdd) result = _add(result, addend);
    addend = _double(addend);
    e = e >> 1;
  }
  if (result.infinity) return null;
  final zinv = result.z.modInverse(_p);
  final zinv2 = (zinv * zinv) % _p;
  return _Point((result.x * zinv2) % _p, (result.y * zinv2 * zinv) % _p);
}

/// RFC 6979 section 3.2 with HMAC-SHA256.
class _Rfc6979 {
  _Rfc6979(Uint8List x, Uint8List h1) {
    final hBits = _bits2octets(h1);
    _v = Uint8List(32)..fillRange(0, 32, 1);
    _k = Uint8List(32);
    _k = _hmac(_k, [..._v, 0, ...x, ...hBits]);
    _v = _hmac(_k, _v);
    _k = _hmac(_k, [..._v, 1, ...x, ...hBits]);
    _v = _hmac(_k, _v);
  }

  late Uint8List _k;
  late Uint8List _v;
  bool _first = true;

  BigInt next() {
    if (!_first) {
      _k = _hmac(_k, [..._v, 0]);
      _v = _hmac(_k, _v);
    }
    _first = false;
    while (true) {
      _v = _hmac(_k, _v);
      final k = bytesToBigInt(_v);
      if (k > BigInt.zero && k < Secp256k1.n) return k;
      _k = _hmac(_k, [..._v, 0]);
      _v = _hmac(_k, _v);
    }
  }

  static Uint8List _hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

  static Uint8List _bits2octets(Uint8List h) {
    final z = bytesToBigInt(h) % Secp256k1.n;
    return toBytes32(z);
  }
}

BigInt bytesToBigInt(List<int> bytes) {
  var r = BigInt.zero;
  for (final b in bytes) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

Uint8List toBytes32(BigInt v) {
  if (v.isNegative || v.bitLength > 256) throw ArgumentError('out of range');
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}
