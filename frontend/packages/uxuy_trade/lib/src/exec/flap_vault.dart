import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/backend_client.dart';
import '../crypto/keccak.dart';
import '../crypto/secp256k1.dart' show bytesToBigInt;
import '../evm/abi.dart';
import '../evm/evm.dart';

const flapVaultPortalAddress = '0x90497450f2a706f1951b5bdda52b4e5d16f34c06';
const flapV7GiftFactory = '0x6909aD1822Ece349CDDAb98E6F62EeeD9fAa2e10';
const flapV7LegacyGiftFactory = '0x025549F52B03cF36f9e1a337c02d3AA7Af66ab32';
const flapV7VaultRejection = 'Flap 当前链上规则拒绝 V7 无税金库（NewTokenV7RuleViolation(8)）';
bool isFlapV7GiftFactory(String address) =>
    address.toLowerCase() == flapV7GiftFactory.toLowerCase() ||
    address.toLowerCase() == flapV7LegacyGiftFactory.toLowerCase();

const _zero = '0x0000000000000000000000000000000000000000';
const _zeroWord =
    '0x0000000000000000000000000000000000000000000000000000000000000000';
const _formatError = FormatException('金库格式有误');
const _maxItems = 128;
const _maxPayload = 65536;

/// Standard factory input, never a script or wallet capability descriptor.
class FlapVaultField {
  const FlapVaultField({
    required this.name,
    required this.type,
    this.description = '',
    this.decimals = 0,
  });
  final String name;
  final String type;
  final String description;
  final int decimals;
  String get abiType => type == 'time' || type.startsWith('time[')
      ? type.replaceFirst('time', 'uint256')
      : type;
  void validate() {
    if (name.trim().isEmpty || name.length > 128 || description.length > 8192)
      throw _formatError;
    final m = RegExp(
      r'^(address|bool|string|bytes(?:[0-9]+)?|u?int(?:[0-9]+)?|time)(\[([0-9]*)\])?$',
    ).firstMatch(type);
    if (m == null) throw _formatError;
    final base = m.group(1)!;
    final numeric = base.startsWith('uint') || base.startsWith('int');
    if (numeric) {
      final digits = base.replaceFirst(RegExp(r'^u?int'), '');
      final bits = digits.isEmpty ? 256 : int.tryParse(digits) ?? 0;
      if (bits < 8 ||
          bits > 256 ||
          bits % 8 != 0 ||
          (digits.isNotEmpty && bits.toString() != digits))
        throw _formatError;
    } else if (base.startsWith('bytes') && base != 'bytes') {
      final width = int.tryParse(base.substring(5)) ?? 0;
      if (width < 1 || width > 32 || width.toString() != base.substring(5))
        throw _formatError;
    }
    final count = m.group(3);
    if (count != null && count.isNotEmpty) {
      final n = int.tryParse(count) ?? 0;
      if (n < 1 || n > _maxItems || n.toString() != count) throw _formatError;
    }
    if (decimals < 0 || decimals > 77 || (!numeric && decimals != 0))
      throw _formatError;
  }

