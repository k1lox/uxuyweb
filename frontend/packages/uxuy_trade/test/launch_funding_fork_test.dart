@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/launch_fork_node.dart';

/// No private key exists in this fixture. The historical Four login and
/// signature response are played back offline; transaction signing is disabled.
class _ObservedWallet extends Fake implements TradeWallet {
  _ObservedWallet(this.address);
  @override
  final String address;
  @override
  String signMessage(String message) => 'offline-fixture';
}

class _Contracts extends LaunchForkNode {
  _Contracts(super.endpoint, this.fixture);
  final Map fixture;
  List get records => fixture['wallets'] as List;
  @override
  Future<ModuleConfig> config() async => ModuleConfig(
    router: (fixture['orderedTransactions'] as List)[1]['to'] as String,
    approvalSpender:
        (fixture['orderedTransactions'] as List)[1]['to'] as String,
    maxImpact: 20,
    routeEnabled: true,
  );
  @override
  Future<TokenMeta> token(String a) async {
    expect(a.toLowerCase(), forkBncb);
    return TokenMeta(a, 'BNCB', 'BNCB', 18);
  }

  @override
  Future<List<RouteResult>> routes(List<RouteRequestData> requests) async {
    final conf = await config();
    final result = <RouteResult>[];
    for (final request in requests) {
      expect(request.token.toLowerCase(), forkBncb);
      final idx = records.indexWhere(
        (r) =>
            r['wallet'].toString().toLowerCase() ==
            request.wallet.toLowerCase(),
      );
      final data =
          (fixture['fundingRoutes'] as List?)?[idx] ??
          (fixture['orderedTransactions'] as List)[idx * 2 + 1];
      final row = records[idx];
      expect(request.amount, BigInt.parse(row['inputWei'] as String));
      final minimum = BigInt.parse(row['conversionMinOut'] as String);
      result.add(
        RouteResult.ok(
          RoutePlan(
            wallet: request.wallet,
            to: conf.router,
            spender: conf.approvalSpender!,
            data: request.forecastOnly ? '0x' : data['data'] as String,
            value: request.amount,
            pools: const [],
            dexes: const [],
            quoteOut: minimum,
            minOut: minimum,
            chainId: 56,
            simulation: request.forecastOnly ? 'forecast' : 'uxuy',
            executed: !request.forecastOnly && row['gatewayExecuted'] != false,
            slippagePpm: 5000,
            priceImpact: 0.01,
            deadline: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120,
            gasLimit: request.forecastOnly ? 0 : 3000000,
            quoteScope: 'wallet',
            amount: request.amount,
            token: request.token,
            buy: true,
          ),
        ),
      );
    }
    return result;
  }

  @override
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async {
    if (token != null && spender != null) {
      for (final w in wallets) {
        final entry = records.singleWhere(
          (r) => r['wallet'].toString().toLowerCase() == w.toLowerCase(),
        );
        fundQuote(
          token,
          w,
          spender,
          BigInt.parse(entry['conversionMinOut'] as String),
          balance: BigInt.zero,
        );
      }
    }
    return super.refreshWalletStates(wallets, token: token, spender: spender);
  }

  Map<String, dynamic> get raised => {
    'status': 'PUBLISH',
    'symbolAddress': forkBncb,
    'nativeSymbol': 'BNCB',
    'symbol': 'BNCB',
    'totalBAmount': '3065',
  };
  @override
  Future<Object?> four(
    String op, [
    Map<String, Object?> payload = const {},
  ]) async {
    switch (op) {
      case 'config':
        return {
          'code': 0,
          'data': [raised],
        };
      case 'nonce':
        return {'code': 0, 'data': 'fixture'};
      case 'login':
        return {'code': 0, 'data': 'fixture'};
      case 'create':
        final parsed = AbiFunction.parse('createToken(bytes,bytes)')
            .decodeInput(hexToBytes(fixture['creation']['data'] as String));
        expect((payload['payload'] as Map)['preSale'], '0');
        return {
          'code': 0,
          'data': {
            'createArg': bytesToHex(parsed[0] as List<int>),
            'signature': bytesToHex(parsed[1] as List<int>),
          },
        };
      case 'predictTokenAddress':
        return {'tokenAddress': fixture['token']};
      default:
        throw StateError('unexpected Four action');
    }
  }

