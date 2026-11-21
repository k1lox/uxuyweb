@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/exec/executor.dart' show TradeOutcome;
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fork_group.dart';

/// Real launchpad tokens (found read-only from official contract logs, see backend/dev/token_search/),
/// tested through the ordinary group on a local BSC fork, including separate approvals and zero project fees.
/// Run: UXUY_FORK_BACKEND=http://127.0.0.1:3293/ flutter test --tags fork test/real_tokens_test.dart
final _backend = Platform.environment['UXUY_FORK_BACKEND'];
final _anvil = Platform.environment['UXUY_FORK_RPC'] ?? 'http://127.0.0.1:8545';
const feeTo = '0x00000000000000000000000000000000000FEe00';

Future<Object?> anvil(String method, List<Object?> params) async {
  final r = await http.post(
    Uri.parse(_anvil),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    }),
  );
  final j = jsonDecode(r.body) as Map<String, dynamic>;
  if (j['error'] != null) throw StateError('$method: ${j['error']}');
  return j['result'];
}

Future<BigInt> nativeOf(String a) async =>
    BigInt.parse('${await anvil('eth_getBalance', [a, 'latest'])}');
Future<BigInt> tokenOf(String token, String a) async {
  final f = AbiFunction.parse('balanceOf(address) returns (uint256)');
  return f
          .decodeOutput(
            '${await anvil('eth_call', [
              {
                'to': token,
                'data': f.encodeHex([a]),
              },
              'latest',
            ])}',
          )
          .single!
      as BigInt;
}

void main() {
  final file = File(
    Platform.environment['UXUY_REAL_TOKENS'] ??
        '../../../backend/dev/real_tokens.json',
  );
  final skip = _backend == null || !file.existsSync()
      ? 'needs UXUY_FORK_BACKEND and backend/dev/real_tokens.json'
      : null;
  final tokens = file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as List)
            .cast<Map<String, dynamic>>()
      : <Map<String, dynamic>>[];
  setUpAll(() async {
    if (skip == null) await verifyLocalFork(_anvil, _backend!);
  });
  final summary = <String>[];
  tearDownAll(() => stdout.writeln('\n== 真实代币测试汇总 ==\n${summary.join('\n')}'));

  for (final t in tokens) {
    test(
      '${t['category']} ${t['symbol']} ${t['token']}',
      () async {
        final client = http.Client();
        addTearDown(client.close);
        final api = BackendClient(Uri.parse(_backend!), client);
        final token = '${t['token']}';
        final wallets = [TradeWallet.generate('A'), TradeWallet.generate('B')];
        for (final w in wallets) {
          await anvil('anvil_setBalance', [w.address, '0xde0b6b3a7640000']);
        }
        final round = await ForkGroup.open(api, token, wallets);
        String reason() =>
            round.state.log.entries.map((e) => e.text).join('\n');
        final fee0 = await nativeOf(feeTo);
        late final TradeOutcome buy;
        try {
          buy = await round.trade(buy: true);
        } on BackendException catch (e) {
          if (!{
            'UXUY_NO_ROUTE',
            'UXUY_ROUTE_INVALID',
            'LIQUIDITY_INSUFFICIENT',
          }.contains(e.code))
            rethrow;
          expect(
            round.group.trader.last,
            isNull,
            reason: 'refusal must occur before execution',
          );
          for (final w in wallets) {
            expect(await tokenOf(token, w.address), BigInt.zero);
          }
          expect(await nativeOf(feeTo), fee0);
          summary.add('首买未执行 ${t['symbol']} · ${e.code}');
          return;
        }
        expect(buy.confirmed, wallets.length, reason: reason());
        for (final w in wallets) {
          expect(
            await tokenOf(token, w.address),
            greaterThan(BigInt.zero),
            reason: reason(),
          );
        }
        expect(await nativeOf(feeTo), fee0, reason: 'no project fee on buys');
        final sell = await round.trade(buy: false);
        expect(sell.confirmed, wallets.length, reason: reason());
        expect(await nativeOf(feeTo), fee0, reason: 'no project fee on sells');
        for (final w in wallets) {
          final left = await tokenOf(token, w.address);
          expect(
            round.state.market!.sellUnits(left),
            BigInt.zero,
            reason: 'every executable unit must be sold ($left)\n${reason()}',
          );
        }
        summary.add(
          '通过 ${t['category']} ${t['symbol']} · ${round.state.market!.label}',
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
}