  Map<String, Object> get shape => {
    'name': name,
    'type': type,
    'decimals': decimals,
  };
  Object parse(String input) {
    validate();
    final t = AbiType.parse(abiType);
    if (t is ArrayType || t is FixedArrayType) {
      Object? decoded;
      try {
        decoded = input.trimLeft().startsWith('[')
            ? jsonDecode(input)
            : input
                  .split(RegExp(r'[,\r\n]+'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
      } on Object {
        throw FormatException('$name 数组格式有误');
      }
      if (decoded is! List || decoded.length > _maxItems)
        throw FormatException('$name 数组内容有误');
      final element = t is ArrayType
          ? t.element
          : (t as FixedArrayType).element;
      if (t is FixedArrayType && decoded.length != t.length)
        throw FormatException('$name 需要 ${t.length} 项');
      return [
        for (final v in decoded) _parseScalar(element, v, name, decimals),
      ];
    }
    return _parseScalar(t, input, name, decimals);
  }
}

Object _parseScalar(AbiType type, Object? input, String name, int decimals) {
  if (input is List ||
      input is Map ||
      input == null ||
      input is double ||
      (input is int && input.abs() > 9007199254740991))
    throw FormatException('$name 参数有误；数值请使用十进制字符串');
  final text = '$input';
  if (text.length > 16384) throw FormatException('$name 内容过长');
  if (type is StringType) return text;
  final value = text.trim();
  if (type is UintType || type is IntType) {
    final m = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]+))?$').firstMatch(value);
    if (m == null) throw FormatException('$name 请输入有效的十进制数值');
    var fraction = m.group(3) ?? '';
    if (fraction.length > decimals) {
      if (!RegExp(r'^0*$').hasMatch(fraction.substring(decimals)))
        throw FormatException('$name 最多支持 $decimals 位小数');
      fraction = fraction.substring(0, decimals);
    }
    var result = BigInt.parse(m.group(2)!) * BigInt.from(10).pow(decimals);
    if (decimals > 0) result += BigInt.parse(fraction.padRight(decimals, '0'));
    if (m.group(1) == '-') result = -result;
    try {
      type.encode(result);
    } on Object {
      throw FormatException('$name 超出允许范围');
    }
    return result;
  }
  if (type is AddressType) {
    if (!isAddress(value)) throw FormatException('$name 地址格式有误');
    return checksumAddress(value);
  }
  if (type is BoolType) {
    if (value == 'true') return true;
    if (value == 'false') return false;
    throw FormatException('$name 只能为 true 或 false');
  }
  if (type is BytesType || type is FixedBytesType) {
    if (!RegExp(r'^0x(?:[0-9a-fA-F]{2})*$').hasMatch(value))
      throw FormatException('$name 请输入完整十六进制字节');
    final data = hexToBytes(value);
    try {
      type.encode(data);
    } on Object {
      throw FormatException('$name 字节长度有误');
    }
    return data;
  }
  throw _formatError;
}

class FlapVaultSchema {
  FlapVaultSchema({
    this.description = '',
    this.isArray = false,
    required List<FlapVaultField> fields,
  }) : fields = List.unmodifiable(fields);
  final String description;
  final bool isArray;
  final List<FlapVaultField> fields;
  void validate() {
    if (description.length > 16384 ||
        fields.length > 64 ||
        (isArray && fields.isEmpty))
      throw _formatError;
    final names = <String>{};
    for (final field in fields) {
      field.validate();
      if (!names.add(field.name)) throw _formatError;
    }
  }

  Map<String, Object> get shape => {
    'isArray': isArray,
    'fields': [for (final f in fields) f.shape],
  };
  String get fingerprint => _fingerprint(shape);
  Uint8List encode(List<Map<String, String>> rows) {
    validate();
    if ((!isArray && rows.length != 1) ||
        rows.length > _maxItems ||
        (isArray && rows.isEmpty))
      throw FormatException(
        isArray ? '请填写金库配置，最多 $_maxItems 项' : '金库配置只允许一组参数',
      );
    final names = fields.map((f) => f.name).toSet();
    final values = <List<Object?>>[];
    for (final row in rows) {
      if (row.length != fields.length || !row.keys.every(names.contains))
        throw const FormatException('请完整填写金库参数');
      values.add([for (final f in fields) f.parse(row[f.name]!)]);
    }
    if (fields.isEmpty) return Uint8List(0);
    final tuple = TupleType(
      fields.map((f) => AbiType.parse(f.abiType)).toList(),
    );
    final result = encodeSequence(
      [isArray ? ArrayType(tuple) : tuple],
      [isArray ? values : values.single],
    );
    if (result.length > _maxPayload) throw const FormatException('金库参数内容过长');
    return result;
  }
}

class FlapVaultPolicy {
  FlapVaultPolicy({
    required this.target,
    required this.operator,
    required List<int> value,
    this.description = '',
  }) : value = Uint8List.fromList(value);
  final String target;
  final String operator;
  final Uint8List value;
  final String description;
}

class FlapVaultInfo {
  FlapVaultInfo({
    required this.factory,
    required this.quoteToken,
    required this.schema,
    this.specVersion,
    List<FlapVaultPolicy> policies = const [],
    this.registered = false,
    this.official = false,
    this.riskLevel = 0,
    this.permission = 0,
    this.permissionDescription = '',
    this.permissionData = _zeroWord,
    this.supportsQuote = true,
    String? wireSchemaFingerprint,
  }) : policies = List.unmodifiable(policies),
       wireSchemaFingerprint = wireSchemaFingerprint ?? schema.fingerprint;
  final String factory;
  final String quoteToken;
  final FlapVaultSchema schema;
  final String? specVersion;
  final List<FlapVaultPolicy> policies;