  @override
  Future<Object?> fourUpload(String accessToken, LaunchImage image) async => {
    'code': 0,
    'data': 'https://example.invalid/fixture.png',
  };
}

class _Four extends FourLauncher {
  _Four(BackendClient api) : super(api, ExecutionLog());
  @override
  Future<void> launchBundle(
    List<LaunchTx> txs,
    Map<String, int> nonces,
    BigInt gas,
    LaunchSession s,
  ) async {
    transactions = txs;
    session = s;
  }
}

class _Genius extends GeniusLauncher {
  _Genius(BackendClient api) : super(api, ExecutionLog(), random: Random(217));
  @override
  Future<void> launchBundle(
    List<LaunchTx> txs,
    Map<String, int> nonces,
    BigInt gas,
    LaunchSession s,
  ) async {
    transactions = txs;
    session = s;
  }
}

void main() {
  for (final platform in ['four', 'genius']) {
    final endpoint =
        Platform.environment['UXUY_${platform.toUpperCase()}_FUNDING_FORK'];
    test(
      '$platform creates a BNCB pool and executes wallet-bound UXUY BNB swaps before each official first buy',
      () async {
        final record = File(
          'test/fixtures/$platform-bnb-bncb-same-block.json',
        );
        final fixture = jsonDecode(await record.readAsString()) as Map;
        final api = _Contracts(Uri.parse(endpoint!), fixture);
        addTearDown(api.http_.close);
        expect(
          ((await api.read('anvil_nodeInfo', []) as Map)['forkConfig']
              as Map)['forkBlockNumber'],
          fixture['localForkBlock'],
        );
        final buyers = [
          for (final row in fixture['wallets'] as List)
            LaunchBuyer(
              _ObservedWallet(row['wallet'] as String),
              BigInt.parse(row['inputWei'] as String),
            ),
        ];
        late Launcher launch;
        if (platform == 'four') {
          final four = _Four(api);
          launch = four;
          await four.launch(
            FourLaunchForm(
              name: 'Matrix',
              shortName: 'MCK',
              desc: 'fixture',
              raised: FourRaised(api.raised),
              image: LaunchImage([1], 'fixture.png', 'image/png'),
              payWithBnb: true,
            ),
            dev: LaunchBuyer(
              _ObservedWallet(fixture['creation']['from'] as String),
              BigInt.zero,
            ),
            internal: buyers,
          );
        } else {
          final genius = _Genius(api);
          launch = genius;
          await genius.launch(
            GeniusLaunchForm(
              name: 'BNB buyer',
              symbol: 'BCK',
              logo: 'ipfs://test',
              creatorFeeRecipient: buyers.first.wallet.address,
              quote: forkBncb,
              payWithBnb: true,
              policy: const GeniusConfigurablePolicy(lpRewards: true),
            ),
            dev: buyers.first,
            internal: [buyers[1]],
          );
        }
        addTearDown(launch.dispose);
        expect(launch.error, isNull);
        expect(launch.session!.poolToken.toLowerCase(), forkBncb);
        expect(launch.session!.wallets.length, platform == 'four' ? 3 : 2);
        expect(launch.transactions.map((tx) => tx.kind), [
          'create',
          'funding',
          'funding',
          'inner',
          'inner',
        ]);
        for (final i in [0, 1]) {
          final swap = launch.transactions[1 + i] as LaunchFundingTx;
          final purchase = launch.transactions[3 + i];
          expect(swap.value, buyers[i].amount);
          expect(swap.from.address, buyers[i].wallet.address);
          expect(swap.simulatedDelivery, greaterThanOrEqualTo(swap.poolSpend));
          expect(purchase.from.address, swap.from.address);
          expect(purchase.simulatedDelivery, greaterThan(BigInt.zero));
        }
      },
      skip: endpoint == null
          ? 'Requires the matching isolated BSC Anvil fork'
          : false,
      timeout: const Timeout(Duration(minutes: 5)),
    );
    _graduationTest(platform, endpoint);
  }
}

