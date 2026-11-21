import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

final launchForkBlock = int.parse(
  Platform.environment['UXUY_LAUNCH_FORK_BLOCK'] ?? '134456783',
);
const forkBncb = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';
const forkNvdab = '0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436';

class LaunchForkNode extends BackendClient {
  LaunchForkNode(this.endpoint) : super(endpoint, http.Client()) {
    if (endpoint.scheme != 'http' || endpoint.host != '127.0.0.1') {
      throw ArgumentError('Only a local Anvil fork is supported');
    }
  }
  final Uri endpoint;
  var id = 0;
  List<Map>? simulations;
  List<Map>? simulatedCalls;

  final _quoteStorage = <String, Map<String, Object?>>{};

  /// The two fork-tested bStocks use the OpenZeppelin ERC-7201 storage layout.
  /// Their actual getters below verify the test balance and exact allowance
  /// before using the same isolated state in ordered simulation.
  void fundQuote(
    String token,
    String wallet,
    String spender,
    BigInt amount, {
    BigInt? balance,
  }) {
    if (![
      forkBncb,
      forkNvdab,
    ].any((a) => a.toLowerCase() == token.toLowerCase()))
      throw ArgumentError('Unsupported fixture token');
    final base = BigInt.parse(
      '52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00',
      radix: 16,
    );
    String word(BigInt n) => n.toRadixString(16).padLeft(64, '0');
    String slot(String address, String index) => bytesToHex(
      keccak256(hexToBytes('${address.substring(2).padLeft(64, '0')}$index')),
    );
    final ownerSlot = slot(wallet, word(base + BigInt.one));
    _quoteStorage[token] = {
      'stateDiff': {
        ...?(_quoteStorage[token]?['stateDiff'] as Map<String, String>?),
        slot(wallet, word(base)): '0x${word(balance ?? amount)}',
        slot(spender, ownerSlot.substring(2)): '0x${word(amount)}',
      },
    };
  }

  @override
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async {
    if (token == null || spender == null)
      return walletStates(wallets, token: token, spender: spender);
    Future<BigInt> value(String fn, List<Object?> args) async {
      final call = AbiFunction.parse(fn);
      final raw = await read('eth_call', [
        {'to': token, 'data': bytesToHex(call.encode(args))},
        'latest',
        _quoteStorage,
      ]);
      return BigInt.parse(raw as String);
    }

    return [
      for (final wallet in wallets)
        WalletState(
          wallet,
          parseUnits('100', 18),
          0,
          await value('balanceOf(address)', [wallet]),
          await value('allowance(address,address)', [wallet, spender]),
        ),
    ];
  }

  Future<Object?> read(String method, List<Object?> params) async {
    if (!{
      'anvil_nodeInfo',
      'eth_call',
      'eth_getCode',
      'eth_getBlockByNumber',
      'eth_simulateV1',
    }.contains(method)) {
      throw StateError('Read-only test, rejected $method');
    }
    final res = await http_
        .post(
          endpoint,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'id': ++id,
            'jsonrpc': '2.0',
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 90));
    final obj = jsonDecode(res.body) as Map;
    final error = obj['error'];
    if (error != null) throw BackendException('RPC_ERROR', '$error', false);
    return obj['result'];
  }

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) => Future.wait(
    calls.map((c) async {
      if (c.$1 != 'eth_simulateV1') return read(c.$1, c.$2);
      final req = Map.of(c.$2.first as Map);
      final block = Map.of((req['blockStateCalls'] as List).single as Map);
      final transactions = (block['calls'] as List).cast<Map>();
      simulatedCalls = transactions;
      block['stateOverrides'] = {
        ..._quoteStorage,
        for (final tx in transactions)
          tx['from']: {
            'balance': '0x${parseUnits('100', 18).toRadixString(16)}',
          },
      };
      req['blockStateCalls'] = [block];
      final result = await read(c.$1, [req, 'latest']);
      simulations = (((result as List).single as Map)['calls'] as List)
          .cast<Map>();
      return result;
    }),
  );

  @override
  Future<GasInfo> gas() async => GasInfo(BigInt.one, launchForkBlock);
  @override
  Future<List<WalletState>> walletStates(
    List<String> addresses, {
    String? token,
    String? spender,
  }) async => [
    for (final address in addresses)
      WalletState(address, parseUnits('100', 18), 0, null, null),
  ];
  @override
  SignedTx sign(TradeWallet wallet, LegacyTx tx) =>
      throw StateError('This test stops before signing');
}
