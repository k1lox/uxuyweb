import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';
import 'package:uxuy_trade/src/exec/flap_vault_adapters.dart';
import 'package:uxuy_trade/src/exec/flap_vault_catalog.dart';

const zero = '0x0000000000000000000000000000000000000000';
const a = '0x1111111111111111111111111111111111111111';
const b = '0x2222222222222222222222222222222222222222';
const bncb = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';
final fixtures = (jsonDecode(
  File('test/fixtures/flap_curated_schemas.json').readAsStringSync(),
) as Map).cast<String, dynamic>();
FlapVaultSchema schema(String factory) {
  final override = flapCuratedSchema(factory);
  if (override != null) return override;
  final raw = fixtures[factory.toLowerCase()]['schema'];
  return FlapVaultSchema(
    description: raw['description'] ?? '',
    isArray: raw['isArray'] ?? false,
    fields: [
      for (final f in raw['fields'] ?? [])
        FlapVaultField(
          name: f['name'],
          type: f['type'],
          description: f['description'] ?? '',
          decimals: f['decimals'],
        ),
    ],
  );
}

FlapVaultInfo info(String factory, {String quote = zero}) => FlapVaultInfo(
  factory: factory,
  quoteToken: quote,
  schema: schema(factory),
  registered: true,
);
CuratedFlapVaultSelection select(
  String factory,
  Map<String, String> row, {
  String quote = zero,
}) => buildFlapCuratedSelection(
  info: info(factory, quote: quote),
  rows: [row],
);
String factory(String name) =>
    flapCuratedVaults.singleWhere((v) => v.officialName == name).factory;
List<Object?> decode(String type, List<int> data) =>
    decodeSequence([AbiType.parse(type)], hexToBytes(bytesToHex(data)), 0);
FlapVaultLaunchContext context(
  CuratedFlapVaultSelection selection, {
  int vault = 10000,
  int dividend = 0,
  String quote = zero,
  String? dividendToken,
  BigInt? minimum,
}) => FlapVaultLaunchContext(
  creator: a,
  quoteToken: quote,
  tokenVersion: 6,
  buyTaxBps: 300,
  sellTaxBps: 300,
  vaultBps: vault,
  burnBps: 0,
  dividendBps: dividend,
  liquidityBps: 0,
  dividendToken: dividendToken ?? selection.dividendToken ?? zero,
  minimumShare: minimum ?? selection.minimumShare ?? parseUnits('10000', 18),
);

class ReadBackend extends BackendClient {
  ReadBackend()
    : super(
        Uri.parse('http://fixture.invalid'),
        MockClient((r) async => throw StateError('Unexpected HTTP')),
      );
  BigInt minimum = parseUnits('0.02', 18), credit = parseUnits('0.005', 18);
  bool fail = false;
  int reads = 0;
  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    reads++;
    if (fail) throw StateError('offline');
    if (data == bytesToHex(AbiFunction.parse('config()').encode([])))
      return bytesToHex(
        encodeSequence(
          [
            'address',
            'address',
            'address',
            'uint16',
            'uint256',
            'uint256',
          ].map(AbiType.parse).toList(),
          [a, a, a, 100, minimum, parseUnits('1', 18)],
        ),
      );
    if (data.startsWith(
      bytesToHex(AbiFunction.parse('prepaidGas(address)').encode([a]))
          .substring(0, 10),
    ))
      return bytesToHex(encodeSequence([AbiType.parse('uint256')], [credit]));
    if (data ==
        bytesToHex(
          AbiFunction.parse('getSupportedAssetsWithNames()').encode([]),
        ))
      return bytesToHex(
        encodeSequence(
          [AbiType.parse('address[]'), AbiType.parse('string[]')],
          [
            [a, b],
            ['A', 'B'],
          ],
        ),
      );
    if (data == bytesToHex(AbiFunction.parse('MAX_SYMBOL_LENGTH()').encode([])))
      return bytesToHex(encodeSequence([AbiType.parse('uint256')], [16]));
    throw StateError('Unexpected call $to $data');
  }
}