class _GraduationContracts extends _Contracts {
  _GraduationContracts(super.endpoint, super.fixture);
  Map? simulationState;

  /// Supply the previously confirmed Permit2 balance for this specific public
  /// wallet, collateral and Infinity router, without signing or mining a grant.
  Map<String, Object?> get permitState {
    final row = records.last;
    String word(BigInt value) => value.toRadixString(16).padLeft(64, '0');
    BigInt slot =
        BigInt.one; // AllowanceTransfer.allowance follows nonceBitmap.
    for (final a in [row['wallet'] as String, forkBncb, geniusInfinityRouter]) {
      slot = BigInt.parse(
        bytesToHex(keccak256(hexToBytes(word(BigInt.parse(a)) + word(slot)))),
      );
    }
    final amount = BigInt.parse(row['conversionMinOut'] as String);
    final expiry = BigInt.from(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    );
    return {
      geniusPermit2: {
        'stateDiff': {'0x${word(slot)}': '0x${word(amount | expiry << 160)}'},
      },
    };
  }

  @override
  Future<Object?> read(String method, List<Object?> params) {
    if (method == 'eth_call' && (params.first as Map)['to'] == geniusPermit2) {
      return super.read(method, [
        ...params.take(2),
        {if (params.length > 2) ...params[2] as Map, ...permitState},
      ]);
    }
    if (method == 'eth_simulateV1') {
      final q = Map.from(params.first as Map);
      final blocks = (q['blockStateCalls'] as List).cast<Map>();
      q['blockStateCalls'] = [
        for (final block in blocks)
          {
            ...block,
            'stateOverrides': {
              ...?block['stateOverrides'] as Map?,
              ...permitState,
            },
          },
      ];
      simulationState =
          ((q['blockStateCalls'] as List).first as Map)['stateOverrides']
              as Map;
      return super.read(method, [q, ...params.skip(1)]);
    }
    return super.read(method, params);
  }
}

