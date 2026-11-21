import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';
import 'package:uxuy_trade/src/exec/flap_vault_adapters.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';

import 'flap_alignment_test.dart' as base;
import 'flap_vault_test.dart' as v;
import 'support/launch_purchase_receipt.dart';

class Api extends base.FlapBackend {
  final vault = v.Backend();
  String factory = v.factory;
  bool wrongCreationAddress = false;
  void Function()? onCodeCheck;
  BigInt prepayment = BigInt.from(1000);
  @override
  Future<GasInfo> gas() async => GasInfo(BigInt.one, 100);
  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    if (to.toLowerCase() == factory.toLowerCase()) {
      final config = AbiFunction.parse(
        'config() returns (address,address,address,uint16,uint256,uint256)',
      );
      final credit = AbiFunction.parse('prepaidGas(address) returns (uint256)');
      if (data == config.encodeHex([]))
        return v.encode(
          ['address', 'address', 'address', 'uint16', 'uint256', 'uint256'],
          [
            base.router,
            base.router,
            base.router,
            100,
            prepayment,
            BigInt.from(1000000),
          ],
        );
      if (data.startsWith(bytesToHex(credit.selector)))
        return v.encode(['uint256'], [BigInt.zero]);
      return vault.call(to, data, block: block);
    }
    if (to.toLowerCase() == flapVaultPortal.toLowerCase() &&
        !data.startsWith(
          bytesToHex(AbiFunction.parse('TOKEN_IMPL_TAXED_V3()').selector),
        )) {
      return vault.call(to, data, block: block);
    }
    if (data.startsWith(
      bytesToHex(
        AbiFunction.parse('getQuoteTokenConfiguration(address)').selector,
      ),
    ))
      return v.encode(
        ['(uint8,uint8,uint8,uint8,uint8)'],
        [
          [1, 1, 1, 1, 1],
        ],
      );
    if (data.startsWith(
      bytesToHex(
        AbiFunction.parse('quoteTokenCreationDisabled(address)').selector,
      ),
    ))
      return v.encode(['bool'], [false]);
    return super.call(to, data, block: block);
  }

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> requested) async {
    final (method, params) = requested.single;
    if (method == 'eth_getCode' &&
        params.first.toString().toLowerCase() ==
            base.implementation.toLowerCase())
      onCodeCheck?.call();
    if (method == 'eth_getCode' &&
        '${params[0]}'.toLowerCase() == factory.toLowerCase())
      return ['0x6000'];
    if (method == 'eth_simulateV1') {
      calls.addAll(requested);
      final calls_ =
          ((params.first as Map)['blockStateCalls'] as List).single['calls']
              as List;
      return [
        [
          {
            'calls': [
              for (final call in calls_)
                {
                  'status': '0x1',
                  'gasUsed': '0x186a0',
                  'logs': [
                    if ('${call['data']}'.startsWith(
                      bytesToHex(flapV6WithVault.selector),
                    ))
                      purchaseTransfer(
                        flapTokenAddress(
                          (flapV6WithVault.decodeInput(call['data']).single
                                  as List)[4]
                              as Uint8List,
                          flapProxyHash(base.implementation),
                        ),
                        call['from'] as String,
                      ),
                  ],
                  'returnData':
                      '${call['data']}'.startsWith(
                        bytesToHex(flapV6WithVault.selector),
                      )
                      ? v.encode(
                          ['address'],
                          [
                            wrongCreationAddress
                                ? base.router
                                : flapTokenAddress(
                                    (flapV6WithVault
                                                .decodeInput(call['data'])
                                                .single
                                            as List)[4]
                                        as Uint8List,
                                    flapProxyHash(base.implementation),
                                  ),
                          ],
                        )
                      : '0x',
                },
            ],
          },
        ],
      ];
    }
    return super.rpc(requested);
  }
}

/// Intercepts the final bundle, never signs or sends. All preflight code is real.
class Runner extends FlapLauncher {
  Runner(BackendClient api) : super(api, ExecutionLog(), random: Random(7));
  List<LaunchTx>? captured;
  @override
  Future<Map<String, int>> checkBalances(
    List<LaunchTx> txs,
    BigInt gasPrice, {
    Map<String, BigInt> extra = const {},
    int reserveGas = 0,
  }) async => {for (final t in txs) t.from.address.toLowerCase(): 0};
  @override
  Future<void> launchBundle(
    List<LaunchTx> txs,
    Map<String, int> nonceMap,
    BigInt gasPrice,
    LaunchSession s,
  ) async {
    captured = txs;
    session = s;
    state = LaunchState.launched;
  }
}

Future<FlapLaunchForm> draft(
  Api api, {
  bool quote = false,
  BigInt? gasBudget,
}) async {
  final q = quote ? v.quote : zeroAddress;
  final info = await FlapVaultService(api).read(api.factory, quoteToken: q);
  return FlapLaunchForm(
    nonTax: false,
    name: 'Synthetic Vault',
    symbol: 'TEST',
    payment: FlapPayment({
      'address': q,
      'symbol': quote ? 'BNCB' : 'BNB',
      'decimals': 18,
      'r': '16.3',
      'h': '107035714',
      'k': '17762499132',
    }),
    buyTaxBps: 300,
    sellTaxBps: 300,
    marketingBps: 10000,
    minimumShare: BigInt.from(12345),
    vault: FlapVaultSelection(
      info: info,
      rows: [
        {'amount': '1.25'},
      ],
    ),
    vaultGasBudget: gasBudget,
    image: LaunchImage([1], 'test.png', 'image/png'),
  );
}

