@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';

import 'support/fork_group.dart';

import 'package:uxuy_trade/src/wallet/wallet.dart';

void main() {
  final nodeUrl = Platform.environment['UXUY_FORK_RPC'];
  final appUrl = Platform.environment['UXUY_FORK_BACKEND'];
  late http.Client cli;
  late Uri node;
  late BackendClient api;
  final skip = nodeUrl == null || appUrl == null
      ? 'requires isolated Anvil and local-fork backend'
      : null;
  Future<Object?> rpc(String method, List<Object?> params) async {
    final res = await cli.post(
      node,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }),
    );
    final row = jsonDecode(res.body) as Map;
    if (row['error'] != null) throw StateError('$method: ${row['error']}');
    return row['result'];
  }

  const wbnb = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c';
  // Ephemeral fixtures are never persisted. Only the loopback Anvil is funded.
  TradeWallet fixture(String name) {
    final generated = TradeWallet.generate(name);
    return TradeWallet.import(name, generated.exportPrivateKey());
  }

  setUp(() async {
    if (skip != null) return;
    await verifyLocalFork(nodeUrl!, appUrl!);
    cli = http.Client();
    addTearDown(cli.close);
    node = Uri.parse(nodeUrl);
    final apiRoot = Uri.parse(appUrl);
    api = BackendClient(apiRoot, cli);
  });
  test(
    'local BSC fork: WBNB deposit, signed relay distribution and full collection without price providers',
    () async {
      final src = fixture('source'),
          relay = fixture('relay'),
          recipient = fixture('recipient');
      await rpc('anvil_setBalance', [src.address, '0xde0b6b3a7640000']);
      await rpc('anvil_setBalance', [recipient.address, '0x2386f26fc10000']);
      final gas = await api.gas();
      final amount = parseUnits('0.001', 18);
      final deposit = src.sign(
        LegacyTx(
          nonce: 0,
          gasPrice: gas.gasPrice,
          gasLimit: 90000,
          to: wbnb,
          value: amount,
          data: hexToBytes('0xd0e30db0'),
        ),
      );
      await rpc('eth_sendRawTransaction', [deposit.raw]);
      Map? depositReceipt;
      for (var i = 0; i < 150 && depositReceipt == null; i++) {
        depositReceipt =
            await rpc('eth_getTransactionReceipt', [deposit.hash]) as Map?;
        if (depositReceipt == null)
          await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        depositReceipt?['status'],
        '0x1',
        reason: 'The funded synthetic wallet must have WBNB before testing the tool.',
      );
      Future<BigInt> owned(TradeWallet w) async => BigInt.parse(
        (await rpc('eth_call', [
          {
            'to': wbnb,
            'data': '0x70a08231${w.address.substring(2).padLeft(64, '0')}',
          },
          'latest',
        ])) as String,
      );
      expect(await owned(src), amount);
      final log = ExecutionLog();
      final engine = TransferEngine(
        api,
        log,
        pollEvery: const Duration(milliseconds: 150),
      );
      final asset = await engine.asset(wbnb);
      expect(asset.decimals, 18);
      expect(asset.symbol, 'WBNB');
      final outgoing = await engine.prepareDistribution(
        engine.drawOneToMany(
          src,
          [recipient.address],
          amount,
          amount,
          transits: {recipient.address.toLowerCase(): relay},
        ),
        asset,
        source: src,
      );
      await engine.execute(outgoing);
      expect(
        outgoing.complete,
        true,
        reason: log.entries.map((l) => l.text).join('\n'),
      );
      expect(await owned(recipient), amount);
      expect(await owned(src), BigInt.zero);
      expect(await owned(relay), BigInt.zero);
      final collect = await engine.prepareCollection(
        [recipient],
        src.address,
        asset,
      );
      await engine.execute(collect);
      expect(
        collect.complete,
        true,
        reason: log.entries.map((l) => l.text).join('\n'),
      );
      expect(await owned(src), amount);
      expect(await owned(recipient), BigInt.zero);
      for (final tx in [...outgoing.legs, ...collect.legs]) {
        final receipt =
            await rpc('eth_getTransactionReceipt', [tx.hash]) as Map;
        expect(receipt['status'], '0x1');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // These are independently established BSC external markets. Platform
  // discovery has its own suite. This exercises the production external path.
  for (final (symbol, token) in [
    ('CAKE', '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82'),
    ('DOGE', '0xba2ae424d960c26247dd6c32edc70b295c744c43'),
    ('BTCB', '0x7130d2a12b9bcbfae4f2634d864a1ee1ce3ead9c'),
    ('USDC', '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d'),
  ]) {
    test(
      'real $symbol external bundle buy / interval sell + allowance and native fees',
      () async {
        final w = fixture(symbol);
        await rpc('anvil_setBalance', [w.address, '0xde0b6b3a7640000']);
        final balance = AbiFunction.parse(
          'balanceOf(address) returns (uint256)',
        );
        Future<BigInt> tokens() async =>
            balance
                    .decodeOutput(
                      await api.call(token, balance.encodeHex([w.address])),
                    )
                    .single
                as BigInt;
        final round = await ForkGroup.open(api, token, [w]);
        String detail() =>
            round.state.log.entries.map((l) => l.text).join('\n');
        final bought = await round.trade(buy: true);
        expect(bought.confirmed, 1, reason: detail());
        final acquired = await tokens();
        expect(acquired, greaterThan(BigInt.zero));
        final spender = (await api.config()).approvalSpender!;
        final sold = await round.trade(
          buy: false,
          afterCheck: (prepared) async {
            final allowance = AbiFunction.parse(
              'allowance(address,address) returns (uint256)',
            );
            final raw = await api.call(
              token,
              allowance.encodeHex([w.address, spender]),
            );
            expect(allowance.decodeOutput(raw).single, acquired);
            expect(
              await tokens(),
              acquired,
              reason: 'preflight only approved the position',
            );
          },
        );
        expect(sold.confirmed, 1, reason: detail());
        expect(await tokens(), BigInt.zero);
        expect(
          sold.sent,
          sold.tradeHashes,
          reason: 'only the swap is submitted after confirmation',
        );
        for (final hash in [...bought.sent, ...sold.sent]) {
          final receipt = await rpc('eth_getTransactionReceipt', [hash]) as Map;
          expect(receipt['status'], '0x1');
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