void _graduationTest(String platform, String? endpoint) {
  final input =
      Platform.environment['UXUY_MIGRATION_FUNDING_QUOTES'] ??
      'test/fixtures/bnb-funded-graduation.json';
  test(
    '$platform converts wallet-bound BNB to BNCB before the graduating inner buy and the outer buy',
    () async {
      final record = jsonDecode(
        await File(
          'test/fixtures/$platform-bnb-bncb-same-block.json',
        ).readAsString(),
      ) as Map;
      final quoteFile = jsonDecode(await File(input).readAsString()) as Map;
      final quotes = (quoteFile['fundingRoutes'] as List).cast<Map>();
      final wallets = [
        for (final q in quotes)
          {...q, 'inputWei': q['value'], 'conversionMinOut': q['minOut']},
      ];
      final api = _GraduationContracts(Uri.parse(endpoint!), {
        ...record,
        'wallets': wallets,
        'fundingRoutes': quotes,
      });
      addTearDown(api.http_.close);
      expect(
        ((await api.read('anvil_nodeInfo', []) as Map)['forkConfig']
            as Map)['forkBlockNumber'],
        record['localForkBlock'],
      );
      final buyers = [
        for (final q in quotes)
          LaunchBuyer(
            _ObservedWallet(q['wallet'] as String),
            BigInt.parse(q['value'] as String),
          ),
      ];
      final dev = LaunchBuyer(
        _ObservedWallet(record['creation']['from'] as String),
        BigInt.zero,
      );
      late Launcher launcher;
      if (platform == 'four') {
        final l = _Four(api);
        launcher = l;
        await l.launch(
          FourLaunchForm(
            name: 'Tax test',
            shortName: 'BSC',
            desc: 'fixture',
            raised: FourRaised(api.raised),
            image: LaunchImage([1], 'fixture.png', 'image/png'),
            external: true,
            payWithBnb: true,
            tax: const FourTax(
              feeRate: 3,
              feeRateSell: 3,
              burn: 100,
              divide: 0,
              liquidity: 0,
              recipient: 0,
            ),
          ),
          dev: dev,
          internal: [buyers.first],
          external: [buyers.last],
        );
      } else {
        final l = _Genius(api);
        launcher = l;
        await l.launch(
          GeniusLaunchForm(
            name: 'Graduate',
            symbol: 'BSC',
            logo: 'ipfs://test',
            creatorFeeRecipient: dev.wallet.address,
            exemptInternal: true,
            quote: forkBncb,
            external: true,
            payWithBnb: true,
            policy: const GeniusConfigurablePolicy(lpRewards: true),
          ),
          dev: dev,
          internal: [buyers.first],
          external: [buyers.last],
        );
      }
      addTearDown(launcher.dispose);
      if (quoteFile['expectError'] != null) {
        expect(launcher.error, contains(quoteFile['expectError']));
        expect(launcher.session, isNull);
        return;
      }
      expect(launcher.error, isNull);
      expect(launcher.session!.poolToken.toLowerCase(), forkBncb);
      expect(launcher.transactions.map((t) => t.kind), [
        'create',
        'funding',
        'funding',
        'inner',
        if (platform == 'genius') 'migrate',
        'outer',
      ]);
      final detail = <Map<String, Object?>>[];
      final conversions = launcher.transactions
          .whereType<LaunchFundingTx>()
          .toList();
      expect(conversions.map((tx) => tx.value), [
        buyers.last.amount,
        buyers.first.amount,
      ]);
      for (final tx in conversions) {
        final buy = launcher.transactions.singleWhere(
          (t) =>
              ['inner', 'outer'].contains(t.kind) &&
              t.from.address == tx.from.address,
        );
        expect(tx.from.address, buy.from.address);
        expect(
          buy.simulatedDelivery,
          greaterThanOrEqualTo(buy.minimumDelivery!),
        );
        expect(tx.simulatedDelivery, greaterThanOrEqualTo(tx.poolSpend));
        final idx = api.simulatedCalls!.indexWhere(
          (c) =>
              c['data'] == bytesToHex(buy.data) &&
              (c['from'] as String).toLowerCase() ==
                  buy.from.address.toLowerCase(),
        );
        final spent = -launchReceiptDelivery(
          api.simulations![idx],
          forkBncb,
          buy.from.address,
        );
        expect(spent, greaterThan(BigInt.zero));
        expect(spent, lessThanOrEqualTo(tx.poolSpend));
        detail.add({
          'wallet': tx.from.address,
          'stage': buy.kind,
          'bnbInput': tx.value.toString(),
          'minimumCollateral': tx.minimumDelivery.toString(),
          'receivedCollateral': tx.simulatedDelivery.toString(),
          'spentCollateral': spent.toString(),
          'retainedCollateral': (tx.simulatedDelivery! - spent).toString(),
          'minimumNewTokens': buy.minimumDelivery.toString(),
          'receivedNewTokens': buy.simulatedDelivery.toString(),
        });
      }
      final out = Platform.environment['UXUY_MIGRATION_FUNDING_RESULTS'];
      if (out != null)
        await File('$out-$platform.json').writeAsString(
          jsonEncode({
            'blockNumber': record['localForkBlock'],
            'now': platform == 'genius'
                ? BigInt.parse(
                    (await api.read('eth_getBlockByNumber', ['latest', false])
                            as Map)['timestamp']
                        as String,
                  ).toInt()
                : DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'token': launcher.session!.token,
            'transactions': [
              for (final tx in launcher.transactions)
                {
                  'from': tx.from.address,
                  'to': tx.to,
                  'data': bytesToHex(tx.data),
                  'value': '0x${tx.value.toRadixString(16)}',
                  'gas': '0x${tx.gasLimit.toRadixString(16)}',
                },
            ],
            'stateOverrides': api.simulationState,
            'order': [for (final tx in launcher.transactions) tx.kind],
            'wallets': detail,
          }),
        );
    },
    skip: endpoint == null
        ? 'Requires pinned collateral conversion quotes and isolated BSC fork'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
