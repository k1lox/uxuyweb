import 'dart:convert';

import 'support/launch_purchase_receipt.dart';

import 'package:uxuy_trade/src/crypto/keccak.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

TradeWallet key(int i) => TradeWallet.import(
  'K$i',
  '0x${(i + 500).toRadixString(16).padLeft(64, '0')}',
);
const token = '0x1111111111111111111111111111111111114444';

/// Four.meme launch against a scripted backend (the official API is not reachable from the test machine).
void main() {
  final bnbRaised = {
    'status': 'PUBLISH',
    'symbol': 'BNB',
    'nativeSymbol': 'BNB',
    'symbolAddress': wbnb,
    'totalBAmount': '18',
    'totalAmount': 1000000000,
    'saleRate': 0.8,
  };
  late List<List<String>> bundles;
  late List<Map<String, dynamic>> fourCalls;
  late List<dynamic> simulated;
  final indexes = <String, int>{};

  final usd = {
    ...bnbRaised,
    'nativeSymbol': 'USDX',
    'symbol': 'USDX',
    'symbolAddress': '0x0000000000000000000000000000000000000101',
  };
  int? expectedGraduation;
  int walletStateReads = 0;
  List<Map<String, dynamic>> logs(int index) {
    final leg = simulated[index] as Map;
    final owner = leg['from'] as String;
    String word(String a) => a.substring(2).toLowerCase().padLeft(64, '0');
    return [
      if (index == 0)
        {
          'address': fourManager,
          'topics': [
            '0x396d5e902b675b032348d3d2e9517ee8f0c4a926603fbc075d3d282ff00cad20',
          ],
          'data': '0x${word(owner)}${word(token)}',
        },
      if (leg['data'] != '0x') purchaseTransfer(token, owner),
      if (index == expectedGraduation)
        {
          'address': fourManager,
          'topics': [
            bytesToHex(
              keccak256(
                'LiquidityAdded(address,uint256,address,uint256)'.codeUnits,
              ),
            ),
          ],
          'data':
              '0x${word(token)}${'1'.padLeft(64, '0')}${word(zeroAddress)}${'2'.padLeft(64, '0')}',
        },
    ];
  }

  BackendClient backend({
    Map<String, Object>? pool,
    bool simulationSupported = true,
  }) => BackendClient(
    Uri.parse('http://backend.test/'),
    MockClient((req) async {
      final path = req.url.path;
      Object res;
      if (path == '/api/fourmeme') {
        if (req.headers['content-type']?.startsWith('multipart/form-data') ??
            false) {
          res = {
            'ok': true,
            'payload': {'code': 0, 'data': 'https://static.four.meme/img.png'},
          };
        } else {
          final b = jsonDecode(req.body) as Map<String, dynamic>;
          fourCalls.add(b);
          res = {
            'ok': true,
            'payload': switch (b['action']) {
              'config' => {
                'code': 0,
                'data': [pool ?? bnbRaised],
              },
              'nonce' => {'code': 0, 'data': '42'},
              'login' => {'code': 0, 'data': 'access-token'},
              'create' => {
                'code': 0,
                'data': {'createArg': '0x1234', 'signature': '0xabcd'},
              },
              'predictTokenAddress' => {'tokenAddress': token},
              _ => {'code': 1, 'msg': 'unexpected'},
            },
          };
        }
      } else if (path == '/api/v1/rpc/bsc') {
        final batch = jsonDecode(req.body) as List;
        for (final c in batch.where((c) => c['method'] == 'eth_simulateV1')) {
          simulated = c['params'][0]['blockStateCalls'][0]['calls'] as List;
        }
        res = [
          for (final c in batch)
            {
              'jsonrpc': '2.0',
              'id': (c as Map)['id'],
              if (c['method'] == 'eth_simulateV1') ...{
                if (!simulationSupported)
                  'error': {'code': -32601, 'message': 'Method not found'}
                else
                  'result': [
                    {
                      'calls': [
                        for (var i = 0; i < simulated.length; i++)
                          {
                            'status': '0x1',
                            'gasUsed': '0x186a0',
                            'logs': logs(i),
                          },
                      ],
                    },
                  ],
              } else
                'result': c['method'] == 'eth_getCode'
                    ? '0x'
                    : c['params'][0]['data'] ==
                          AbiFunction.parse('_tradingFeeRate()').encodeHex([])
                    ? '0x${'64'.padLeft(64, '0')}'
                    : bytesToHex(
                        encodeSequence(
                          [AbiType.parse('uint256')],
                          [parseUnits('0.005', 18)],
                        ),
                      ),
            },
        ];
        return http.Response(jsonEncode(res), 200);
      } else if (path == '/api/v1/gas') {
        res = {'ok': true, 'gasPrice': '1000000000', 'blockNumber': 100};
      } else if (path.startsWith('/api/v1/tokens/')) {
        res = {'ok': true, 'token': {'token': usd['symbolAddress'], 'symbol': 'USDX', 'name':'USDX', 'decimals': 6}};
      } else if (path == '/api/v1/wallets/state') {
        walletStateReads++;
        res = {
          'ok': true,
          'wallets': [
            for (final w in (jsonDecode(req.body) as Map)['wallets'] as List)
              {'wallet': w, 'native': '${parseUnits('100', 18)}', 'nonce': 3,
                'tokenBalance': w.toString().toLowerCase() == key(2).address.toLowerCase() ? '0' : '1000000', 'routerAllowance': '0'},
          ],
        };
      } else if (path == '/api/v1/bundles') {
        bundles.add([
          for (final r in (jsonDecode(req.body) as Map)['transactions'] as List)
            '$r',
        ]);
        for (var i = 0; i < bundles.last.length; i++) {
          indexes[bytesToHex(keccak256(hexToBytes(bundles.last[i])))] = i;
        }
        res = {
          'ok': true,
          'result': {'bundleHash': '0x${'ab' * 32}'},
        };
      } else if (path.startsWith('/api/v1/transactions/bsc/')) {
        res = {
          'ok': true,
          'result': {
            'transactionHash': path.split('/').last,
            'status': 'confirmed',
            'receipt': launchReceipt(
              path.split('/').last,
              indexes[path.split('/').last]!,
              logs(indexes[path.split('/').last]!),
            ),
          },
        };
      } else {
        res = {'ok': false, 'code': 'X', 'message': path};
      }
      return http.Response(
        jsonEncode(res),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  setUp(() {
    expectedGraduation = null;
    walletStateReads = 0;
    bundles = [];
    fourCalls = [];
    simulated = [];
  });

  FourLaunchForm form({bool external = false, bool payWithBnb = false, FourTax? tax, Map<String, Object>? pool}) => FourLaunchForm(
    name: 'UXUY',
    shortName: 'UX',
    desc: 'test',
    raised: FourRaised(pool ?? bnbRaised),
    external: external,
    payWithBnb: payWithBnb,
    tax: tax,
    image: const LaunchImage([1, 2, 3], 'a.png', 'image/png'),
    tip: parseUnits('0.001', 18),
  );

  test('Four counts wallet-specific BNB conversions and the separate Dev buy before login or approval', () async {
    final launcher = FourLauncher(backend(pool: usd), ExecutionLog());
    await launcher.launch(
      form(pool: usd, payWithBnb: true),
      dev: LaunchBuyer(key(1), BigInt.one),
      internal: [
        for (var i = 2; i <= 51; i++) LaunchBuyer(key(i), BigInt.one),
      ],
    );
    expect(launcher.error, contains('共 104 笔，超过单个捆绑上限 103'));
    expect(fourCalls.map((row) => row['action']), ['config']);
    expect(walletStateReads, 0);
    expect(simulated, isEmpty);
    expect(bundles, isEmpty);
  });

  test('Four creation signs its login, attaches the official factory fee and sends only the requested tip', () async {
    final dev = key(1);
    final launcher = FourLauncher(
      backend(),
      ExecutionLog(),
      sleep: (_) async {},
    );
    await launcher.launch(form(), dev: LaunchBuyer(dev, BigInt.zero));
    expect(launcher.error, isNull);
    expect(launcher.state, LaunchState.launched);
    final login = fourCalls.firstWhere((c) => c['action'] == 'login');
    expect(
      login['payload']['verifyInfo']['signature'],
      dev.signMessage('You are sign in Meme 42'),
    );
    final create = fourCalls.firstWhere((c) => c['action'] == 'create');
    expect(create['payload']['preSale'], '0');
    expect(launcher.transactions.map((t) => (t.to, t.value)), [
      (fourManager, parseUnits('0.005', 18)),
      (bscBundleTipRecipient, parseUnits('0.001', 18)),
    ]);
    expect(simulated, hasLength(2));
    expect(bundles.single, hasLength(2));
  });

  test('Four atomic native presale binds API amount, prediction value and verified Dev delivery', () async {
    final runner = FourLauncher(backend(), ExecutionLog());
    await runner.launch(
      form(),
      dev: LaunchBuyer(key(1), parseUnits('0.1', 18)),
    );
    expect(runner.error, isNull);
    expect(runner.state, LaunchState.launched);
    final create = fourCalls.singleWhere((row) => row['action'] == 'create');
    expect(create['payload']['preSale'], '0.09900990099009901');
    expect(runner.transactions.first.value, parseUnits('0.105', 18));
    expect(runner.transactions.first.purchasedToken?.toLowerCase(), token);
    expect(bundles, hasLength(1));
  });

  test('Four internal group signs ordered official buys with measured minimums and includes all holders', () async {
    final launcher = FourLauncher(backend(), ExecutionLog());
    await launcher.launch(
      form(),
      dev: LaunchBuyer(key(1), BigInt.zero),
      internal: [
        for (final i in [2, 3]) LaunchBuyer(key(i), parseUnits('0.1', 18)),
      ],
    );
    expect(launcher.error, isNull);
    expect(launcher.state, LaunchState.launched);
    expect(launcher.transactions.map((t) => t.kind), [
      'create',
      'inner',
      'inner',
      'tip',
    ]);
    expect(launcher.session!.wallets.map((w) => w.address), [
      key(1).address,
      key(2).address,
      key(3).address,
    ]);
    for (final i in [1, 2]) {
      final tx = launcher.transactions[i];
      final args = AbiFunction.parse(
        'buyTokenAMAP(address,address,uint256,uint256)',
      ).decodeInput(tx.data);
      expect(tx.to, fourManager);
      expect((args[0] as String).toLowerCase(), token);
      expect(args[1], key(i + 1).address);
      expect(args[2], parseUnits('0.1', 18));
      expect(args[3], BigInt.from(1228));
    }
  });
  for (final valid in [false, true]) {
    test(
      'classic tax migration checks the last inner phase proof before signing external, valid=$valid',
      () async {
        expectedGraduation = valid ? 1 : null;
        final launcher = FourLauncher(backend(), ExecutionLog());
        await launcher.launch(
          form(
            external: true,
            tax: const FourTax(
              feeRate: 3,
              feeRateSell: 3,
              burn: 100,
              divide: 0,
              liquidity: 0,
              recipient: 0,
            ),
          ),
          dev: LaunchBuyer(key(1), BigInt.zero),
          internal: [LaunchBuyer(key(2), parseUnits('20', 18))],
          external: [LaunchBuyer(key(3), parseUnits('0.1', 18))],
        );
        if (!valid) {
          expect(launcher.error, contains('毕业事件'));
          expect(bundles, isEmpty);
          return;
        }
        expect(launcher.error, isNull);
        expect(launcher.state, LaunchState.launched);
        final tx = launcher.transactions[2];
        expect(tx.to, fourPancakeRouter);
        final args = AbiFunction.parse(
          'swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)',
        ).decodeInput(tx.data);
        expect(args[0], BigInt.from(1228));
        expect((args[1] as List).last.toString().toLowerCase(), token);
        expect(args[2], key(3).address);
      },
    );
  }
  test('ordinary tokens cannot migrate inside the bundle; tax splits must sum to 100', () async {
    final launcher = FourLauncher(
      backend(),
      ExecutionLog(),
      sleep: (_) async {},
    );
    await launcher.launch(
      form(external: true),
      dev: LaunchBuyer(key(1), BigInt.zero),
      internal: [LaunchBuyer(key(2), BigInt.one)],
      external: [LaunchBuyer(key(3), BigInt.one)],
    );
    expect(launcher.error, contains('需要税币'));
    expect(
      () => const FourTax(
        feeRate: 3,
        feeRateSell: 3,
        burn: 50,
        divide: 20,
        liquidity: 20,
        recipient: 0,
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => const FourTax(
        feeRate: 2,
        feeRateSell: 3,
        burn: 100,
        divide: 0,
        liquidity: 0,
        recipient: 0,
      ).validate(),
      throwsFormatException,
    );
    expect(bundles, isEmpty);
  });

  test('an unsupported node cannot send the Four launch package', () async {
    final launcher = FourLauncher(
      backend(simulationSupported: false),
      ExecutionLog(),
    );
    await launcher.launch(form(), dev: LaunchBuyer(key(1), BigInt.zero));
    expect(launcher.error, contains('连续模拟不可用'));
    expect(bundles, isEmpty);
  });

  test(
    'a selected pool that is no longer available stops before login',
    () async {
      final launcher = FourLauncher(backend(pool: usd), ExecutionLog());
      await launcher.launch(form(), dev: LaunchBuyer(key(1), BigInt.zero));
      expect(launcher.error, contains('底池代币已变更'));
      expect(fourCalls.map((c) => c['action']), ['config']);
      expect(bundles, isEmpty);
    },
  );
  test('Four rejects a direct Dev quote purchase that would graduate before touching allowances', () async {
    final launcher = FourLauncher(backend(pool: usd), ExecutionLog());
    await launcher.launch(form(pool: usd), dev: LaunchBuyer(key(1), parseUnits('19', 6)));
    expect(launcher.error, contains('已达到迁移目标'));
    expect(walletStateReads, 0);
    expect(fourCalls.map((c) => c['action']), ['config']);
    expect(bundles, isEmpty);
  });
  test('Four rejects missing buyer funds before Dev approval or prediction', () async {
    final launcher = FourLauncher(backend(pool: usd), ExecutionLog());
    await launcher.launch(form(pool: usd), dev: LaunchBuyer(key(1), parseUnits('1', 6)),
        internal: [LaunchBuyer(key(2), parseUnits('0.1', 6))]);
    expect(launcher.error, contains('底池币余额不足'));
    expect(walletStateReads, 1);
    expect(fourCalls.map((c) => c['action']), contains('create'));
    expect(fourCalls.map((c) => c['action']), isNot(contains('predictTokenAddress')));
    expect(bundles, isEmpty);
  });
  test('bonding validation', () {
    final t = BigInt.from(100), c = BigInt.from(101);
    expect(
      () => validateFourBonding(
        external: false,
        dev: BigInt.from(50),
        internal: [BigInt.from(50)],
        target: t,
        crossing: c,
      ),
      throwsStateError,
    );
    validateFourBonding(
      external: false,
      dev: BigInt.from(10),
      internal: [BigInt.from(50)],
      target: t,
      crossing: c,
    );
    expect(
      () => validateFourBonding(
        external: true,
        dev: BigInt.zero,
        internal: [BigInt.from(100), BigInt.from(5)],
        target: t,
        crossing: c,
      ),
      throwsStateError,
    );
    validateFourBonding(
      external: true,
      dev: BigInt.zero,
      internal: [BigInt.from(10), BigInt.from(95)],
      target: t,
      crossing: c,
    );
  });
}
