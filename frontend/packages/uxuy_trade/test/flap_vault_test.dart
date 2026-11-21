import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';

const zero = '0x0000000000000000000000000000000000000000';
const creator = '0x0000000000000000000000000000000000000001';
const factory = '0x889C64Ba9fe1A0E371EDe0579098E0bd71135232';
const quote = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';
final schema = FlapVaultSchema(
  fields: const [FlapVaultField(name: 'amount', type: 'uint256', decimals: 6)],
);
String encode(List<String> types, List<Object?> values) =>
    bytesToHex(encodeSequence(types.map(AbiType.parse).toList(), values));
FlapVaultLaunchContext context({
  String recipient = zero,
  String who = creator,
  int vault = 10000,
}) => FlapVaultLaunchContext(
  creator: who,
  quoteToken: zero,
  tokenVersion: 6,
  buyTaxBps: 300,
  sellTaxBps: 300,
  vaultBps: vault,
  burnBps: 0,
  dividendBps: 0,
  liquidityBps: 0,
  dividendToken: recipient,
  minimumShare: BigInt.from(10000),
);
Matcher get formatError =>
    isA<FormatException>().having((e) => e.message, 'message', '金库格式有误');

class Backend extends BackendClient {
  Backend()
    : super(
        Uri.parse('http://fixture.invalid/'),
        MockClient((r) async => throw StateError('No network')),
      );
  FlapVaultSchema currentSchema = schema;
  String? version = 'v2.3';
  bool support = true, registered = false, hook = true;
  int permission = 0;
  Uint8List permissionData = Uint8List(32);
  List<FlapVaultPolicy> policies = [];
  Object? schemaError;
  String? rawSchema;
  final seen = <String>[];
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    expect(calls.single.$1, 'eth_getCode');
    return ['0x6000'];
  }

  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    final functions = <String, String>{
      'vaultDataSchema()': '((string,(string,string,string,uint8)[],bool))',
      'factorySpecVersion()': '(string)',
      'tokenCreationPolicies()': '((string,string,bytes,string)[])',
      'isQuoteTokenSupported(address)': '(bool)',
      'vaultFactories(address)': '(bool,bool,uint8,bytes29)',
      'getFactoryPolicy(address)': '(uint8,bytes32,string)',
      'onBeforeLaunch(bytes)': '(bool,string)',
    };
    for (final entry in functions.entries) {
      final f = AbiFunction.parse('${entry.key} returns ${entry.value}');
      if (!data.startsWith(bytesToHex(f.selector))) continue;
      seen.add(f.name);
      final values = switch (f.name) {
        'vaultDataSchema' => [
          <Object?>[
            currentSchema.description,
            [
              for (final field in currentSchema.fields)
                [field.name, field.type, field.description, field.decimals],
            ],
            currentSchema.isArray,
          ],
        ],
        'factorySpecVersion' => [version],
        'tokenCreationPolicies' => [
          [
            for (final p in policies)
              [p.target, p.operator, p.value, p.description],
          ],
        ],
        'isQuoteTokenSupported' => [support],
        'vaultFactories' => [registered, false, 0, Uint8List(29)],
        'getFactoryPolicy' => [permission, permissionData, 'permission'],
        'onBeforeLaunch' => [hook, hook ? '' : 'blocked by hook'],
        _ => throw StateError('unexpected'),
      };
      if (f.name == 'vaultDataSchema') {
        if (schemaError != null) throw schemaError!;
        if (rawSchema != null) return rawSchema!;
      }
      if (f.name == 'factorySpecVersion' && version == null)
        throw const BackendException('RPC_ERROR', 'execution reverted', false);
      return bytesToHex(encodeSequence(f.outputs, values));
    }
    throw StateError('unexpected call');
  }
}