void main() {
  test('23 curated identities and four explicit current Lista modes', () {
    expect(flapCuratedVaults.length, 23);
    expect(
      flapCuratedVaults.map((v) => v.factory.toLowerCase()).toSet().length,
      23,
    );
    for (final v in flapCuratedVaults) {
      expect(isAddress(v.factory), isTrue);
      expect(fixtures.containsKey(v.factory.toLowerCase()), isTrue);
    }
    expect(flapCuratedVaults.first.modes.length, 4);
    expect(flapCuratedSchema(a), isNull);
  });
  test('Split uses exact tuple array with percentages in hundredths', () {
    final selection = buildFlapCuratedSelection(
      info: info(factory('split')),
      rows: [
        {'recipient': a, 'bps': '25.25'},
        {'recipient': b, 'bps': '74.75'},
      ],
    );
    final bytes = selection.encode();
    final value = decode('(address,uint16)[]', bytes).single as List;
    expect(value, [
      [a, BigInt.from(2525)],
      [b, BigInt.from(7475)],
    ]);
    expect(bytesToHex(bytes).substring(2, 66), '20'.padLeft(64, '0'));
    expect(
      () => buildFlapCuratedSelection(
        info: info(factory('split')),
        rows: [
          {'recipient': a, 'bps': '50'},
          {'recipient': a, 'bps': '50'},
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => select(factory('split'), {'recipient': a, 'bps': '99'}),
      throwsFormatException,
    );
  });
  test('Current Omnidrop uses flat uint256,uint256,bytes and packed 20-byte addresses', () {
    final selection = select(factory('omnidrop'), {
      'rewardAssetType': '2',
      'fixedSharePercent': '12.5',
      'fixedAddresses': '$a\n$b',
    });
    final data = selection.encode();
    final decoded = decodeSequence(
      ['uint256', 'uint256', 'bytes'].map(AbiType.parse).toList(),
      data,
      0,
    );
    expect(decoded[0], BigInt.from(2));
    expect(decoded[1], BigInt.from(1250));
    expect(
      bytesToHex(decoded[2] as List<int>),
      '0x${a.substring(2)}${b.substring(2)}',
    );
    expect(bytesToHex(data).substring(130, 194), '60'.padLeft(64, '0'));
    expect(
      () => select(factory('omnidrop'), {
        'rewardAssetType': '0',
        'fixedSharePercent': '51',
        'fixedAddresses': a,
      }),
      throwsFormatException,
    );
    expect(
      () => select(factory('omnidrop'), {
        'rewardAssetType': '0',
        'fixedSharePercent': '0',
        'fixedAddresses': a,
      }),
      throwsFormatException,
    );
    final many = [
      for (var i = 1; i <= 300; i++)
        '0x${i.toRadixString(16).padLeft(40, '0')}',
    ];
    expect(
      select(factory('omnidrop'), {
        'rewardAssetType': '1',
        'fixedSharePercent': '50',
        'fixedAddresses': many.join('\n'),
      }).encode().isNotEmpty,
      isTrue,
    );
  });
  test('Lista native modes encode exact official flat words / tuple[4]', () {
    for (final f in [listaStableFactory, listaLiquidFactory]) {
      final selection = select(f, flapCuratedDefaults(f));
      expect(selection.encode().length, 32);
      expect(
        decode('uint256', selection.encode()).single,
        parseUnits('10000', 18),
      );
    }
    final lock = select(
      listaLockFactory,
      flapCuratedDefaults(listaLockFactory),
    );
    expect(lock.encode().length, 384);
    final tiers =
        decode('(uint16,uint16,uint256)[4]', lock.encode()).single as List;
    expect((tiers[3] as List)[0], BigInt.from(365));
    expect(lock.minimumShare, BigInt.zero);
    final invalid = {
      ...flapCuratedDefaults(listaLockFactory),
      'lockDays2': '0',
      'lockDays3': '180',
    };
    expect(() => select(listaLockFactory, invalid), throwsFormatException);
  });
  test('Lista flex matches three-route flat nested official encoding', () {
    final selection = select(
      listaFlexFactory,
      flapCuratedDefaults(listaFlexFactory),
    );
    final values = decodeSequence(
      [
        'uint256',
        '(address,bytes)[]',
        '(address,uint16,uint8,bytes)[]',
      ].map(AbiType.parse).toList(),
      selection.encode(),
      0,
    );
    expect(values[0], parseUnits('10000', 18));
    expect((values[1] as List).length, 1);
    final routes = values[2] as List;
    expect(routes.length, 3);
    expect((routes[0] as List)[1], BigInt.from(3400));
    expect((routes[2] as List)[2], BigInt.one);
    expect(((routes[2] as List)[3] as List<int>).length, 384);
    expect(
      selection.dividendToken?.toLowerCase(),
      flapComputedDividendToken.toLowerCase(),
    );
    expect(
      () => select(listaFlexFactory, {
        ...flapCuratedDefaults(listaFlexFactory),
        'tokenLockPercent': '32',
      }),
      throwsFormatException,
    );
  });
  test('Gift normalizes account, never uses a URL as an X handle', () {
    final s = select(factory('gift'), {'xHandle': '@EXample_User'});
    expect(s.rows.single['xHandle'], 'example_user');
    expect(s.dividendToken, zero);
    expect(decode('(string)', s.encode()).single, ['example_user']);
    expect(
      () => select(factory('gift'), {'xHandle': 'https://x.com/user'}),
      throwsFormatException,
    );
  });
  test(
    'Index is a flat dynamic encoding; membership checked before execution',
    () async {
      final s = select(factory('IndexVault'), {
        'selectedAssets': '$a\n$b',
        'symbol': 'BASKET',
        'instantDividend': 'true',
      });
      final parsed = decodeSequence(
        ['address[]', 'string', 'bool'].map(AbiType.parse).toList(),
        s.encode(),
        0,
      );
      expect(parsed, [
        [a, b],
        'BASKET',
        true,
      ]);
      final api = ReadBackend();
      await validateFlapCuratedReadiness(api, s, context(s));
      expect(api.reads, 2);
      final bad = select(factory('IndexVault'), {
        'selectedAssets': bncb,
        'symbol': 'BASKET',
        'instantDividend': 'false',
      });
      await expectLater(
        validateFlapCuratedReadiness(api, bad, context(bad)),
        throwsFormatException,
      );
    },
  );
  test(
    'MYX prepayment uses live shortfall, no fee for native or other factories',
    () async {
      final api = ReadBackend();
      expect(
        await flapVaultGasDeficit(
          api,
          factory: flapMyxFactory,
          creator: a,
          quoteToken: bncb,
        ),
        parseUnits('0.015', 18),
      );
      expect(api.reads, 2);
      api.credit = parseUnits('1', 18);
      expect(
        await flapVaultGasDeficit(
          api,
          factory: flapMyxFactory,
          creator: a,
          quoteToken: bncb,
        ),
        BigInt.zero,
      );
      final count = api.reads;
      expect(
        await flapVaultGasDeficit(
          api,
          factory: flapMyxFactory,
          creator: a,
          quoteToken: zero,
        ),
        BigInt.zero,
      );
      expect(api.reads, count);
      api.fail = true;
      await expectLater(
        flapVaultGasDeficit(
          api,
          factory: flapMyxFactory,
          creator: a,
          quoteToken: bncb,
        ),
        throwsStateError,
      );
    },
  );
  test('Curated execution validates allocation and immutable computed dividend settings', () {
    final s = select(listaFlexFactory, flapCuratedDefaults(listaFlexFactory));
    validateFlapCuratedLaunch(s, context(s), quoteSymbol: 'BNB');
    expect(
      () => validateFlapCuratedLaunch(
        s,
        context(s, vault: 9000),
        quoteSymbol: 'BNB',
      ),
      throwsFormatException,
    );
    expect(
      () => validateFlapCuratedLaunch(
        s,
        context(s, dividendToken: zero),
        quoteSymbol: 'BNB',
      ),
      throwsFormatException,
    );
    expect(
      () => validateFlapCuratedLaunch(
        s,
        context(s, minimum: BigInt.zero),
        quoteSymbol: 'BNB',
      ),
      throwsFormatException,
    );
  });
  test(
    'Known adapter rejects changed live schema instead of guessing old bytes',
    () {
      final changed = FlapVaultInfo(
        factory: factory('IndexVault'),
        quoteToken: zero,
        schema: FlapVaultSchema(
          fields: [const FlapVaultField(name: 'x', type: 'bytes')],
        ),
      );
      expect(
        () => buildFlapCuratedSelection(
          info: changed,
          rows: [
            {'x': '0x'},
          ],
        ),
        throwsFormatException,
      );
    },
  );
  test('Domain constraints reject unsupported schedule, rewards, cooldown and precision', () {
    expect(
      () => select(factory('ScheduledBuybackVaultV3'), {
        ...flapCuratedDefaults(factory('ScheduledBuybackVaultV3')),
        'buybackAmount': '0.0011',
      }),
      throwsFormatException,
    );
    expect(
      () => select(factory('GmgnCallOutVault'), {
        ...flapCuratedDefaults(factory('GmgnCallOutVault')),
        'rewardAt50Usd': '6',
      }),
      throwsFormatException,
    );
    expect(
      () => select(factory('Buffett'), {'decisionCooldown': '59'}),
      throwsFormatException,
    );
    expect(
      select(factory('FOMOX'), {
        'claimUsdE18': '2',
        'minTaxBalance': '10000.5',
      }).rows.single['minTaxBalance'],
      '10000',
    );
    expect(
      select(factory('FOMOX'), {
        'claimUsdE18': '0',
        'minTaxBalance': '0',
      }).rows.single,
      {'claimUsdE18': '2', 'minTaxBalance': '10000'},
    );
    expect(
      select(factory('FOMOX'), {
        'claimUsdE18': '99',
        'minTaxBalance': '1',
      }).rows.single,
      {'claimUsdE18': '10', 'minTaxBalance': '10000'},
    );
  });
  test(
    'Every current curated schema has an explicit usable typed configuration',
    () {
      final overrides = <String, Map<String, String>>{
        'gift': {'xHandle': 'example'},
        'flapixelRwaV1': {
          'NFTName': 'Fixture',
          'NFTSymbol': 'NFT',
          'maxNFTSupply': '100',
          'initialFloorNFTs': '10',
          'tokenCostPerNFT': '10000',
          'dividendSharePercent': '50',
          'floorSharePercent': '50',
          'artSource': '0',
        },
        'IndexVault': {
          'selectedAssets': a,
          'symbol': 'IDX',
          'instantDividend': 'false',
        },
        'TokenizedAssetYieldVault': flapCuratedDefaults(
          factory('TokenizedAssetYieldVault'),
        ),
        'MyxPerpetualVault': {
          ...flapCuratedDefaults(flapMyxFactory),
          'minProcessAmount': parseUnits('0.1', 18).toString(),
        },
        'LivingMemeVault': {
          'characterCid': 'bafyfixture',
          'openingPrompt': 'Fixture only',
        },
        'split': {'recipient': a, 'bps': '100'},
        'silent': {'maxUserBnbOutPerSell': '1'},
        'flapixelV2': {
          'NFTName': 'Fixture',
          'NFTSymbol': 'NFT',
          'maxNFTSupply': '100',
          'initialFloorNFTs': '10',
          'tokenCostPerNFT': '10000',
          'dividendSharePercent': '50',
          'floorSharePercent': '50',
          'artSource': '0',
        },
      };
      for (final v in flapCuratedVaults) {
        final row = overrides[v.officialName] ?? v.defaults;
        final s = v.officialName == 'StrategyReserveV2'
            ? buildFlapCuratedSelection(
                info: info(v.factory),
                rows: [
                  {'selectedAsset': a},
                ],
              )
            : select(
                v.factory,
                row,
                quote: v.officialName == 'flapixelRwaV1'
                    ? bncb
                    : v.officialName == 'TokenizedAssetYieldVault'
                    ? '0x02fca66c1d1afb4e2a7884261eb00f63598a7436'
                    : zero,
              );
        expect(() => s.encode(), returnsNormally, reason: v.officialName);
      }
    },
  );
}
