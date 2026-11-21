@Tags(['fork'])
library;

import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/launch_fork_node.dart';

class _Preview extends GeniusLauncher {
  _Preview(BackendClient api) : super(api, ExecutionLog(), random: Random(918));
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

/// Fund only synthetic wallets in eth_call/eth_simulateV1 state overrides. Permit2
/// is exercised through its actual deployed code on the local fork.
class _FundedQuoteSequence extends LaunchForkNode {
  _FundedQuoteSequence(super.endpoint, this.pair, this.outer);
  final String pair;
  final TradeWallet outer;
  final allowance = BigInt.one << 120;
  @override
  Future<TokenMeta> token(String address) async {
    final symbol = AbiFunction.parse('symbol() returns (string)'),
        decimals = AbiFunction.parse('decimals() returns (uint8)');
    final values = await super.rpc([
      for (final fn in [symbol, decimals])
        (
          'eth_call',
          [
            {'to': address, 'data': fn.encodeHex([])},
            'latest',
          ],
        ),
    ]);
    return TokenMeta(
      address,
      '',
      symbol.decodeOutput(values[0] as String).single as String,
      (decimals.decodeOutput(values[1] as String).single as BigInt).toInt(),
    );
  }

  @override
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) {
    if (token != null && spender != null) {
      for (final w in wallets) {
        fundQuote(token, w, spender, allowance);
      }
    }
    return super.refreshWalletStates(wallets, token: token, spender: spender);
  }

  Map<String, Object?> get permit => {
    'from': outer.address,
    'to': geniusPermit2,
    'gas': '0x30d40',
    'gasPrice': '0x0',
    'data': AbiFunction.parse('approve(address,address,uint160,uint48)')
        .encodeHex([
          pair,
          geniusInfinityRouter,
          allowance,
          (BigInt.one << 48) - BigInt.one,
        ]),
  };
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    if (calls.isNotEmpty &&
        calls.every(
          (c) =>
              c.$1 == 'eth_call' && (c.$2.first as Map)['to'] == geniusPermit2,
        )) {
      final r = await super.rpc([
        (
          'eth_simulateV1',
          [
            {
              'blockStateCalls': [
                {
                  'calls': [
                    permit,
                    for (final c in calls)
                      {'from': outer.address, ...(c.$2.first as Map)},
                  ],
                },
              ],
              'validation': false,
            },
            'latest',
          ],
        ),
      ]);
      final rows = ((r.single as List).single as Map)['calls'] as List;
      return [for (final row in rows.skip(1)) (row as Map)['returnData']];
    }
    if (calls.length == 1 && calls.first.$1 == 'eth_simulateV1') {
      final req = Map.of(calls.first.$2.first as Map),
          block = Map.of(
            ((calls.first.$2.first as Map)['blockStateCalls'] as List).single
                as Map,
          );
      block['calls'] = [permit, ...block['calls'] as List];
      req['blockStateCalls'] = [block];
      final result = await super.rpc([
        ('eth_simulateV1', [req, 'latest']),
      ]);
      final output = (result.single as List).single as Map;
      final full = (output['calls'] as List);
      if (full.first['status'] != '0x1')
        throw StateError('Test Permit2 precondition failed');
      final restored = full.skip(1).toList();
      simulations = restored.cast<Map>();
      simulatedCalls = simulatedCalls?.skip(1).toList();
      return [
        [
          {...output, 'calls': restored},
        ],
      ];
    }
    return super.rpc(calls);
  }
}

