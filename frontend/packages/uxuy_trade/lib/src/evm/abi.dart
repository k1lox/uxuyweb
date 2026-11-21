import 'dart:convert';
import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../crypto/secp256k1.dart' show bytesToBigInt, toBytes32;
import 'evm.dart';

/// Solidity ABI codec (static/dynamic types, nested tuples and arrays).
/// Values: BigInt for (u)int, checksummed String for address, bool, Uint8List for bytes/bytesN,
/// String for string, `List<Object?>` for arrays and tuples.
abstract class AbiType {
  const AbiType();

  bool get isDynamic;

  /// Size in the head when static.
  int get headSize => 32;

  Uint8List encode(Object? value);

  /// Decode at [offset] inside [data] (head position for static types, start of tail for dynamic).
  Object? decode(Uint8List data, int offset);

  String get signature;

  static AbiType parse(String text) =>
      _Parser(text.replaceAll(' ', '')).parse();
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  AbiType parse() {
    final t = _type();
    if (i != s.length) throw FormatException('invalid ABI type: $s');
    return t;
  }

  AbiType _type() {
    AbiType base;
    if (i < s.length && s[i] == '(') {
      i++;
      final parts = <AbiType>[];
      if (s[i] != ')') {
        while (true) {
          parts.add(_type());
          // optional component name, e.g. "(address to,uint256 amount)"
          if (s[i] == ')') break;
          if (s[i] != ',') throw FormatException('invalid tuple: $s');
          i++;
        }
      }
      i++; // ')'
      base = TupleType(parts);
    } else {
      final start = i;
      while (i < s.length && RegExp(r'[a-z0-9]').hasMatch(s[i])) {
        i++;
      }
      base = _elementary(s.substring(start, i));
    }
    while (i < s.length && s[i] == '[') {
      final close = s.indexOf(']', i);
      final n = s.substring(i + 1, close);
      i = close + 1;
      base = n.isEmpty ? ArrayType(base) : FixedArrayType(base, int.parse(n));
    }
    return base;
  }

  AbiType _elementary(String name) {
    if (name == 'address') return const AddressType();
    if (name == 'bool') return const BoolType();
    if (name == 'string') return const StringType();
    if (name == 'bytes') return const BytesType();
    if (name == 'uint') return const UintType(256);
    if (name == 'int') return const IntType(256);
    final m = RegExp(r'^(uint|int|bytes)(\d+)$').firstMatch(name);
    if (m != null) {
      final n = int.parse(m.group(2)!);
      return switch (m.group(1)) {
        'uint' => UintType(n),
        'int' => IntType(n),
        _ => FixedBytesType(n),
      };
    }
    throw FormatException('unsupported ABI type: $name');
  }
}

Uint8List _word(BigInt v) => toBytes32(v);

BigInt _readWord(Uint8List data, int offset) {
  if (offset + 32 > data.length) {
    throw const FormatException('ABI data too short');
  }
  return bytesToBigInt(data.sublist(offset, offset + 32));
}

int _readOffset(Uint8List data, int offset) {
  final v = _readWord(data, offset);
  if (v > BigInt.from(data.length)) {
    throw const FormatException('ABI offset out of range');
  }
  return v.toInt();
}

class UintType extends AbiType {
  const UintType(this.bits);
  final int bits;
  @override
  bool get isDynamic => false;
  @override
  String get signature => 'uint$bits';
  @override
  Uint8List encode(Object? value) {
    final v = _big(value);
    if (v.isNegative || v.bitLength > bits) {
      throw FormatException('value out of range for $signature');
    }
    return _word(v);
  }

  @override
  Object? decode(Uint8List data, int offset) {
    final v = _readWord(data, offset);
    if (v.bitLength > bits) {
      throw FormatException('value out of range for $signature');
    }
    return v;
  }
}

class IntType extends AbiType {
  const IntType(this.bits);
  final int bits;
  @override
  bool get isDynamic => false;
  @override
  String get signature => 'int$bits';
  @override
  Uint8List encode(Object? value) {
    final v = _big(value);
    final limit = BigInt.one << (bits - 1);
    if (v >= limit || v < -limit) {
      throw FormatException('value out of range for $signature');
    }
    return _word(v.isNegative ? (BigInt.one << 256) + v : v);
  }

  @override
  Object? decode(Uint8List data, int offset) {
    final v = _readWord(data, offset);
    return v >= (BigInt.one << 255) ? v - (BigInt.one << 256) : v;
  }
}

