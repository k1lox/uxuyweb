import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart' show FakeBackend;

import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

const implementation = '0x00000000000000000000000000000000000A0011';
const router = '0x00000000000000000000000000000000000C0011';
final wallet = TradeWallet.import('synthetic', '0x${'1'.padLeft(64, '0')}');

FlapPayment payment([Object? decimals = 18]) => FlapPayment({
  'address': zeroAddress,
  'symbol': 'BNB',
  'decimals': decimals,
  'r': '16.3',
  'h': '107035714',
  'k': '17762499132',
});

FlapLaunchForm form({
  bool nonTax = false,
  int marketing = 10000,
  int burn = 0,
  int dividend = 0,
  int liquidity = 0,
  int buyTax = 300,
  int sellTax = 300,
  String? beneficiary,
  int antiFarmerDays = 30,
  List<int> image = const [1],
  FlapPayment? quote,
  bool payWithBnb = false,
  BigInt? tip,
}) => FlapLaunchForm(
  nonTax: nonTax,
  name: 'Synthetic',
  symbol: 'TEST',
  payment: quote ?? payment(),
  payWithBnb: payWithBnb,
  tip: tip,
  buyTaxBps: buyTax,
  sellTaxBps: sellTax,
  marketingBps: marketing,
  burnBps: burn,
  dividendBps: dividend,
  liquidityBps: liquidity,
  beneficiary: beneficiary,
  antiFarmerDays: antiFarmerDays,
  minimumShare: flapMinDividendShare,
  image: LaunchImage(image, 'test.png', 'image/png'),
);

String encoded(List<String> types, List<Object> values) =>
    bytesToHex(encodeSequence(types.map(AbiType.parse).toList(), values));

class FlapBackend extends BackendClient {
  FlapBackend({
    this.implAddress = implementation,
    this.implCode = '0x6000',
    this.quoteAddress = zeroAddress,
    this.portalConverts = true,
  })
    : super(Uri.parse('http://fixture.invalid/'), FakeBackend().client());
  String implAddress;
  Object? implCode;
  final String quoteAddress;
  final bool portalConverts;
  bool failImplementationRead = false;
  Object? simulation;
  Object? simulationError;
  final calls = <(String, List<Object?>)>[];
  final implementationReads = <String>[];

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> requested) async {
    calls.addAll(requested);
    final results = <Object?>[];
    for (final (method, params) in requested) {
      if (method == 'eth_simulateV1') {
        if (simulationError != null) throw simulationError!;
        results.add(simulation);
      } else if (method == 'eth_getCode') {
        results.add(
          '${params.first}'.toLowerCase() == implAddress.toLowerCase()
              ? implCode
              : '0x',
        );
      } else if (method == 'eth_call') {
        final input = params.first! as Map;
        final data = input['data'];
        final tax = AbiFunction.parse(
          'TOKEN_IMPL_TAXED_V3() returns (address)',
        );
        final nonTax = AbiFunction.parse('TOKEN_IMPL_V3() returns (address)');
        if (data == bytesToHex(tax.encode([])) ||
            data == bytesToHex(nonTax.encode([]))) {
          expect('${input['to']}'.toLowerCase(), flapVaultPortal.toLowerCase());
          implementationReads.add(
            data == bytesToHex(tax.encode([])) ? 'tax' : 'nonTax',
          );
          if (failImplementationRead)
            throw BackendException('RPC', 'offline', true);
          results.add(encoded(['address'], [implAddress]));
        } else if (data ==
            bytesToHex(AbiFunction.parse('getFeeRate()').encode([]))) {
          results.add(
            encoded(
              ['uint256', 'uint256'],
              [BigInt.from(100), BigInt.from(100)],
            ),
          );
        } else if (data ==
            bytesToHex(
              AbiFunction.parse('getQuoteTokenConfiguration(address)')
                  .encode([quoteAddress]),
            )) {
          results.add(
            encoded(
              ['(uint8,uint8,uint8,uint8,uint8)'],
              [
                [1, 1, 1, portalConverts ? 1 : 0, 1],
              ],
            ),
          );
        } else if (data ==
            bytesToHex(
              AbiFunction.parse('quoteTokenCreationDisabled(address)')
                  .encode([quoteAddress]),
            )) {
          results.add(encoded(['bool'], [false]));
        } else {
          throw StateError('Unexpected eth_call');
        }
      } else {
        throw StateError('Unexpected RPC method $method');
      }
    }
    return results;
  }
}

