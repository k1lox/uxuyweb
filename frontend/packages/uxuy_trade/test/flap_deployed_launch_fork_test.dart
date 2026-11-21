@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/launch_fork_node.dart';

class _Preview extends FlapLauncher {
  _Preview(BackendClient api) : super(api, ExecutionLog(), random: Random(718));
  @override
  Future<void> launchBundle(
    List<LaunchTx> txs,
    Map<String, int> nonceMap,
    BigInt gasPrice,
    LaunchSession s,
  ) async {
    transactions = txs;
    session = s;
  }
}

final _state = AbiFunction.parse(
  'getTokenV8Safe(address) returns ((uint8,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,address,bool,bytes32,uint256,uint256,address,uint256,uint8,uint8))',
);

Future<(List, String)> _postState(
  LaunchForkNode api,
  List<LaunchTx> txs,
  String token,
) async {
  final result =
      (await api.rpc([
            (
              'eth_simulateV1',
              [
                {
                  'blockStateCalls': [
                    {
                      'calls': [
                        for (final tx in txs)
                          {
                            'from': tx.from.address,
                            'to': tx.to,
                            'data': bytesToHex(tx.data),
                            'value': '0x${tx.value.toRadixString(16)}',
                            'gas': '0x${tx.gasLimit.toRadixString(16)}',
                            'gasPrice': '0x0',
                          },
                        {
                          'from': txs.first.from.address,
                          'to': flapPortal,
                          'data': bytesToHex(_state.encode([token])),
                          'gas': '0x400000',
                          'gasPrice': '0x0',
                        },
                      ],
                    },
                  ],
                  'validation': false,
                  'traceTransfers': false,
                },
                'latest',
              ],
            ),
          ])).single
          as List;
  final last = (result.single['calls'] as List).last as Map;
  expect(last['status'], '0x1');
  final output = last['returnData'] as String;
  return (_state.decodeOutput(output).single as List, output);
}

class _SnapshotApi extends LaunchForkNode {
  _SnapshotApi(super.endpoint, this.block, this.state, this.pool);
  final String block, state, pool;
  bool hasCode = true;
  @override
  Future<String> call(String to, String data, {String block = 'latest'}) async {
    expect(to, flapPortal);
    expect(block, this.block);
    return state;
  }

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    expect(calls.single.$1, 'eth_getCode');
    expect(calls.single.$2, [pool, block]);
    return [hasCode ? '0x60ff' : '0x'];
  }
}