void main() {
  final endpoint = Platform.environment['UXUY_GENIUS_MATRIX_FORK'];
  for (final migrate in [false, true]) {
    test(
      'deployed m5.2 official curve sequence, graduation and Infinity first fill: migrate=$migrate',
      () async {
        final api = LaunchForkNode(Uri.parse(endpoint!));
        addTearDown(api.http_.close);
        final launcher = _Preview(api);
        addTearDown(launcher.dispose);
        final wallets = [
          for (var i = 0; i < 4; i++)
            TradeWallet.import(
              'synthetic $i',
              (129392 + i).toRadixString(16).padLeft(64, '0'),
            ),
        ];
        final pool = await launcher.previewPool(zeroAddress);
        final tiny = parseUnits('0.002', 18);
        await launcher.launch(
          GeniusLaunchForm(
            name: 'Genius Matrix',
            symbol: 'MAT',
            logo: 'ipfs://test',
            creatorFeeRecipient: wallets[0].address,
            external: migrate,
            exemptInternal: true,
          ),
          dev: LaunchBuyer(wallets[0], BigInt.zero),
          internal: [
            LaunchBuyer(wallets[1], tiny),
            LaunchBuyer(
              wallets[2],
              migrate ? pool.threshold * BigInt.two : tiny,
            ),
          ],
          external: [if (migrate) LaunchBuyer(wallets[3], tiny)],
        );
        if (Platform.environment['UXUY_GENIUS_CAPTURE'] == '1') {
          final file = File(
            '${Directory.systemTemp.path}/uxuy-genius-m52-${migrate ? 'graduation' : 'inner'}.json',
          );
          await file.writeAsString(
            jsonEncode({
              'threshold': pool.threshold.toString(),
              'simulatedCalls': api.simulatedCalls,
              'simulatedResults': api.simulations,
              'txs': [
                for (final tx in launcher.transactions)
                  {
                    'from': tx.from.address,
                    'to': tx.to,
                    'data': bytesToHex(tx.data),
                    'value': tx.value.toString(),
                    'kind': tx.kind,
                    'gas': tx.gasLimit,
                  },
              ],
            }),
          );
        }
        expect(
          launcher.error,
          isNull,
          reason: launcher.log.entries.map((e) => e.text).join(' / '),
        );
        final txs = launcher.transactions;
        expect(txs.map((t) => t.kind), [
          'create',
          'inner',
          'inner',
          if (migrate) 'migrate',
          if (migrate) 'outer',
        ]);
        for (final tx in txs.where((t) => t.purchasedToken != null)) {
          expect(tx.simulatedDelivery, greaterThan(BigInt.zero));
          expect(tx.minimumDelivery, greaterThan(BigInt.zero));
        }
        expect(
          await api.read('eth_getCode', [launcher.session!.token, 'latest']),
          '0x',
        );
      },
      skip: endpoint == null ? 'Requires isolated read-only Anvil fork' : false,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
  for (final pair in [forkBncb, forkNvdab]) {
    test(
      'deployed quote-paid multi-wallet curve, migration and Infinity first fill: $pair',
      () async {
        final wallets = [
          for (var i = 0; i < 4; i++)
            TradeWallet.import(
              'quote synthetic $i',
              (159802 + i).toRadixString(16).padLeft(64, '0'),
            ),
        ];
        final api = _FundedQuoteSequence(
          Uri.parse(endpoint!),
          pair,
          wallets.last,
        );
        addTearDown(api.http_.close);
        final launcher = _Preview(api);
        addTearDown(launcher.dispose);
        final pool = await launcher.previewPool(pair);
        final small = pool.threshold ~/ BigInt.from(100);
        await launcher.launch(
          GeniusLaunchForm(
            name: 'Genius Quote',
            symbol: 'MQU',
            logo: 'ipfs://test',
            creatorFeeRecipient: wallets[0].address,
            quote: pair,
            external: true,
            exemptInternal: true,
          ),
          dev: LaunchBuyer(wallets[0], BigInt.zero),
          internal: [
            LaunchBuyer(wallets[1], small),
            LaunchBuyer(wallets[2], pool.threshold * BigInt.two),
          ],
          external: [LaunchBuyer(wallets[3], small)],
        );
        expect(
          launcher.error,
          isNull,
          reason: launcher.log.entries.map((e) => e.text).join(' / '),
        );
        expect(launcher.transactions.map((t) => t.kind), [
          'create',
          'inner',
          'inner',
          'migrate',
          'outer',
        ]);
        if (Platform.environment['UXUY_GENIUS_CAPTURE'] == '1') {
          final txs = launcher.transactions,
              create = geniusCreate.decodeInput(txs.first.data);
          final outer = txs.last,
              execute = AbiFunction.parse('execute(bytes,bytes[],uint256)')
                  .decodeInput(outer.data);
          final key = pair.toLowerCase() == forkBncb.toLowerCase()
              ? 'bncb'
              : 'nvdab';
          await File('${Directory.systemTemp.path}/uxuy-genius-m52-$key.json').writeAsString(
            jsonEncode({
              'launchContext': {
                'dev': wallets.first.address,
                'to': geniusM52Factory,
                'data': geniusPreview.encodeHex([
                  create.first,
                  wallets.first.address,
                ]),
                'value': '0',
              },
              'quote': pair,
              'token': launcher.session!.token,
              'curve': txs[1].to,
              'inner': {
                'wallet': wallets[1].address,
                'amount': small.toString(),
                'spender': txs[1].to,
              },
              'outer': {
                'wallet': wallets.last.address,
                'amount': small.toString(),
                'erc20Spender': geniusPermit2,
                'permitSpender': geniusInfinityRouter,
                'swapDeadline': execute.last.toString(),
              },
              'txs': [
                for (final tx in txs)
                  {
                    'from': tx.from.address,
                    'to': tx.to,
                    'data': bytesToHex(tx.data),
                    'value': tx.value.toString(),
                    'kind': tx.kind,
                    'gas': tx.gasLimit,
                  },
              ],
              'simulatedResults': api.simulations,
            }),
          );
        }
        expect(launcher.transactions.last.value, BigInt.zero);
        expect(
          launcher.transactions.last.simulatedDelivery,
          greaterThan(BigInt.zero),
        );
        expect(
          await api.read('eth_getCode', [launcher.session!.token, 'latest']),
          '0x',
        );
      },
      skip: endpoint == null ? 'Requires isolated read-only Anvil fork' : false,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
  for (final (label, address) in [
    ('BNB', zeroAddress),
    ('WBNB', wbnb),
    ('BNCB', forkBncb),
    ('NVDAB', forkNvdab),
  ]) {
    for (final tax in [false, true]) {
      test(
        'deployed m5.2 official creation: $label, taxed=$tax',
        () async {
          final api = LaunchForkNode(Uri.parse(endpoint!));
          addTearDown(api.http_.close);
          final info = await api.read('anvil_nodeInfo', []) as Map;
          expect(info['forkConfig']['forkBlockNumber'], launchForkBlock);
          final launcher = _Preview(api);
          addTearDown(launcher.dispose);
          final keys = [
            for (int i = 0; i < 3; i++)
              TradeWallet.import(
                'test$i',
                (119000 + i).toRadixString(16).padLeft(64, '0'),
              ),
          ];
          final policy = tax
              ? const GeniusConfigurablePolicy(
                  buyBps: 200,
                  sellBps: 350,
                  burnBps: 10000,
                )
              : const GeniusConfigurablePolicy(lpRewards: true);
          final purchase = tax ? BigInt.from(10000000000000000) : BigInt.zero;
          if (address != zeroAddress && address != wbnb && tax)
            api.fundQuote(
              address,
              keys.first.address,
              geniusM52LaunchAndBuy,
              purchase,
            );
          await launcher.launch(
            GeniusLaunchForm(
              name: 'Matrix Check',
              symbol: 'MCK',
              logo: 'ipfs://test',
              creatorFeeRecipient: keys.first.address,
              quote: address,
              policy: policy,
            ),
            dev: LaunchBuyer(keys.first, purchase),
          );
          if (address == wbnb) {
            final approved = AbiFunction.parse(
              'approvedPairTokens(address) returns (bool)',
            );
            final value = await api.call(
              geniusM52Factory,
              approved.encodeHex([wbnb]),
            );
            expect(approved.decodeOutput(value).single, false);
            expect(launcher.error, contains('尚未支持所选底池币'));
            expect(api.simulations, isNull);
            expect(launcher.transactions, isEmpty);
            expect(launcher.session, isNull);
            return;
          }
          expect(
            launcher.error,
            isNull,
            reason:
                'Simulation statuses: ${api.simulations?.map((x) => [x['status'], x['error']])}',
          );
          if (address != zeroAddress && tax)
            expect(
              launchReceiptDelivery(
                api.simulations!.single,
                address,
                keys.first.address,
              ),
              -purchase,
            );
          expect(api.simulations, hasLength(1));
          expect(api.simulations!.map((m) => m['status']), everyElement('0x1'));
          expect(
            await api.read('eth_getCode', [launcher.session!.token, 'latest']),
            '0x',
            reason: 'Simulation did not create anything on the fork',
          );
        },
        skip: endpoint == null
            ? 'Set UXUY_GENIUS_MATRIX_FORK to a loopback Anvil fork pinned to $launchForkBlock.'
            : false,
        timeout: const Timeout(Duration(minutes: 4)),
      );
    }
  }
}