List<LaunchTx> transactions() => [
  LaunchTx(
    'create',
    wallet,
    flapPortal,
    Uint8List(0),
    BigInt.zero,
    8000000,
    kind: 'create',
  ),
  LaunchTx('buy', wallet, router, Uint8List(0), BigInt.one, 3000000),
];

void main() {
  group('Flap payment precision', () {
    test('unknown, fractional and out-of-range precision cannot become an available payment', () {
      for (final value in [
        null,
        -1,
        1.25,
        37,
        '18',
        double.nan,
        double.infinity,
      ]) {
        final row = payment(value);
        expect(row.available, isFalse, reason: '$value');
        expect(row.decimals, -1);
        expect(() => form(quote: row).validate(), throwsStateError);
      }
      expect(FlapPayment.custom(implementation, 'SIX', -1).available, isFalse);
      expect(FlapPayment.custom(implementation, 'SIX', 37).available, isFalse);
    });
    test('known precision is preserved, including six and zero decimals', () {
      for (final value in [0, 6, 18, 18.0, 36]) {
        final row = payment(value);
        expect(row.available, isTrue);
        expect(row.decimals, value.toInt());
      }
    });
  });

  group('Flap launch input boundaries', () {
    test(
      'a tax side may be zero or 1 to 10 percent, but both cannot be zero',
      () {
        for (final rates in [(0, 100), (100, 0), (100, 100), (1000, 1000)]) {
          expect(
            () => form(buyTax: rates.$1, sellTax: rates.$2).validate(),
            returnsNormally,
          );
        }
        for (final rates in [(0, 0), (50, 100), (1001, 100), (-1, 100)]) {
          expect(
            () => form(buyTax: rates.$1, sellTax: rates.$2).validate(),
            throwsFormatException,
          );
        }
      },
    );
    test('beneficiary and protection period match launch constraints', () {
      expect(() => form(beneficiary: '').validate(), returnsNormally);
      expect(
        () => form(beneficiary: implementation).validate(),
        returnsNormally,
      );
      expect(
        () => form(beneficiary: zeroAddress).validate(),
        throwsFormatException,
      );
      expect(
        () => form(beneficiary: 'invalid').validate(),
        throwsFormatException,
      );
      expect(form().antiFarmerDays, 30);
      for (final nonTax in [false, true]) {
        expect(
          () => form(nonTax: nonTax, antiFarmerDays: 0).validate(),
          returnsNormally,
        );
        expect(
          () => form(nonTax: nonTax, antiFarmerDays: 365).validate(),
          returnsNormally,
        );
        expect(
          () => form(nonTax: nonTax, antiFarmerDays: -1).validate(),
          throwsFormatException,
        );
        expect(
          () => form(nonTax: nonTax, antiFarmerDays: 366).validate(),
          throwsFormatException,
        );
      }
    });
    test(
      'negative allocation cannot cancel an allocation over 100 percent',
      () {
        expect(
          () => form(marketing: 10100, burn: -100).validate(),
          throwsFormatException,
        );
        expect(
          () => form(marketing: 9900, liquidity: 100).validate(),
          returnsNormally,
        );
        expect(() => form(marketing: 9900).validate(), throwsFormatException);
      },
    );
    test('ten decimal MB is the image size boundary for both token types', () {
      for (final nonTax in [false, true]) {
        expect(
          () => form(nonTax: nonTax, image: Uint8List(10_000_000)).validate(),
          returnsNormally,
        );
        expect(
          () =>
              form(nonTax: nonTax, image: Uint8List(10_000_000 + 1)).validate(),
          throwsFormatException,
        );
      }
    });
  });

  test('Flap rejects 104 creation and funding calls before metadata, signing or approvals', () async {
    final api = FlapBackend(quoteAddress: router, portalConverts: false);
    final runner = FlapLauncher(api, ExecutionLog());
    await runner.launch(
      form(
        quote: FlapPayment({'address': router, 'symbol': 'USD', 'decimals': 18}),
        payWithBnb: true,
        tip: BigInt.one,
      ),
      dev: LaunchBuyer(wallet, BigInt.one),
      internal: [
        for (var i = 2; i <= 51; i++)
          LaunchBuyer(TradeWallet.import('test $i', i.toRadixString(16).padLeft(64, '0')), BigInt.one),
      ],
    );
    expect(runner.error, contains('共 104 笔，超过单个捆绑上限 103'));
    expect(api.calls.map((call) => call.$1), ['eth_call', 'eth_call']);
    expect(runner.transactions, isEmpty);
    runner.dispose();
    api.http_.close();
  });

  test('Flap rejects overlap between Dev and the inner group before reading chains or uploading metadata', () async {
    final api = FlapBackend();
    final runner = FlapLauncher(api, ExecutionLog());
    await runner.launch(
      form(),
      dev: LaunchBuyer(wallet, BigInt.zero),
      internal: [LaunchBuyer(wallet, BigInt.one)],
    );
    expect(runner.error, contains('不能重复'));
    expect(api.implementationReads, isEmpty);
    expect(api.calls, isEmpty);
    expect(runner.transactions, isEmpty);
    runner.dispose();
    api.http_.close();
  });

  group('Flap implementation address is read from the live portal', () {
    for (final nonTax in [false, true]) {
      for (final failure in ['read', 'zero', 'noCode', 'malformedCode']) {
        test(
          '${nonTax ? 'V7' : 'V6'} fails closed on $failure without using a hardcoded implementation',
          () async {
            final api = FlapBackend();
            api.failImplementationRead = failure == 'read';
            if (failure == 'zero') api.implAddress = zeroAddress;
            if (failure == 'noCode') api.implCode = '0x';
            if (failure == 'malformedCode') api.implCode = 'unexpected';
            final runner = FlapLauncher(api, ExecutionLog(), random: Random(1));
            await runner.launch(
              form(nonTax: nonTax),
              dev: LaunchBuyer(wallet, BigInt.zero),
              internal: [],
              metaOverride: 'bafkrei-test',
            );
            expect(api.implementationReads, [nonTax ? 'nonTax' : 'tax']);
            expect(runner.error, contains('当前代币实现读取失败'));
            expect(runner.transactions, isEmpty);
            expect(runner.session, isNull);
            expect(api.calls.any((c) => c.$1 == 'eth_simulateV1'), isFalse);
            runner.dispose();
            api.http_.close();
          },
        );
      }
    }
    test('a valid newly read implementation is used and unavailable simulation stops the main launch', () async {
      final api = FlapBackend()
        ..simulationError = BackendException(
          'RPC',
          'method unavailable',
          false,
        );
      final runner = FlapLauncher(api, ExecutionLog(), random: Random(7));
      await runner.launch(
        form(),
        dev: LaunchBuyer(wallet, BigInt.zero),
        internal: [],
        metaOverride: 'bafkrei-test',
      );
      expect(api.implementationReads, ['tax']);
      expect(api.calls.any((c) => c.$1 == 'eth_simulateV1'), isTrue);
      final request =
          api.calls.singleWhere((c) => c.$1 == 'eth_simulateV1').$2.first!
              as Map;
      final creation =
          ((request['blockStateCalls'] as List).single as Map)['calls'] as List;
      final call = AbiFunction.parse(
        'newTokenV6((string,string,string,uint8,bytes32,uint8,address,uint256,address,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8))',
      );
      final fields =
          call.decodeInput((creation.first as Map)['data']).single! as List;
      expect(
        fields[8],
        wallet.address,
        reason: 'blank beneficiary uses the creator',
      );
      expect(fields[17], BigInt.from(30 * 86400));
      expect(
        flapTokenAddress(
          fields[4] as Uint8List,
          flapProxyHash(implementation),
        ).endsWith('7777'),
        isTrue,
      );
      expect(runner.error, contains('已停止发币准备'));
      expect(runner.transactions, isEmpty);
      expect(runner.session, isNull);
      runner.dispose();
      api.http_.close();
    });
    for (final nonTax in [false, true]) {
      test(
        '${nonTax ? 'V7' : 'V6'} encodes protection period without shifting fee fields',
        () async {
          final api = FlapBackend()
            ..simulationError = BackendException(
              'RPC',
              'simulation unavailable',
              false,
            );
          final runner = FlapLauncher(api, ExecutionLog(), random: Random(7));
          await runner.launch(
            form(nonTax: nonTax, beneficiary: router, antiFarmerDays: 365),
            dev: LaunchBuyer(wallet, BigInt.zero),
            internal: [],
            metaOverride: 'bafkrei-test',
          );
          final request =
              api.calls.singleWhere((c) => c.$1 == 'eth_simulateV1').$2.first!
                  as Map;
          final creation =
              ((request['blockStateCalls'] as List).single as Map)['calls']
                  as List;
          expect(creation, hasLength(1));
          expect(creation.single['from'], wallet.address);
          final call = AbiFunction.parse(
            nonTax
                ? 'newTokenV7((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint16,uint16,uint64,uint64,address,uint8,(uint8,uint16,address,address,uint256)[4]))'
                : 'newTokenV6((string,string,string,uint8,bytes32,uint8,address,uint256,address,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8))',
          );
          final fields =
              call.decodeInput((creation.first as Map)['data']).single! as List;
          expect(fields[nonTax ? 15 : 17], BigInt.from(365 * 86400));
          expect(
            fields[7],
            BigInt.zero,
            reason: 'creator purchase remains a separate fee-router call',
          );
          expect(fields[nonTax ? 17 : 25], BigInt.from(nonTax ? 7 : 6));
          if (nonTax) {
            expect(
              fields[14],
              BigInt.zero,
              reason: 'non-tax tax duration stays zero',
            );
            final fees = fields[18] as List;
            expect((fees.first as List)[1], BigInt.from(10000));
          } else {
            expect('${fields[8]}'.toLowerCase(), router.toLowerCase());
            expect(fields[16], flapTaxDuration);
          }
          expect(
            flapTokenAddress(
              fields[4] as Uint8List,
              flapProxyHash(implementation),
            ).endsWith(nonTax ? '8888' : '7777'),
            isTrue,
          );
          expect(runner.error, contains('已停止发币准备'));
          expect(runner.transactions, isEmpty);
          runner.dispose();
          api.http_.close();
        },
      );
    }
  });

  group('required ordered simulation', () {
    for (final failure in ['rpc', 'timeout', 'shape', 'missing', 'revert']) {
      test(
        'rejects $failure instead of continuing with gas ceilings',
        () async {
          final api = FlapBackend();
          switch (failure) {
            case 'rpc':
              api.simulationError = BackendException(
                'RPC',
                'method unavailable',
                false,
              );
            case 'timeout':
              api.simulationError = TimeoutException('timeout');
            case 'shape':
              api.simulation = {'calls': []};
            case 'missing':
              api.simulation = [
                {
                  'calls': [
                    {'status': '0x1', 'gasUsed': '0x5208'},
                  ],
                },
              ];
            case 'revert':
              api.simulation = [
                {
                  'calls': [
                    {'status': '0x1', 'gasUsed': '0x5208'},
                    {
                      'status': '0x0',
                      'error': {'message': 'factory changed'},
                    },
                  ],
                },
              ];
          }
          final runner = FlapLauncher(api, ExecutionLog());
          await expectLater(
            runner.simulateBundle(transactions(), requireSuccess: true),
            throwsStateError,
          );
          expect(api.calls.length, 1);
          runner.dispose();
          api.http_.close();
        },
      );
    }
    test(
      'a complete successful response updates gas from observed usage',
      () async {
        final api = FlapBackend()
          ..simulation = [
            {
              'calls': [
                {'status': '0x1', 'gasUsed': '0x186a0'},
                {'status': '0x1', 'gasUsed': '0x30d40'},
              ],
            },
          ];
        final runner = FlapLauncher(api, ExecutionLog());
        final txs = transactions();
        await runner.simulateBundle(txs, requireSuccess: true);
        expect(txs.map((e) => e.gasLimit), [200000, 400000]);
        runner.dispose();
        api.http_.close();
      },
    );
    for (final failure in [
      const BackendException(
        'RPC_ERROR',
        'execution reverted: token not supported',
        false,
      ),
      const BackendException('BAD_RESPONSE', '节点返回的批量数据不完整', true),
    ]) {
      test(
        'a failed simulation cannot fall back to signing: ${failure.code}',
        () async {
          final api = FlapBackend()..simulationError = failure;
          final runner = FourLauncher(api, ExecutionLog());
          await expectLater(
            runner.simulateBundle(transactions()),
            throwsStateError,
          );
          runner.dispose();
          api.http_.close();
        },
      );
    }
    test(
      'other launchers retain the previous optional-simulation behavior',
      () async {
        final api = FlapBackend()
          ..simulationError = BackendException(
            'RPC',
            'method unavailable',
            false,
          );
        final runner = FourLauncher(api, ExecutionLog());
        final txs = transactions();
        await runner.simulateBundle(txs);
        expect(txs.map((e) => e.gasLimit), [8000000, 3000000]);
        runner.dispose();
        api.http_.close();
      },
    );
  });
}