void main() {
  final endpoint = Platform.environment['UXUY_FLAP_MATRIX_FORK'];
  for (final migrate in [false, true]) {
    test(
      'UUSD pool accepts native BNB Dev and follow-on buyers migrate=$migrate',
      () async {
        const uusd = '0x61a10e8556bed032ea176330e7f17d6a12a10000';
        final api = LaunchForkNode(Uri.parse(endpoint!));
        addTearDown(api.http_.close);
        final keys = [
          for (int i = 0; i < 4; i++)
            TradeWallet.import(
              'fixture',
              (129000 + i).toRadixString(16).padLeft(64, '0'),
            ),
        ];
        final launch = _Preview(api);
        addTearDown(launch.dispose);
        final balance = AbiFunction.parse(
          'balanceOf(address) returns (uint256)',
        );
        for (final key in keys) {
          expect(
            BigInt.parse(
              await api.call(uusd, balance.encodeHex([key.address])),
            ),
            BigInt.zero,
          );
        }
        await launch.launch(
          FlapLaunchForm(
            nonTax: false,
            name: 'UUSD Matrix',
            symbol: 'UTEST',
            payment: FlapPayment({
              'address': uusd,
              'symbol': 'UUSD',
              'decimals': 18,
            }),
            payWithBnb: true,
            external: migrate,
            image: LaunchImage([1], 'test.png', 'image/png'),
            buyTaxBps: 300,
            sellTaxBps: 300,
            marketingBps: 10000,
            minimumShare: flapMinDividendShare,
          ),
          dev: LaunchBuyer(keys[0], parseUnits('0.01', 18)),
          internal: [
            LaunchBuyer(keys[1], parseUnits('0.01', 18)),
            if (migrate) LaunchBuyer(keys[2], parseUnits('65', 18)),
          ],
          external: [if (migrate) LaunchBuyer(keys[3], parseUnits('0.01', 18))],
          metaOverride:
              'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        expect(launch.error, isNull);
        expect(launch.session!.poolToken.toLowerCase(), uusd);
        expect(launch.transactions.first.value, BigInt.zero);
        final buys = launch.transactions.skip(1);
        expect(buys.length, migrate ? 4 : 2);
        for (final tx in buys) {
          expect(tx.to, flapPortal);
          expect(tx.value, greaterThan(BigInt.zero));
          expect(tx.simulatedDelivery, greaterThan(BigInt.zero));
        }
        final out = Platform.environment['UXUY_UUSD_LAUNCH_FIXTURE'];
        if (out != null && !migrate) {
          await File(out).writeAsString(
            jsonEncode({
              'blockNumber': launchForkBlock,
              'token': launch.session!.token,
              'transactions': [
                for (final tx in launch.transactions)
                  {
                    'from': tx.from.address,
                    'to': tx.to,
                    'data': bytesToHex(tx.data),
                    'value': '0x${tx.value.toRadixString(16)}',
                    'gas': '0x${tx.gasLimit.toRadixString(16)}',
                  },
              ],
            }),
          );
        }
      },
      skip: endpoint == null ? 'Requires local BSC fork' : false,
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }
  for (final version in [6, 7]) {
    for (final migrate in [false, true]) {
      test(
        'deployed Flap V$version ordered official BNB purchases migrate=$migrate',
        () async {
          final api = LaunchForkNode(Uri.parse(endpoint!));
          addTearDown(api.http_.close);
          final info = await api.read('anvil_nodeInfo', []) as Map;
          expect(info['forkConfig']['forkBlockNumber'], launchForkBlock);
          final launch = _Preview(api);
          addTearDown(launch.dispose);
          final keys = [
            for (var i = 0; i < 4; i++)
              TradeWallet.import(
                'fixture',
                (129000 + i).toRadixString(16).padLeft(64, '0'),
              ),
          ];
          final form = FlapLaunchForm(
            name: 'Matrix',
            symbol: 'MATR',
            image: LaunchImage([1], 'fixture.png', 'image/png'),
            nonTax: version == 7,
            external: migrate,
            payment: FlapPayment({
              'address': zeroAddress,
              'symbol': 'BNB',
              'decimals': 18,
              'r': '6.14',
              'h': '107036752',
              'k': '6797205657.28',
            }),
            buyTaxBps: 300,
            sellTaxBps: 300,
            marketingBps: 10000,
            minimumShare: flapMinDividendShare,
          );
          await launch.launch(
            form,
            dev: LaunchBuyer(keys[0], parseUnits('0.01', 18)),
            internal: [
              LaunchBuyer(keys[1], parseUnits('0.02', 18)),
              LaunchBuyer(keys[2], parseUnits(migrate ? '25' : '0.03', 18)),
            ],
            external: [
              if (migrate) LaunchBuyer(keys[3], parseUnits('0.01', 18)),
            ],
            metaOverride:
                'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          );
          expect(
            launch.error,
            isNull,
            reason:
                '${api.simulations?.map((r) => [r['status'], r['error'], r['returnData']])}',
          );
          expect(launch.transactions.length, migrate ? 4 : 3);
          expect(
            launch.session!.wallets.map((w) => w.address),
            keys.take(migrate ? 4 : 3).map((w) => w.address),
          );
          final file = Platform.environment['UXUY_FLAP_PUBLIC_PREVIEW'];
          if (file != null && version == 6 && migrate) {
            await File(file).writeAsString(
              jsonEncode({
                'blockNumber': launchForkBlock,
                'token': launch.session!.token,
                'transactions': [
                  for (final tx in launch.transactions)
                    {
                      'from': tx.from.address,
                      'to': tx.to,
                      'value': '0x${tx.value.toRadixString(16)}',
                      'data': bytesToHex(tx.data),
                      'gas': '0x${tx.gasLimit.toRadixString(16)}',
                    },
                ],
              }),
              flush: true,
            );
          }
          final swap = AbiFunction.parse(
            'swapExactInputV3((address,address,uint256,uint256,bytes,bytes))',
          );
          for (var i = 1; i < launch.transactions.length; i++) {
            final tx = launch.transactions[i],
                row = swap.decodeInput(tx.data).single as List;
            expect(tx.to, flapPortal);
            expect(row[0], zeroAddress);
            expect(row[2], tx.value);
            expect(row[3], greaterThan(BigInt.zero));
            expect(tx.simulatedDelivery, greaterThanOrEqualTo(row[3]));
            expect(tx.protocolCheck!(api.simulations![i]), isNull);
          }
          final state = await _postState(
            api,
            launch.transactions,
            launch.session!.token,
          );
          expect(state.$1[0], BigInt.from(migrate ? 4 : 1));
          final pool = state.$1[14].toString().toLowerCase();
          if (migrate) {
            expect(pool, isNot(zeroAddress));
            final migration = launch.transactions[2],
                outer = launch.transactions[3];
            final calls = api.simulations!;
            expect(migration.protocolCheck!(calls[3]), isNotNull);
            expect(outer.protocolCheck!(calls[2]), isNotNull);
            // eth_simulateV1 supplies the inclusion fields of its own simulated block.
            final firstLog = (calls.first['logs'] as List).first as Map;
            final block = firstLog['blockNumber'] as String;
            final blockHash = firstLog['blockHash'] as String;
            final replay = _SnapshotApi(
              Uri.parse(endpoint),
              block,
              state.$2,
              pool,
            );
            addTearDown(replay.http_.close);
            final settled = _Preview(replay);
            addTearDown(settled.dispose);
            for (var i = 0; i < launch.transactions.length; i++) {
              final tx = launch.transactions[i];
              final inclusion = (calls[i]['logs'] as List).first as Map;
              expect(inclusion['blockHash'], blockHash);
              tx.hash = inclusion['transactionHash'] as String;
              tx.status = 'confirmed';
              tx.receipt = {
                'transactionHash': tx.hash,
                'blockNumber': block,
                'blockHash': blockHash,
                'transactionIndex': inclusion['transactionIndex'],
                'status': '0x1',
                'logs': calls[i]['logs'],
              };
            }
            expect(
              await settled.settle(launch.transactions),
              isTrue,
              reason:
                  'status=${migration.status} issue=${migration.protocolError}, version=${state.$1[4]} quote=${state.$1[9]} pool=$pool, event=${(migration.receipt!['logs'] as List).where((r) => r['topics'].length == 1 && r['data'].toString().length == 258).map((r) => r['data'])}',
            );
            replay.hasCode = false;
            expect(await settled.settle(launch.transactions), isFalse);
            expect(migration.status, 'protocol_unproven');
          }
          expect(
            await api.read('eth_getCode', [launch.session!.token, 'latest']),
            '0x',
          );
        },
        skip: endpoint == null ? 'Requires a local BSC Anvil fork' : false,
        timeout: const Timeout(Duration(minutes: 8)),
      );
    }
  }
  for (final (version, quote) in [(6, forkBncb), (7, forkNvdab)]) {
    test(
      'deployed Flap V$version official ERC20 Dev and inner swaps on a quoted pool',
      () async {
        final api = LaunchForkNode(Uri.parse(endpoint!));
        addTearDown(api.http_.close);
        final launch = _Preview(api);
        addTearDown(launch.dispose);
        final keys = [
          for (int i = 0; i < 3; i++)
            TradeWallet.import(
              'fixture',
              (191900 + i).toRadixString(16).padLeft(64, '0'),
            ),
        ];
        final amount = parseUnits('0.01', 18);
        for (final wallet in keys) {
          api.fundQuote(quote, wallet.address, flapPortal, amount);
        }
        final form = FlapLaunchForm(
          name: 'Quote Matrix',
          symbol: 'QMTX',
          image: LaunchImage([1], 'fixture.png', 'image/png'),
          nonTax: version == 7,
          payment: FlapPayment({
            'address': quote,
            'symbol': 'QUOTE',
            'decimals': 18,
          }),
          buyTaxBps: 300,
          sellTaxBps: 300,
          marketingBps: 10000,
          minimumShare: flapMinDividendShare,
        );
        await launch.launch(
          form,
          dev: LaunchBuyer(keys.first, amount),
          internal: [for (final w in keys.skip(1)) LaunchBuyer(w, amount)],
          metaOverride:
              'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        expect(
          launch.error,
          isNull,
          reason: '${api.simulations?.map((r) => [r['status'], r['error']])}',
        );
        expect(launch.transactions.length, 4);
        expect(launch.transactions.first.value, BigInt.zero);
        final token = launch.session!.token;
        for (var i = 1; i < 4; i++) {
          final tx = launch.transactions[i], receipt = api.simulations![i];
          expect(tx.from.address, keys[i - 1].address);
          expect(tx.to, flapPortal);
          expect(tx.value, BigInt.zero);
          expect(
            launchReceiptDelivery(receipt, quote, tx.from.address),
            -amount,
          );
          expect(
            launchReceiptDelivery(receipt, token, tx.from.address),
            greaterThanOrEqualTo(tx.minimumDelivery!),
          );
        }
        final snapshot = (await _postState(api, launch.transactions, token)).$1;
        final fees = AbiFunction.parse(
          'getFeeRate() returns (uint256,uint256)',
        );
        final fee =
            fees
                    .decodeOutput(
                      await api.call(flapPortal, bytesToHex(fees.encode([]))),
                    )
                    .first
                as BigInt;
        String decimal(int i) =>
            formatUnits(snapshot[i] as BigInt, 18, maxFraction: 18);
        final gross = flapCurveGross(
          r: decimal(5),
          h: decimal(6),
          k: decimal(7),
          quoteDecimals: 18,
          platformBuyFeeBps: fee,
          buyTaxBps: BigInt.from(version == 6 ? 300 : 0),
          tokenTargetUnits: snapshot[8] as BigInt,
        );
        final target = gross * BigInt.from(105) ~/ BigInt.from(100);
        api.fundQuote(quote, keys[1].address, flapPortal, target);
        final graduated = _Preview(api);
        addTearDown(graduated.dispose);
        final ext = FlapLaunchForm(
          name: form.name,
          symbol: form.symbol,
          image: form.image,
          external: true,
          nonTax: form.nonTax,
          payment: form.payment,
          buyTaxBps: 300,
          sellTaxBps: 300,
          marketingBps: 10000,
          minimumShare: flapMinDividendShare,
        );
        await graduated.launch(
          ext,
          dev: LaunchBuyer(keys[0], amount),
          internal: [LaunchBuyer(keys[1], target)],
          external: [LaunchBuyer(keys[2], amount)],
          metaOverride:
              'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        expect(
          graduated.error,
          isNull,
          reason:
              '${api.simulations?.map((r) => [r['status'], r['error']])}, gross=$gross version=$version',
        );
        final after = (await _postState(
          api,
          graduated.transactions,
          graduated.session!.token,
        )).$1;
        expect(after[0], BigInt.from(4));
        expect(after[9].toString().toLowerCase(), quote.toLowerCase());
        expect(after[14], isNot(zeroAddress));
      },
      skip: endpoint == null ? 'Requires a local BSC Anvil fork' : false,
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
  for (final (label, quote) in [
    ('BNB', zeroAddress),
    ('BNCB', forkBncb),
    ('NVDAB', forkNvdab),
  ]) {
    for (final nonTax in [true, false]) {
      test(
        'deployed Flap V${nonTax ? 7 : 6} $label: official creation',
        () async {
          final api = LaunchForkNode(Uri.parse(endpoint!));
          addTearDown(api.http_.close);
          expect(
            (await api.read('anvil_nodeInfo', [])
                as Map)['forkConfig']['forkBlockNumber'],
            launchForkBlock,
          );
          final launcher = _Preview(api);
          addTearDown(launcher.dispose);
          final keys = [
            for (int i = 0; i < 3; i++)
              TradeWallet.import(
                'test$i',
                (119000 + i).toRadixString(16).padLeft(64, '0'),
              ),
          ];
          final form = FlapLaunchForm(
            name: 'Launch Matrix',
            symbol: 'MATR',
            image: LaunchImage([1], 'local.png', 'image/png'),
            nonTax: nonTax,
            payment: FlapPayment({
              'address': quote,
              'symbol': label,
              'decimals': 18,
              'category': label == 'BNB' ? 'crypto' : 'rwa',
              if (label == 'BNB') ...{
                // BNB row in the recorded official Flap payment catalogue.
                'r': '6.14',
                'h': '107036752',
                'k': '6797205657.28',
              },
            }),
            buyTaxBps: 300,
            sellTaxBps: 300,
            marketingBps: 10000,
            minimumShare: flapMinDividendShare,
          );
          final purchase = BigInt.from(10000000000000000);
          if (quote != zeroAddress)
            api.fundQuote(quote, keys.first.address, flapPortal, purchase);
          await launcher.launch(
            form,
            metaOverride:
                'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            dev: LaunchBuyer(keys.first, purchase),
          );
          expect(
            launcher.error,
            isNull,
            reason:
                'Simulated results: ${api.simulations?.map((x) => [x['status'], x['error']])}',
          );
          if (quote != zeroAddress)
            expect(
              launchReceiptDelivery(
                api.simulations!.single,
                quote,
                keys.first.address,
              ),
              -purchase,
            );
          expect(api.simulations, hasLength(1));
          expect(api.simulations!.map((m) => m['status']), everyElement('0x1'));
          if (!nonTax && quote == zeroAddress) {
            final tx = launcher.transactions.single;
            final v6 = AbiFunction.parse(
              'newTokenV6((string,string,string,uint8,bytes32,uint8,address,uint256,address,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8))',
            );
            for (final bps in [0, 50, 100, 1000]) {
              final args = List<Object?>.of(
                v6.decodeInput(tx.data).single as List,
              )..[14] = BigInt.from(bps);
              final check = LaunchTx(
                tx.label,
                tx.from,
                tx.to,
                v6.encode([args]),
                tx.value,
                8000000,
              );
              try {
                await launcher.simulateBundle([check], requireSuccess: true);
              } on StateError {
                if (bps != 50) rethrow;
              }
              final result = api.simulations!.single;
              expect(
                result['status'],
                bps == 50 ? '0x0' : '0x1',
                reason: 'Flap V6 buyTaxBps $bps: ${result['error']}',
              );
            }
          }
          expect(launcher.transactions.first.kind, 'create');
          expect(
            await api.read('eth_getCode', [launcher.session!.token, 'latest']),
            '0x',
          );
        },
        skip: endpoint == null
            ? 'Set UXUY_FLAP_MATRIX_FORK to a local Anvil fork at $launchForkBlock.'
            : false,
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }
  }
}