class AddressType extends AbiType {
  const AddressType();
  @override
  bool get isDynamic => false;
  @override
  String get signature => 'address';
  @override
  Uint8List encode(Object? value) {
    final a = '$value';
    if (!isAddress(a)) throw FormatException('invalid address: $a');
    return Uint8List(32)..setRange(12, 32, hexToBytes(a));
  }

  @override
  Object? decode(Uint8List data, int offset) {
    final w = _readWord(data, offset);
    if (w.bitLength > 160) throw const FormatException('invalid address word');
    return checksumAddress(bytesToHex(toBytes32(w).sublist(12)));
  }
}

class BoolType extends AbiType {
  const BoolType();
  @override
  bool get isDynamic => false;
  @override
  String get signature => 'bool';
  @override
  Uint8List encode(Object? value) =>
      _word(value == true ? BigInt.one : BigInt.zero);
  @override
  Object? decode(Uint8List data, int offset) {
    final v = _readWord(data, offset);
    if (v > BigInt.one) throw const FormatException('invalid bool');
    return v == BigInt.one;
  }
}

class FixedBytesType extends AbiType {
  const FixedBytesType(this.size);
  final int size;
  @override
  bool get isDynamic => false;
  @override
  String get signature => 'bytes$size';
  @override
  Uint8List encode(Object? value) {
    final b = _bytes(value);
    if (b.length != size) throw FormatException('expected $size bytes');
    return Uint8List(32)..setRange(0, size, b);
  }

  @override
  Object? decode(Uint8List data, int offset) {
    if (offset + 32 > data.length) {
      throw const FormatException('ABI data too short');
    }
    return Uint8List.fromList(data.sublist(offset, offset + size));
  }
}

class BytesType extends AbiType {
  const BytesType();
  @override
  bool get isDynamic => true;
  @override
  String get signature => 'bytes';
  @override
  Uint8List encode(Object? value) {
    final b = _bytes(value);
    final padded = Uint8List(((b.length + 31) ~/ 32) * 32)
      ..setRange(0, b.length, b);
    return Uint8List.fromList([..._word(BigInt.from(b.length)), ...padded]);
  }

  @override
  Object? decode(Uint8List data, int offset) {
    final len = _readOffset(data, offset);
    if (offset + 32 + len > data.length) {
      throw const FormatException('ABI bytes out of range');
    }
    return Uint8List.fromList(data.sublist(offset + 32, offset + 32 + len));
  }
}

class StringType extends AbiType {
  const StringType();
  @override
  bool get isDynamic => true;
  @override
  String get signature => 'string';
  @override
  Uint8List encode(Object? value) =>
      const BytesType().encode(Uint8List.fromList(utf8.encode('$value')));
  @override
  Object? decode(Uint8List data, int offset) => utf8.decode(
    const BytesType().decode(data, offset)! as Uint8List,
    allowMalformed: true,
  );
}

class TupleType extends AbiType {
  const TupleType(this.components);
  final List<AbiType> components;
  @override
  bool get isDynamic => components.any((c) => c.isDynamic);
  @override
  int get headSize =>
      isDynamic ? 32 : components.fold(0, (a, c) => a + c.headSize);
  @override
  String get signature => '(${components.map((c) => c.signature).join(',')})';

  @override
  Uint8List encode(Object? value) {
    final values = value as List<Object?>;
    if (values.length != components.length) {
      throw FormatException(
        'tuple $signature expects ${components.length} values',
      );
    }
    return encodeSequence(components, values);
  }

  @override
  Object? decode(Uint8List data, int offset) =>
      decodeSequence(components, data, offset);
}

class ArrayType extends AbiType {
  const ArrayType(this.element);
  final AbiType element;
  @override
  bool get isDynamic => true;
  @override
  String get signature => '${element.signature}[]';
  @override
  Uint8List encode(Object? value) {
    final values = value as List<Object?>;
    return Uint8List.fromList([
      ..._word(BigInt.from(values.length)),
      ...encodeSequence(List.filled(values.length, element), values),
    ]);
  }

  @override
  Object? decode(Uint8List data, int offset) {
    final n = _readOffset(data, offset);
    if (n > 100000) throw const FormatException('ABI array too long');
    return decodeSequence(List.filled(n, element), data, offset + 32);
  }
}

class FixedArrayType extends AbiType {
  const FixedArrayType(this.element, this.length);
  final AbiType element;
  final int length;
  @override
  bool get isDynamic => element.isDynamic;
  @override
  int get headSize => isDynamic ? 32 : element.headSize * length;
  @override
  String get signature => '${element.signature}[$length]';
  @override
  Uint8List encode(Object? value) {
    final values = value as List<Object?>;
    if (values.length != length) {
      throw FormatException('$signature expects $length values');
    }
    return encodeSequence(List.filled(length, element), values);
  }