  /// Registry status is informational: unregistered standard factories are allowed by Portal.
  final bool registered;
  final bool official;
  final int riskLevel;
  final int permission;
  final String permissionDescription;
  final String permissionData;
  final bool supportsQuote;
  final String wireSchemaFingerprint;
  String get schemaFingerprint => _fingerprint({
    'factory': factory.toLowerCase(),
    'wire': wireSchemaFingerprint,
    'effective': schema.shape,
  });
}

/// Immutable human inputs. Reviewed curated adapters may subclass to encode an
/// exact documented factory format; this class has no raw-calldata override.
class FlapVaultSelection {
  FlapVaultSelection({
    required this.info,
    required List<Map<String, String>> rows,
    this.legacySchema,
  }) : rows = List.unmodifiable(
         rows.map((r) => Map<String, String>.unmodifiable(r)),
       );
  final FlapVaultInfo info;
  final List<Map<String, String>> rows;
  final FlapVaultSchema? legacySchema;
  String get factory => info.factory;
  Uint8List encode() => info.schema.encode(rows);
  String get fingerprint => _fingerprint({
    'schema': info.schemaFingerprint,
    'quote': info.quoteToken.toLowerCase(),
    'data': bytesToHex(encode()),
  });
}

class FlapVaultLaunchContext {
  const FlapVaultLaunchContext({
    required this.creator,
    required this.quoteToken,
    required this.tokenVersion,
    required this.buyTaxBps,
    required this.sellTaxBps,
    required this.vaultBps,
    required this.burnBps,
    required this.dividendBps,
    required this.liquidityBps,
    required this.dividendToken,
    required this.minimumShare,
    this.migratorType = 1,
    this.dexId = 0,
  });
  final String creator;
  final String quoteToken;
  final int tokenVersion;
  final int buyTaxBps;
  final int sellTaxBps;
  final int vaultBps;
  final int burnBps;
  final int dividendBps;
  final int liquidityBps;
  final String dividendToken;
  final BigInt minimumShare;
  final int migratorType;
  final int dexId;
  Map<String, Object> get values => {
    'tokenVersion': tokenVersion,
    'quoteToken': quoteToken,
    'buyTaxRate': buyTaxBps,
    'buyTaxBps': buyTaxBps,
    'sellTaxRate': sellTaxBps,
    'sellTaxBps': sellTaxBps,
    'taxBps': buyTaxBps,
    'mktBps': vaultBps,
    'vaultBps': vaultBps,
    'marketingBps': vaultBps,
    'deflationBps': burnBps,
    'burnBps': burnBps,
    'dividendBps': dividendBps,
    'lpBps': liquidityBps,
    'liquidityBps': liquidityBps,
    'dividendToken': dividendToken,
    'minimumShareBalance': minimumShare,
    'migratorType': migratorType,
    'dexId': dexId,
  };
  Uint8List encodeValidation() => encodeSequence(
    [
      AbiType.parse(
        '(uint8,address,uint16,uint16,uint16,uint16,uint16,uint16,address,uint256)',
      ),
    ],
    [
      [
        tokenVersion,
        quoteToken,
        buyTaxBps,
        sellTaxBps,
        vaultBps,
        burnBps,
        dividendBps,
        liquidityBps,
        dividendToken,
        minimumShare,
      ],
    ],
  );
}

class FlapVaultValidation {
  FlapVaultValidation({
    required this.info,
    required List<String> warnings,
    required List<int> data,
  }) : warnings = List.unmodifiable(warnings),
       data = Uint8List.fromList(data);
  final FlapVaultInfo info;
  final List<String> warnings;
  final Uint8List data;
}

final _schemaCall = AbiFunction.parse(
  'vaultDataSchema() returns ((string,(string,string,string,uint8)[],bool))',
);
final _versionCall = AbiFunction.parse('factorySpecVersion() returns (string)');
final _policiesCall = AbiFunction.parse(
  'tokenCreationPolicies() returns ((string,string,bytes,string)[])',
);
final _quoteCall = AbiFunction.parse(
  'isQuoteTokenSupported(address) returns (bool)',
);
final _registryCall = AbiFunction.parse(
  'vaultFactories(address) returns (bool,bool,uint8,bytes29)',
);
final _permissionCall = AbiFunction.parse(
  'getFactoryPolicy(address) returns (uint8,bytes32,string)',
);
final _hookCall = AbiFunction.parse(
  'onBeforeLaunch(bytes) returns (bool,string)',
);

