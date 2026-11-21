import 'dart:typed_data';

/// Keccak-256 (Ethereum variant, pad 0x01).
/// Lanes are held as two 32-bit halves so results are identical on native (64-bit int) and web (JS numbers).
Uint8List keccak256(List<int> input) {
  const rate = 136;
  final lo = List<int>.filled(25, 0);
  final hi = List<int>.filled(25, 0);
  final padded = Uint8List(((input.length ~/ rate) + 1) * rate)
    ..setRange(0, input.length, input);
  padded[input.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  for (var off = 0; off < padded.length; off += rate) {
    for (var i = 0; i < rate ~/ 8; i++) {
      final b = off + i * 8;
      lo[i] = (lo[i] ^ _word(padded, b)) & _m;
      hi[i] = (hi[i] ^ _word(padded, b + 4)) & _m;
    }
    _keccakF(lo, hi);
  }
  final out = Uint8List(32);
  for (var i = 0; i < 4; i++) {
    for (var b = 0; b < 4; b++) {
      out[i * 8 + b] = (lo[i] >>> (8 * b)) & 0xff;
      out[i * 8 + 4 + b] = (hi[i] >>> (8 * b)) & 0xff;
    }
  }
  return out;
}

const _m = 0xffffffff;

int _word(Uint8List p, int b) =>
    (p[b] | (p[b + 1] << 8) | (p[b + 2] << 16) | (p[b + 3] << 24)) & _m;

/// Round constants as (hi, lo).
const _rcHi = <int>[
  0x00000000,
  0x00000000,
  0x80000000,
  0x80000000,
  0x00000000,
  0x00000000,
  0x80000000,
  0x80000000,
  0x00000000,
  0x00000000,
  0x00000000,
  0x00000000,
  0x00000000,
  0x80000000,
  0x80000000,
  0x80000000,
  0x80000000,
  0x80000000,
  0x00000000,
  0x80000000,
  0x80000000,
  0x80000000,
  0x00000000,
  0x80000000,
];
const _rcLo = <int>[
  0x00000001,
  0x00008082,
  0x0000808a,
  0x80008000,
  0x0000808b,
  0x80000001,
  0x80008081,
  0x00008009,
  0x0000008a,
  0x00000088,
  0x80008009,
  0x8000000a,
  0x8000808b,
  0x0000008b,
  0x00008089,
  0x00008003,
  0x00008002,
  0x00000080,
  0x0000800a,
  0x8000000a,
  0x80008081,
  0x00008080,
  0x80000001,
  0x80008008,
];

const _rotc = <int>[
  1,
  3,
  6,
  10,
  15,
  21,
  28,
  36,
  45,
  55,
  2,
  14,
  27,
  41,
  56,
  8,
  25,
  43,
  62,
  18,
  39,
  61,
  20,
  44,
];
const _piln = <int>[
  10,
  7,
  11,
  17,
  18,
  3,
  5,
  16,
  8,
  21,
  24,
  4,
  15,
  23,
  19,
  13,
  12,
  2,
  20,
  14,
  22,
  9,
  6,
  1,
];

// 64-bit rotate-left of (h, l) by n, returning the new high / low halves.
int _rotHi(int h, int l, int n) {
  if (n == 32) return l;
  if (n < 32) return ((h << n) | (l >>> (32 - n))) & _m;
  final k = n - 32;
  return ((l << k) | (h >>> (32 - k))) & _m;
}

int _rotLo(int h, int l, int n) {
  if (n == 32) return h;
  if (n < 32) return ((l << n) | (h >>> (32 - n))) & _m;
  final k = n - 32;
  return ((h << k) | (l >>> (32 - k))) & _m;
}

void _keccakF(List<int> lo, List<int> hi) {
  final cLo = List<int>.filled(5, 0);
  final cHi = List<int>.filled(5, 0);
  for (var round = 0; round < 24; round++) {
    // theta
    for (var i = 0; i < 5; i++) {
      cLo[i] = lo[i] ^ lo[i + 5] ^ lo[i + 10] ^ lo[i + 15] ^ lo[i + 20];
      cHi[i] = hi[i] ^ hi[i + 5] ^ hi[i + 10] ^ hi[i + 15] ^ hi[i + 20];
    }
    for (var i = 0; i < 5; i++) {
      final a = (i + 4) % 5;
      final b = (i + 1) % 5;
      final tLo = cLo[a] ^ _rotLo(cHi[b], cLo[b], 1);
      final tHi = cHi[a] ^ _rotHi(cHi[b], cLo[b], 1);
      for (var j = 0; j < 25; j += 5) {
        lo[j + i] = (lo[j + i] ^ tLo) & _m;
        hi[j + i] = (hi[j + i] ^ tHi) & _m;
      }
    }
    // rho + pi
    var tLo = lo[1];
    var tHi = hi[1];
    for (var i = 0; i < 24; i++) {
      final j = _piln[i];
      final sLo = lo[j];
      final sHi = hi[j];
      lo[j] = _rotLo(tHi, tLo, _rotc[i]);
      hi[j] = _rotHi(tHi, tLo, _rotc[i]);
      tLo = sLo;
      tHi = sHi;
    }
    // chi
    for (var j = 0; j < 25; j += 5) {
      for (var i = 0; i < 5; i++) {
        cLo[i] = lo[j + i];
        cHi[i] = hi[j + i];
      }
      for (var i = 0; i < 5; i++) {
        lo[j + i] =
            (lo[j + i] ^ ((~cLo[(i + 1) % 5] & _m) & cLo[(i + 2) % 5])) & _m;
        hi[j + i] =
            (hi[j + i] ^ ((~cHi[(i + 1) % 5] & _m) & cHi[(i + 2) % 5])) & _m;
      }
    }
    // iota
    lo[0] = (lo[0] ^ _rcLo[round]) & _m;
    hi[0] = (hi[0] ^ _rcHi[round]) & _m;
  }
}