  @override
  Object? decode(Uint8List data, int offset) =>
      decodeSequence(List.filled(length, element), data, offset);
}

/// Head/tail encoding of a list of values.
Uint8List encodeSequence(List<AbiType> types, List<Object?> values) {
  final heads = <Uint8List>[];
  final tails = <Uint8List>[];
  var headLen = types.fold(0, (a, t) => a + t.headSize);
  var tailLen = 0;
  for (var i = 0; i < types.length; i++) {
    final t = types[i];
    if (t.isDynamic) {
      final enc = t.encode(values[i]);
      heads.add(_word(BigInt.from(headLen + tailLen)));
      tails.add(enc);
      tailLen += enc.length;
    } else {
      heads.add(t.encode(values[i]));
    }
  }
  return Uint8List.fromList([
    for (final h in heads) ...h,
    for (final t in tails) ...t,
  ]);
}

List<Object?> decodeSequence(List<AbiType> types, Uint8List data, int base) {
  final out = <Object?>[];
  var cursor = base;
  for (final t in types) {
    if (t.isDynamic) {
      out.add(t.decode(data, base + _readOffset(data, cursor)));
      cursor += 32;
    } else {
      out.add(t.decode(data, cursor));
      cursor += t.headSize;
    }
  }
  return out;
}

BigInt _big(Object? v) => switch (v) {
  final BigInt b => b,
  final int i => BigInt.from(i),
  final String s =>
    s.startsWith('0x')
        ? BigInt.parse(s.substring(2), radix: 16)
        : BigInt.parse(s),
  _ => throw FormatException('expected integer, got $v'),
};

Uint8List _bytes(Object? v) => switch (v) {
  final Uint8List b => b,
  final List<int> l => Uint8List.fromList(l),
  final String s => hexToBytes(s),
  _ => throw FormatException('expected bytes, got $v'),
};

/// A function definition like `function buy(address token,uint256 minOut) payable returns (uint256)`.
class AbiFunction {
  AbiFunction(this.name, this.inputs, this.outputs);

  factory AbiFunction.parse(String text) {
    final m = RegExp(
      r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*(?:(?:external|public|view|pure|payable|nonpayable)\s*)*(?:returns\s*\((.*)\))?\s*$',
    ).firstMatch(text);
    if (m == null) throw FormatException('invalid function: $text');
    return AbiFunction(
      m.group(1)!,
      _params(m.group(2)!),
      _params(m.group(3) ?? ''),
    );
  }

  final String name;
  final List<AbiType> inputs;
  final List<AbiType> outputs;

  String get signature => '$name(${inputs.map((t) => t.signature).join(',')})';
  Uint8List get selector => keccak256(utf8.encode(signature)).sublist(0, 4);

  Uint8List encode(List<Object?> args) {
    if (args.length != inputs.length) {
      throw FormatException('$signature expects ${inputs.length} arguments');
    }
    return Uint8List.fromList([...selector, ...encodeSequence(inputs, args)]);
  }

  String encodeHex(List<Object?> args) => bytesToHex(encode(args));

  List<Object?> decodeOutput(Object data) =>
      decodeSequence(outputs, _bytes(data), 0);

  List<Object?> decodeInput(Object data) {
    final b = _bytes(data);
    if (b.length < 4 || !_eq(b.sublist(0, 4), selector)) {
      throw FormatException('selector mismatch for $signature');
    }
    return decodeSequence(inputs, Uint8List.fromList(b.sublist(4)), 0);
  }
}

/// Event topic0 for `Name(type,...)`.
Uint8List eventTopic(String signature) =>
    keccak256(utf8.encode(signature.replaceAll(' ', '')));

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Split a parameter list at top-level commas and drop parameter names / data locations.
List<AbiType> _params(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == ',' && depth == 0) {
      parts.add(t.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(t.substring(start));
  return [for (final p in parts) AbiType.parse(_stripName(p.trim()))];
}

String _stripName(String p) {
  // "(address a,uint256 b)[] calldata items" -> "(address,uint256)[]"
  if (p.startsWith('(')) {
    var depth = 0;
    var end = 0;
    for (var i = 0; i < p.length; i++) {
      if (p[i] == '(') depth++;
      if (p[i] == ')') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final inner = _params(p.substring(1, end))
        .map((t) => t.signature)
        .join(',');
    final rest = p.substring(end + 1);
    final suffix = RegExp(r'^((?:\[\d*\])*)').firstMatch(rest)!.group(1)!;
    return '($inner)$suffix';
  }
  return p.split(RegExp(r'\s+')).first;
}