void main() {
  test('exact decimals and overflow; no blank, exponent or floating point guessing', () {
    const f = FlapVaultField(name: 'amount', type: 'uint256', decimals: 6);
    expect(f.parse('1.000001'), BigInt.from(1000001));
    expect(f.parse('1.0000010'), BigInt.from(1000001));
    for (final value in ['1.0000001', '', '1e3', '-1']) {
      expect(() => f.parse(value), throwsFormatException);
    }
    expect(
      () => const FlapVaultField(name: 'bps', type: 'uint16').parse('65536'),
      throwsFormatException,
    );
    expect(
      () => const FlapVaultField(
        name: 'x',
        type: 'uint[]',
      ).parse('[9007199254740992]'),
      throwsFormatException,
    );
  });
  test('single tuple and tuple array byte parity including dynamic text', () {
    final s = FlapVaultSchema(
      fields: const [
        FlapVaultField(name: 'wallet', type: 'address'),
        FlapVaultField(name: 'memo', type: 'string'),
        FlapVaultField(name: 'amount', type: 'uint128', decimals: 6),
      ],
    );
    final rows = [
      {'wallet': creator, 'memo': '测试', 'amount': '1.25'},
    ];
    expect(
      bytesToHex(s.encode(rows)),
      encode(
        ['(address,string,uint128)'],
        [
          [creator, '测试', BigInt.from(1250000)],
        ],
      ),
    );
    final a = FlapVaultSchema(fields: s.fields, isArray: true);
    expect(
      bytesToHex(a.encode([...rows, ...rows])),
      encode(
        ['(address,string,uint128)[]'],
        [
          [
            [creator, '测试', BigInt.from(1250000)],
            [creator, '测试', BigInt.from(1250000)],
          ],
        ],
      ),
    );
  });
  test(
    'documented zero-field schema is empty bytes; field lists immutable',
    () {
      final s = FlapVaultSchema(fields: []);
      expect(s.encode([{}]), isEmpty);
      expect(
        () => s.fields.add(const FlapVaultField(name: 'x', type: 'uint256')),
        throwsUnsupportedError,
      );
    },
  );
  test('array fields accept newline and exact JSON strings; time alias is integer seconds', () {
    const field = FlapVaultField(name: 'amounts', type: 'uint16[]');
    expect(field.parse('10\n20'), [BigInt.from(10), BigInt.from(20)]);
    expect(field.parse('["10","20"]'), [BigInt.from(10), BigInt.from(20)]);
    expect(
      const FlapVaultField(name: 'at', type: 'time').parse('123'),
      BigInt.from(123),
    );
  });
  test('invalid schemas have exact requested message; no arbitrary tuples or msg.value', () {
    for (final type in [
      'uint7',
      'uint0256',
      'bytes01',
      'uint[01]',
      'bytes33',
      'address[][]',
      '(address,uint16)',
      'msg.value',
      'function',
    ]) {
      expect(
        () => FlapVaultSchema(
          fields: [FlapVaultField(name: 'x', type: type)],
        ).validate(),
        throwsA(formatError),
      );
    }
    expect(
      () => FlapVaultSchema(
        fields: const [
          FlapVaultField(name: 'x', type: 'uint16'),
          FlapVaultField(name: 'x', type: 'string'),
        ],
      ).validate(),
      throwsA(formatError),
    );
    expect(
      () => FlapVaultSchema(
        fields: const [
          FlapVaultField(name: 'x', type: 'address', decimals: 18),
        ],
      ).validate(),
      throwsA(formatError),
    );
  });
  test(
    'complete row validation does not silently drop or invent parameters',
    () {
      expect(() => schema.encode([{}]), throwsFormatException);
      expect(
        () => schema.encode([
          {'amount': '1', 'extra': '2'},
        ]),
        throwsFormatException,
      );
      expect(
        () => schema.encode([
          {'amount': '1'},
          {'amount': '2'},
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'read unregistered standard factory and enforce quote support',
    () async {
      final api = Backend();
      final s = FlapVaultService(api);
      final info = await s.read(factory, quoteToken: zero);
      expect(info.registered, isFalse);
      expect(info.schema.fields.single.decimals, 6);
      api.support = false;
      await expectLater(
        s.read(factory, quoteToken: quote),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('不支持'),
          ),
        ),
      );
    },
  );
  test(
    'network/schema failures remain distinct; no transport legacy fallback',
    () async {
      final api = Backend();
      final s = FlapVaultService(api);
      api.schemaError = const BackendException(
        'RPC_ERROR',
        'execution reverted',
        false,
      );
      await expectLater(
        s.read(factory, quoteToken: zero),
        throwsA(formatError),
      );
      final legacy = await s.read(
        factory,
        quoteToken: zero,
        legacySchema: schema,
      );
      expect(legacy.schema.fields.single.name, 'amount');
      api.schemaError = const BackendException(
        'RPC_ERROR',
        'connection lost',
        true,
      );
      await expectLater(
        s.read(factory, quoteToken: zero, legacySchema: schema),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '金库读取失败，请重试'),
        ),
      );
      api.schemaError = TimeoutException('slow');
      await expectLater(
        s.read(factory, quoteToken: zero),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '金库读取超时，请重试'),
        ),
      );
    },
  );
  test('malicious dynamic offset/count is bounded before allocation', () async {
    final api = Backend();
    final s = FlapVaultService(api);
    api.rawSchema = encode(['uint256'], [BigInt.one << 255]);
    await expectLater(s.read(factory, quoteToken: zero), throwsA(formatError));
    final valid = hexToBytes(
      encode(
        ['(string,(string,string,string,uint8)[],bool)'],
        [
          [
            'schema',
            [
              ['amount', 'uint256', '', 6],
            ],
            false,
          ],
        ],
      ),
    );
    final fieldsOffset =
        (decodeSequence([AbiType.parse('uint256')], valid, 64).single as BigInt)
            .toInt();
    valid.fillRange(32 + fieldsOffset, 64 + fieldsOffset, 255);
    api.rawSchema = bytesToHex(valid);
    await expectLater(s.read(factory, quoteToken: zero), throwsA(formatError));
    api.rawSchema = '0x12';
    await expectLater(s.read(factory, quoteToken: zero), throwsA(formatError));
  });
  test('changed live schema invalidates saved draft', () async {
    final api = Backend();
    final s = FlapVaultService(api);
    final info = await s.read(factory, quoteToken: zero);
    final selection = FlapVaultSelection(
      info: info,
      rows: [
        {'amount': '1'},
      ],
    );
    api.currentSchema = FlapVaultSchema(
      fields: const [
        FlapVaultField(name: 'amount', type: 'uint256', decimals: 18),
      ],
    );
    await expectLater(
      s.revalidate(selection, context()),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('已更新')),
      ),
    );
  });
  test('v2.2+ hook rejects before full transaction; successful validation returns exact bytes', () async {
    final api = Backend();
    final s = FlapVaultService(api);
    final info = await s.read(factory, quoteToken: zero);
    final selection = FlapVaultSelection(
      info: info,
      rows: [
        {'amount': '1'},
      ],
    );
    final ok = await s.revalidate(selection, context());
    expect(ok.data, selection.encode());
    expect(api.seen, contains('onBeforeLaunch'));
    api.hook = false;
    await expectLater(
      s.revalidate(selection, context()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('blocked by hook'),
        ),
      ),
    );
  });
  test(
    'permission disabled and timed creator-only policies enforced',
    () async {
      final api = Backend();
      final s = FlapVaultService(
        api,
        now: () => DateTime.fromMillisecondsSinceEpoch(1000 * 100),
      );
      api.permission = 2;
      await expectLater(s.read(factory, quoteToken: zero), throwsStateError);
      api.permission = 1;
      api.permissionData = encodeSequence(
        [AbiType.parse('uint256')],
        [(BigInt.from(1000) << 192) | (BigInt.from(2) << 32)],
      );
      final selection = FlapVaultSelection(
        info: await s.read(factory, quoteToken: zero),
        rows: [
          {'amount': '1'},
        ],
      );
      await expectLater(s.revalidate(selection, context()), throwsStateError);
      final allowed = await s.revalidate(
        selection,
        context(who: '0x0000000000000000000000000000000000000002'),
      );
      expect(allowed.data, isNotEmpty);
    },
  );
  test('known policy comparisons and future rule warning', () {
    final expected = encodeSequence(
      [AbiType.parse('uint256[]')],
      [
        [BigInt.from(100), BigInt.from(300)],
      ],
    );
    final policies = [
      FlapVaultPolicy(target: 'buyTaxRate', operator: 'in', value: expected),
      FlapVaultPolicy(
        target: 'dividendToken',
        operator: 'eqQuoteToken',
        value: [],
      ),
      FlapVaultPolicy(
        target: 'future',
        operator: 'newRule',
        value: [],
        description: 'future rule',
      ),
    ];
    expect(validatePolicies(policies, context()), [contains('future rule')]);
    expect(
      () => validatePolicies(policies, context(recipient: creator)),
      throwsStateError,
    );
  });
  test('selection rows are immutable snapshots', () {
    final rows = [
      {'amount': '1'},
    ];
    final selection = FlapVaultSelection(
      info: FlapVaultInfo(factory: factory, quoteToken: zero, schema: schema),
      rows: rows,
    );
    final before = selection.fingerprint;
    rows.single['amount'] = '2';
    expect(selection.fingerprint, before);
    expect(() => selection.rows.single['amount'] = '3', throwsUnsupportedError);
  });
  test('real user Factory schema supports all nine documented fields without registry gate', () async {
    final api = Backend();
    api.currentSchema = FlapVaultSchema(
      description: 'StockVault',
      fields: const [
        FlapVaultField(name: 'creatorWallet', type: 'address'),
        FlapVaultField(name: 'creatorBps', type: 'uint16'),
        FlapVaultField(name: 'ownBurnBps', type: 'uint16'),
        FlapVaultField(name: 'thirdBurnBps', type: 'uint16'),
        FlapVaultField(name: 'fissionBps', type: 'uint16'),
        FlapVaultField(name: 'burnToken', type: 'address'),
        FlapVaultField(name: 'intervalSeconds', type: 'uint256'),
        FlapVaultField(name: 'spendBps', type: 'uint16'),
        FlapVaultField(name: 'fissionRecipients', type: 'uint16'),
      ],
    );
    final service = FlapVaultService(api);
    final info = await service.read(factory, quoteToken: zero);
    final selection = FlapVaultSelection(
      info: info,
      rows: [
        {
          'creatorWallet': creator,
          'creatorBps': '3300',
          'ownBurnBps': '6600',
          'thirdBurnBps': '0',
          'fissionBps': '100',
          'burnToken': zero,
          'intervalSeconds': '10',
          'spendBps': '100',
          'fissionRecipients': '10',
        },
      ],
    );
    final result = await service.revalidate(selection, context());
    expect(result.info.registered, isFalse);
    expect(
      bytesToHex(result.data),
      encode(
        ['(address,uint16,uint16,uint16,uint16,address,uint256,uint16,uint16)'],
        [
          [creator, 3300, 6600, 0, 100, zero, 10, 100, 10],
        ],
      ),
    );
  });
}
