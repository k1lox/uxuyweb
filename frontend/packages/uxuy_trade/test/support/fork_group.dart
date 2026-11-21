import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/uxuy_trade.dart';

Future<void> verifyLocalFork(String rpcUrl, String backendUrl) async {
  final rpc = Uri.parse(rpcUrl), backend = Uri.parse(backendUrl);
  for (final uri in [rpc, backend]) {
    expect(uri.scheme, 'http');
    expect(['localhost', '127.0.0.1', '::1'], contains(uri.host));
  }
  final node = await http.post(
    rpc,
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'web3_clientVersion',
      'params': [],
    }),
  );
  expect(
    (jsonDecode(node.body)['result'] as String).toLowerCase(),
    contains('anvil'),
  );
  final config = jsonDecode(
    (await http.get(backend.resolve('/api/v1/config'))).body,
  );
  expect(config['chainId'], 56);
  expect(config['rpcProvider'], 'local-fork');
}

/// Drive the same preparation and confirmation entry points as an ordinary group.
class ForkGroup {
  ForkGroup._(this.state, this.group);
  final AppState state;
  final TradeGroup group;

  static Future<ForkGroup> open(
    BackendClient api,
    String token,
    List<TradeWallet> wallets,
  ) async {
    final state = AppState(
      api,
      MemoryKeyStore(),
      impactSettings: const ImpactSettings(
        bundle: 30,
        intervalStart: 30,
        intervalLive: 30,
      ),
    );
    addTearDown(state.dispose);
    await state.init();
    await state.loadToken(token);
    final group = state.addGroup()
      ..wallets = wallets
      ..selected.addAll(wallets.map((w) => w.address));
    return ForkGroup._(state, group);
  }

  Future<TradeOutcome> trade({
    required bool buy,
    Future<void> Function(PreparedRound)? afterCheck,
  }) async {
    group.setBuy(buy);
    group.setRatio(!buy);
    group.mode = buy ? SendMode.bundle : SendMode.interval;
    group.min = group.max = buy ? '0.01' : '100';
    final checked = await state.prepare(group);
    if (afterCheck != null) await afterCheck(checked);
    return state.start(group, prepared: checked, impactConfirmed: true);
  }
}