void main() {
  for (final changed in ['schema', 'prepayment']) {
    test(
      '$changed changed during prerequisites is rejected before the final bundle',
      () async {
        final api = Api();
        if (changed == 'prepayment') api.factory = flapMyxFactory;
        final form = await draft(
          api,
          quote: true,
          gasBudget: changed == 'prepayment' ? BigInt.from(1000) : BigInt.zero,
        );
        final runner = Runner(api);
        api.onCodeCheck = () {
          api.onCodeCheck = null;
          if (changed == 'schema') {
            api.vault.currentSchema = FlapVaultSchema(
              fields: const [
                FlapVaultField(name: 'amount', type: 'uint256', decimals: 18),
              ],
            );
          } else {
            api.prepayment = BigInt.from(1001);
          }
        };
        await runner.launch(
          form,
          dev: LaunchBuyer(base.wallet, BigInt.zero),
          internal: [],
          metaOverride: 'bafkrei-test',
        );
        expect(
          runner.error,
          contains(changed == 'schema' ? '格式已更新' : '重新核对并确认金额'),
        );
        expect(runner.captured, isNull);
        expect(api.calls.any((c) => c.$1 == 'eth_simulateV1'), isFalse);
      },
    );
  }
  for (final quote in [false, true]) {
    test(
      'Vault creation targets VaultPortal; ${quote ? 'quote' : 'native'} setting retains tracked minimum without extra payments',
      () async {
        final api = Api(), runnerApi = Api(); // The runner uses the same read snapshot, a fresh service still rechecks.
        final form = await draft(api, quote: quote);
        final runner = Runner(runnerApi);
        await runner.launch(
          form,
          dev: LaunchBuyer(base.wallet, BigInt.zero),
          internal: [],
          metaOverride: 'bafkrei-test',
        );
        expect(runner.error, isNull);
        expect(runner.captured, hasLength(1));
        final create = runner.captured!.first;
        expect(create.to, flapVaultPortal);
        final fields = flapV6WithVault.decodeInput(create.data).single as List;
        expect(
          fields[7],
          BigInt.zero,
        ); // Official creation carries zero purchase amount.
        expect(
          fields[21],
          BigInt.from(12345),
        ); // zero direct dividend still keeps tracker minimum
        expect('${fields[25]}'.toLowerCase(), v.factory.toLowerCase());
        expect(fields[26], form.vault!.encode());
        expect(runner.session!.token.endsWith('7777'), isTrue);
      },
    );
  }
  test('native Flap Vault presale uses the same amount in quoteAmt and payable value', () async {
    final api = Api();
    final runner = Runner(api);
    final form = await draft(api, quote: false);
    final amount = parseUnits('0.125', 18);
    await runner.launch(
      form,
      dev: LaunchBuyer(base.wallet, amount),
      metaOverride: 'bafkrei-test',
    );
    expect(runner.error, isNull);
    final create = runner.captured!.single;
    final fields = flapV6WithVault.decodeInput(create.data).single as List;
    expect(fields[7], amount);
    expect(create.value, amount);
    expect(create.simulatedDelivery, BigInt.from(1234));
  });
  for (final failure in ['schema', 'hook', 'wrongAddress']) {
    test('$failure failure stops before final signing/submission', () async {
      final api = Api();
      final form = await draft(api);
      final runner = Runner(api);
      if (failure == 'schema') api.vault.rawSchema = '0x';
      if (failure == 'hook') api.vault.hook = false;
      if (failure == 'wrongAddress') api.wrongCreationAddress = true;
      await runner.launch(
        form,
        dev: LaunchBuyer(base.wallet, BigInt.zero),
        internal: [],
        metaOverride: 'bafkrei-test',
      );
      expect(runner.error, isNotNull);
      expect(runner.captured, isNull);
      expect(runner.session, isNull);
      if (failure != 'wrongAddress')
        expect(api.calls.any((c) => c.$1 == 'eth_simulateV1'), isFalse);
    });
  }
  test('MYX prepayment may not exceed the confirmed budget', () async {
    final api = Api()..factory = flapMyxFactory;
    final form = await draft(api, quote: true, gasBudget: BigInt.from(999));
    final runner = Runner(api);
    await runner.launch(
      form,
      dev: LaunchBuyer(base.wallet, BigInt.zero),
      internal: [],
      metaOverride: 'bafkrei-test',
    );
    expect(runner.error, contains('重新核对并确认金额'));
    expect(runner.captured, isNull);
  });
  test('confirmed MYX prepayment is included before creation in the same simulation and bundle', () async {
    final api = Api()..factory = flapMyxFactory;
    final form = await draft(api, quote: true, gasBudget: BigInt.from(1000));
    final runner = Runner(api);
    await runner.launch(
      form,
      dev: LaunchBuyer(base.wallet, BigInt.zero),
      internal: [],
      metaOverride: 'bafkrei-test',
    );
    expect(runner.error, isNull);
    expect(runner.captured, hasLength(2));
    expect(runner.captured![0].kind, 'vaultPrepayment');
    expect(runner.captured![0].value, BigInt.from(1000));
    expect(runner.captured![1].kind, 'create');
    final simulated =
        (((api.calls.singleWhere((c) => c.$1 == 'eth_simulateV1').$2.first
                            as Map)['blockStateCalls']
                        as List)
                    .single
                as Map)['calls']
            as List;
    expect(simulated, hasLength(2));
    expect(
      simulated[0]['to'].toString().toLowerCase(),
      flapMyxFactory.toLowerCase(),
    );
    expect(
      simulated[1]['to'].toString().toLowerCase(),
      flapVaultPortal.toLowerCase(),
    );
  });
}