class FlapVaultService {
  FlapVaultService(this.api, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final BackendClient api;
  final DateTime Function() _now;

  /// Independent reads run concurrently. Transport errors never become a legacy fallback.
  Future<FlapVaultInfo> read(
    String factory, {
    required String quoteToken,
    FlapVaultSchema? legacySchema,
  }) async {
    if (!isAddress(factory) ||
        factory.toLowerCase() == _zero ||
        !isAddress(quoteToken))
      throw _formatError;
    final address = checksumAddress(factory),
        quote = checksumAddress(quoteToken);
    legacySchema?.validate();
    final results = await Future.wait<Object?>([
      _code(address),
      _call(address, _schemaCall, [], optional: legacySchema != null),
      _call(address, _versionCall, [], optional: true),
      _call(address, _policiesCall, [], optional: true),
      _call(address, _quoteCall, [quote]),
      _call(flapVaultPortalAddress, _registryCall, [address]),
      _call(flapVaultPortalAddress, _permissionCall, [address]),
    ]);
    final schemaResult = results[1] as List<Object?>?;
    final wire = schemaResult == null
        ? null
        : _parseSchema(schemaResult.single);
    final schema = legacySchema != null && (wire == null || wire.fields.isEmpty)
        ? legacySchema
        : wire;
    if (schema == null) throw _formatError;
    final versionResult = results[2] as List<Object?>?;
    final version = versionResult?.single as String?;
    if (version != null && (version.isEmpty || version.length > 128))
      throw _formatError;
    final policyResult = results[3] as List<Object?>?;
    final policies = <FlapVaultPolicy>[];
    if (policyResult != null) {
      for (final item in policyResult.single as List) {
        final row = item as List;
        policies.add(
          FlapVaultPolicy(
            target: row[0] as String,
            operator: row[1] as String,
            value: row[2] as List<int>,
            description: row[3] as String,
          ),
        );
      }
    }
    final registration = results[5] as List<Object?>,
        permission = results[6] as List<Object?>;
    final policy = (permission[0] as BigInt).toInt();
    if (policy < 0 || policy > 2) throw _formatError;
    final info = FlapVaultInfo(
      factory: address,
      quoteToken: quote,
      schema: schema,
      specVersion: version,
      policies: policies,
      registered: registration[0] == true,
      official: registration[1] == true,
      riskLevel: (registration[2] as BigInt).toInt(),
      permission: policy,
      permissionData: bytesToHex(permission[1] as List<int>),
      permissionDescription: permission[2] as String,
      supportsQuote: (results[4] as List).single == true,
      wireSchemaFingerprint:
          wire?.fingerprint ?? 'documented-legacy-schema-unavailable',
    );
    if (!info.supportsQuote) throw StateError('该金库不支持当前底池代币');
    if (info.permission == 2) throw StateError('该金库已停止开放发行');
    return info;
  }

  Future<FlapVaultValidation> revalidate(
    FlapVaultSelection selection,
    FlapVaultLaunchContext context,
  ) async {
    if (!isAddress(context.creator) ||
        context.creator.toLowerCase() == _zero ||
        !isAddress(context.dividendToken))
      throw _formatError;
    if (selection.info.quoteToken.toLowerCase() !=
        context.quoteToken.toLowerCase())
      throw StateError('底池代币已变化，请重新读取金库');
    final fresh = await read(
      selection.factory,
      quoteToken: context.quoteToken,
      legacySchema: selection.legacySchema,
    );
    if (fresh.schemaFingerprint != selection.info.schemaFingerprint ||
        fresh.specVersion != selection.info.specVersion)
      throw StateError('金库参数格式已更新，请重新读取并确认');
    _checkPermission(fresh, context.creator);
    if (context.vaultBps <= 0) throw StateError('启用金库时，金库收益分配必须大于 0');
    final warnings = validatePolicies(fresh.policies, context);
    final version = RegExp(r'^v?(\d+)\.(\d+)(?:\.\d+)?$')
        .firstMatch(fresh.specVersion ?? '');
    if (fresh.specVersion != null && version == null) throw _formatError;
    if (version != null) {
      final major = int.parse(version.group(1)!),
          minor = int.parse(version.group(2)!);
      if (major > 2) throw _formatError;
      if (major == 2 && minor >= 2) {
        final result = await _call(fresh.factory, _hookCall, [
          context.encodeValidation(),
        ]);
        if (result![0] != true) {
          final reason = result[1] as String;
          throw StateError(
            reason.trim().isEmpty ? '金库校验未通过，请检查发行参数' : '金库校验未通过：$reason',
          );
        }
      }
    }
    final encoded = selection.encode();
    if (encoded.length > _maxPayload) throw const FormatException('金库参数内容过长');
    return FlapVaultValidation(info: fresh, warnings: warnings, data: encoded);
  }

  void _checkPermission(FlapVaultInfo info, String creator) {
    if (info.permission == 2) throw StateError('该金库已停止开放发行');
    if (info.permission != 1) return;
    final slot = bytesToBigInt(hexToBytes(info.permissionData));
    final expires = slot >> 192,
        developer = (slot >> 32) & ((BigInt.one << 160) - BigInt.one);
    if ((slot & BigInt.from(0xffffffff)) != BigInt.zero) throw _formatError;
    if (expires > BigInt.from(_now().millisecondsSinceEpoch ~/ 1000) &&
        developer != BigInt.parse(creator.substring(2), radix: 16))
      throw StateError('该金库当前仅向指定创建者开放');
  }

  Future<void> _code(String factory) async {
    try {
      final code = (await api.rpc([
        ('eth_getCode', [factory, 'latest']),
      ])).single;
      if (code is! String || !RegExp(r'^0x(?:[0-9a-fA-F]{2})+$').hasMatch(code))
        throw _formatError;
    } on BackendException catch (e) {
      if (_isTransport(e)) throw StateError('金库读取失败，请重试');
      throw _formatError;
    } on TimeoutException {
      throw StateError('金库读取超时，请重试');
    } on http.ClientException {
      throw StateError('金库读取失败，请重试');
    }
  }

  Future<List<Object?>?> _call(
    String to,
    AbiFunction method,
    List<Object?> args, {
    bool optional = false,
  }) async {
    String raw;
    try {
      raw = await api.call(to, bytesToHex(method.encode(args)));
    } on BackendException catch (e) {
      if (_isTransport(e)) throw StateError('金库读取失败，请重试');
      if (optional &&
          RegExp(
            r'revert|method not found|function selector',
            caseSensitive: false,
          ).hasMatch(e.message))
        return null;
      if (method.name == 'onBeforeLaunch' &&
          RegExp(r'revert', caseSensitive: false).hasMatch(e.message)) {
        throw StateError('金库校验未通过，请检查发行参数');
      }
      throw _formatError;
    } on TimeoutException {
      throw StateError('金库读取超时，请重试');
    } on http.ClientException {
      throw StateError('金库读取失败，请重试');
    } on FormatException {
      throw _formatError;
    }
    if (raw == '0x' && optional) return null;
    try {
      return _boundedOutput(method, raw);
    } on Object {
      throw _formatError;
    }
  }
}

bool _isTransport(BackendException e) =>
    e.retryable ||
    RegExp(
      r'timeout|timed out|network|connection|fetch|unavailable|rate limit|429|502|503|missing trie|header not found|网络|超时|限流',
      caseSensitive: false,
    ).hasMatch(e.message);
FlapVaultSchema _parseSchema(Object? value) {
  try {
    final row = value as List;
    final schema = FlapVaultSchema(
      description: row[0] as String,
      fields: [
        for (final f in row[1] as List)
          FlapVaultField(
            name: (f as List)[0] as String,
            type: f[1] as String,
            description: f[2] as String,
            decimals: (f[3] as BigInt).toInt(),
          ),
      ],
      isArray: row[2] as bool,
    );
    schema.validate();
    return schema;
  } on Object {
    throw _formatError;
  }
}

String _fingerprint(Object value) =>
    bytesToHex(keccak256(utf8.encode(jsonEncode(value))));

/// Informational forward-compatible policies: unknown rules are WARNINGS, never
/// silently recorded as passed. Full VaultPortal simulation remains mandatory.
List<String> validatePolicies(
  List<FlapVaultPolicy> policies,
  FlapVaultLaunchContext context,
) {
  final warnings = <String>[], values = context.values;
  for (final policy in policies) {
    final actual = values[policy.target];
    final expectedType =
        const {'quoteToken', 'dividendToken'}.contains(policy.target)
        ? 'address'
        : 'uint256';
    if (actual == null ||
        !const {
          'eq',
          'neq',
          'gt',
          'gte',
          'lt',
          'lte',
          'in',
          'notIn',
          'eqQuoteToken',
        }.contains(policy.operator)) {
      warnings.add(
        policy.description.isNotEmpty
            ? '需在完整模拟中核验：${policy.description}'
            : '需在完整模拟中核验金库规则：${policy.target} ${policy.operator}',
      );
      continue;
    }
    bool ok;
    try {
      if (policy.operator == 'eqQuoteToken') {
        if (expectedType != 'address' || policy.value.isNotEmpty)
          throw _formatError;
        ok = '$actual'.toLowerCase() == context.quoteToken.toLowerCase();
      } else {
        final isSet = policy.operator == 'in' || policy.operator == 'notIn';
        final decoded = _boundedSequence(
          [AbiType.parse('$expectedType${isSet ? '[]' : ''}')],
          policy.value,
          0,
          0,
        ).single;
        if (isSet) {
          final contains = (decoded as List).any(
            (v) => _same(actual, v, expectedType),
          );
          ok = policy.operator == 'in' ? contains : !contains;
        } else if (policy.operator == 'eq' || policy.operator == 'neq') {
          final same = _same(actual, decoded, expectedType);
          ok = policy.operator == 'eq' ? same : !same;
        } else {
          if (expectedType == 'address') throw _formatError;
          final left = BigInt.parse('$actual'), right = decoded as BigInt;
          ok = switch (policy.operator) {
            'gt' => left > right,
            'gte' => left >= right,
            'lt' => left < right,
            'lte' => left <= right,
            _ => false,
          };
        }
      }
    } on Object {
      throw _formatError;
    }
    if (!ok)
      throw StateError(
        policy.description.isNotEmpty
            ? '金库参数不符合要求：${policy.description}'
            : '金库参数不符合要求：${policy.target}',
      );
  }
  return warnings;
}

bool _same(Object a, Object? b, String type) => type == 'address'
    ? '$a'.toLowerCase() == '$b'.toLowerCase()
    : BigInt.parse('$a') == BigInt.parse('$b');

// Bound untrusted offsets/counts BEFORE allocating dynamic lists or strings.
List<Object?> _boundedOutput(AbiFunction fn, String hex) {
  if (hex.length > _maxPayload * 2 + 2 ||
      !RegExp(r'^0x(?:[0-9a-fA-F]{2})*$').hasMatch(hex))
    throw _formatError;
  return _boundedSequence(fn.outputs, hexToBytes(hex), 0, 0);
}

int _word(Uint8List bytes, int offset, {int? cap}) {
  if (offset < 0 || offset + 32 > bytes.length) throw _formatError;
  final n = bytesToBigInt(bytes.sublist(offset, offset + 32));
  if (n > BigInt.from(cap ?? bytes.length)) throw _formatError;
  return n.toInt();
}

List<Object?> _boundedSequence(
  List<AbiType> types,
  Uint8List bytes,
  int base,
  int depth,
) {
  if (depth > 12 || types.length > _maxItems) throw _formatError;
  var head = base;
  final headEnd = base + types.fold<int>(0, (sum, type) => sum + type.headSize);
  if (base < 0 || headEnd > bytes.length) throw _formatError;
  final result = <Object?>[];
  for (final type in types) {
    var position = head;
    if (type.isDynamic) {
      final offset = _word(bytes, head);
      position = base + offset;
      if (offset % 32 != 0 || position < headEnd || position >= bytes.length)
        throw _formatError;
    }
    result.add(_boundedValue(type, bytes, position, depth + 1));
    head += type.headSize;
  }
  return result;
}

Object? _boundedValue(AbiType type, Uint8List bytes, int offset, int depth) {
  if (depth > 12) throw _formatError;
  if (type is TupleType)
    return _boundedSequence(type.components, bytes, offset, depth);
  if (type is ArrayType) {
    final count = _word(bytes, offset, cap: _maxItems);
    return _boundedSequence(
      List.filled(count, type.element),
      bytes,
      offset + 32,
      depth,
    );
  }
  if (type is FixedArrayType) {
    if (type.length > _maxItems) throw _formatError;
    return _boundedSequence(
      List.filled(type.length, type.element),
      bytes,
      offset,
      depth,
    );
  }
  if (type is StringType || type is BytesType) {
    final count = _word(bytes, offset, cap: 16384);
    if (offset + 32 + count > bytes.length) throw _formatError;
    final value = bytes.sublist(offset + 32, offset + 32 + count);
    return type is StringType
        ? utf8.decode(value, allowMalformed: false)
        : Uint8List.fromList(value);
  }
  if (offset < 0 || offset + type.headSize > bytes.length) throw _formatError;
  return type.decode(bytes, offset);
}
