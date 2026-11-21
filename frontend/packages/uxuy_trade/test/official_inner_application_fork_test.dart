import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

/// Launch with the matching fork-only relay and Rust service on these dedicated
/// loopback ports. The token was in its native Flap market at the pinned block.
void main() {
  final enabled = Platform.environment['UXUY_OFFICIAL_INNER_LOCAL'] == '1';
  test(
    'group check → finite approval → signed Flap buy and sell on local Anvil',
    () async {
      const token = '0xc86326b3a664478c774e0279546405bdf44f8888';
      const portal = '0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0';
      final transport = http.Client();
      addTearDown(transport.close);
      final api = BackendClient(
        Uri.parse('http://127.0.0.1:19743/'),
        transport,
      );
      final rpcUrl = Uri.parse('http://127.0.0.1:19741/');
      Future<dynamic> rpc(String method, List<Object?> params) async {
        final response = await transport.post(
          rpcUrl,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        );
        final body = jsonDecode(response.body) as Map;
        if (body['error'] != null)
          throw StateError('$method: ${body['error']}');
        return body['result'];
      }

      expect(await rpc('web3_clientVersion', []), startsWith('anvil/'));
      final details = await rpc('anvil_nodeInfo', []) as Map;
      final fork = details['forkConfig'] as Map;
      expect(fork['forkUrl'], 'http://127.0.0.1:19672');
      final block = await rpc('eth_blockNumber', []);
      final wallet = TradeWallet.generate('fork-only');
      final owner = wallet.address;
      await rpc('anvil_setBalance', [owner, '0xde0b6b3a7640000']);
      final state = AppState(api, MemoryKeyStore());
      addTearDown(state.dispose);
      await state.init();
      await state.loadToken(token);
      expect(state.market!.innerTarget!.toLowerCase(), portal);
      expect(state.market!.innerPlatform, 'flap');
      final group = state.addGroup()
        ..wallets = [wallet]
        ..selected.add(owner);
      final facts = <String, Object?>{
        'token': token,
        'portal': portal,
        'wallet': owner,
        'client': await rpc('web3_clientVersion', []),
        'chainId': await rpc('eth_chainId', []),
        'startBlock': block,
        'historicalForkBlock': fork['forkBlockNumber'],
        'path': 'AppState.loadToken → prepare → start → loopback Rust → local relay → loopback Anvil',
        'broadcastToPublicNetwork': false,
      };

      final premature = api.checkInnerApprovals(
        token,
        portal,
        [(wallet: owner, amount: BigInt.one, reset: false)],
        innerPlatform: 'flap',
        innerToken: token,
      );
      await expectLater(
        premature,
        throwsA(
          isA<BackendException>().having(
            (e) => e.code,
            'code',
            'INNER_GRANT_BUDGET',
          ),
        ),
      );
      facts['unquotedApprovalError'] = 'INNER_GRANT_BUDGET';
      Future<BigInt> units(String signature, List<Object> args) async {
        final f = AbiFunction.parse(signature);
        final data = await rpc('eth_call', [
          {'to': token, 'data': f.encodeHex(args)},
          'latest',
        ]) as String;
        return f.decodeOutput(data).single as BigInt;
      }

      Future<BigInt> balance() =>
          units('balanceOf(address) returns (uint256)', [owner]);
      Future<BigInt> allowance() => units(
        'allowance(address,address) returns (uint256)',
        [owner, portal],
      );
      Future<String> nonce() => rpc('eth_getTransactionCount', [
        owner,
        'latest',
      ]).then((v) => v as String);
      expect(await balance(), BigInt.zero);
      expect(await allowance(), BigInt.zero);
      expect(await nonce(), '0x0');

      group.min = group.max = '0.001';
      final buy = await state.prepare(group);
      expect(await nonce(), '0x0');
      final quoted = await api.route(
        RouteRequestData(
          buy: true,
          token: token,
          amount: buy.inputTotal,
          wallet: owner,
          market: state.market,
          maxImpactPercent: 100,
        ),
      );
      final verifiedLeg = quoted.legs.single;
      final head = await api.gas();
      final altered = wallet.sign(
        LegacyTx(
          nonce: 0,
          gasPrice: head.gasPrice,
          gasLimit: verifiedLeg.gasLimit + 1,
          to: verifiedLeg.to,
          value: verifiedLeg.value,
          data: hexToBytes(verifiedLeg.data),
        ),
      );
      final rejected = await transport.post(
        Uri.parse('http://127.0.0.1:19743/api/v1/bundles'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'transactions': [altered.raw],
          'maxBlockNumber': head.blockNumber + 20,
        }),
      );
      final refusal = jsonDecode(rejected.body) as Map;
      expect(refusal['ok'], false);
      expect(refusal['notSubmitted'], true);
      expect(await nonce(), '0x0');
      facts['alteredGasRejectedBeforeRelay'] = refusal['code'];
      final bought = await state.start(
        group,
        prepared: buy,
        impactConfirmed: true,
      );
      expect(
        bought.confirmed,
        1,
        reason: state.log.entries.map((e) => e.text).join('\n'),
      );
      final purchase = bought.tradeHashes.single;
      final purchaseReceipt =
          await rpc('eth_getTransactionReceipt', [purchase]) as Map;
      expect(purchaseReceipt['status'], '0x1');
      expect(purchaseReceipt['to'].toString().toLowerCase(), portal);
      final acquired = await balance();
      expect(acquired > BigInt.zero, isTrue);
      facts['buy'] = {
        'hash': purchase,
        'block': purchaseReceipt['blockNumber'],
        'amountInWei': buy.inputTotal.toString(),
        'tokensReceived': acquired.toString(),
      };

      group.setBuy(false);
      group.ratio = true;
      group.min = group.max = '100';
      final sale = await state.prepare(group);
      expect(sale.inputTotal, acquired);
      final allowanceAfterCheck = await allowance();
      expect(allowanceAfterCheck, acquired);
      expect(await nonce(), '0x2');
      final approvalBlock =
          await rpc('eth_getBlockByNumber', ['latest', true]) as Map;
      final approval = (approvalBlock['transactions'] as List)
          .cast<Map>()
          .singleWhere(
            (tx) =>
                tx['from'].toString().toLowerCase() == owner.toLowerCase() &&
                tx['to'].toString().toLowerCase() == token.toLowerCase(),
          );
      expect(approval['input'].toString().startsWith('0x095ea7b3'), isTrue);
      final approvalReceipt =
          await rpc('eth_getTransactionReceipt', [approval['hash']]) as Map;
      expect(approvalReceipt['status'], '0x1');
      facts['approval'] = {
        'hash': approval['hash'],
        'block': approvalReceipt['blockNumber'],
        'allowanceReadBack': allowanceAfterCheck.toString(),
      };
      final nativeBeforeSale = BigInt.parse(
        await rpc('eth_getBalance', [owner, 'latest']) as String,
      );
      final sold = await state.start(
        group,
        prepared: sale,
        impactConfirmed: true,
      );
      expect(
        sold.confirmed,
        1,
        reason: state.log.entries.map((e) => e.text).join('\n'),
      );
      final saleHash = sold.tradeHashes.single;
      final saleReceipt =
          await rpc('eth_getTransactionReceipt', [saleHash]) as Map;
      expect(saleReceipt['status'], '0x1');
      expect(saleReceipt['to'].toString().toLowerCase(), portal);
      expect(await balance(), BigInt.zero);
      expect(await allowance(), BigInt.zero);
      expect(await nonce(), '0x3');
      final saleGas =
          BigInt.parse(saleReceipt['gasUsed'] as String) *
          BigInt.parse(saleReceipt['effectiveGasPrice'] as String);
      final nativeAfterSale = BigInt.parse(
        await rpc('eth_getBalance', [owner, 'latest']) as String,
      );
      final received = nativeAfterSale - nativeBeforeSale + saleGas;
      expect(received > BigInt.zero, isTrue);
      facts['sale'] = {
        'nativeReceivedWei': received.toString(),
        'hash': saleHash,
        'block': saleReceipt['blockNumber'],
        'tokensRemaining': '0',
        'allowanceRemaining': '0',
      };
      final evidence = Platform.environment['UXUY_OFFICIAL_INNER_EVIDENCE'];
      if (evidence != null)
        File(evidence).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(facts)}\n',
        );
    },
    skip: enabled
        ? false
        : 'Requires isolated Flap fork, local Rust backend and local relay',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
