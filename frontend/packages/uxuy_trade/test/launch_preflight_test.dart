import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/launch_purchase_receipt.dart';
import 'support/fake_backend.dart' show FakeBackend, token;

import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

class Probe extends BackendClient {
  Probe()
    : super(
        Uri.parse('http://test.invalid'),
        MockClient((_) => throw StateError('unexpected HTTP')),
      );
  List<WalletState> snapshots = [];
  List<String>? batch;
  String? spenderRead;
  int sends = 0;
  int? lastMaxBlock;
  final reconciled = <String>[];
  Object? sendError;
  final checked = <String>[];
  final receiptOrder = <String>[];
  final statusByHash = <String, String>{};
  final wait = Completer<void>();
  bool hold = false;
  String? deployedCode;
  final codeReads = <List<Object?>>[];

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    if (deployedCode != null &&
        calls.every((call) => call.$1 == 'eth_getCode')) {
      codeReads.addAll(calls.map((call) => call.$2));
      return [for (final _ in calls) deployedCode!];
    }
    if (calls.every((call) => call.$1 == 'eth_getTransactionReceipt')) {
      return [
        for (final call in calls)
          launchReceipt(call.$2.first as String, receiptOrder.indexOf(call.$2.first as String), []),
      ];
    }
    return super.rpc(calls);
  }

  @override
  Future<List<WalletState>> walletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async {
    batch = wallets;
    spenderRead = spender;
    return snapshots;
  }

  @override
  Future<GasInfo> gas() async => GasInfo(BigInt.one, 300);
  @override
  Future<Map<String, dynamic>> bundle(List<String> raws, int head) async {
    sends++;
    lastMaxBlock = head;
    if (sendError != null) throw sendError!;
    return {};
  }

  @override
  Future<TxRecord> reconcileStatus(String hash) {
    reconciled.add(hash);
    return status(hash);
  }

  @override
  Future<TxRecord> status(String hash) async {
    checked.add(hash);
    if (!receiptOrder.contains(hash)) receiptOrder.add(hash);
    if (hold) await wait.future;
    return TxRecord(
      hash,
      statusByHash[hash] ?? 'confirmed',
      null,
      receipt: launchReceipt(hash, receiptOrder.indexOf(hash), []),
    );
  }
}

void main() {
  final keys = [
    for (int i = 1; i <= 2; i++)
      TradeWallet.import('Test $i', i.toRadixString(16).padLeft(64, '0')),
  ];
  const target = '0x0000000000000000000000000000000000001234';
  LaunchTx leg(int i, {String kind = 'approve'}) => LaunchTx(
    'test',
    keys[i],
    target,
    Uint8List(0),
    BigInt.zero,
    21000,
    kind: kind,
  )..hash = 'hash$i';
  late Probe api;
  late FourLauncher launcher;
  setUp(() {
    api = Probe();
    launcher = FourLauncher(api, ExecutionLog(), sleep: (_) async {});
  });
  test('wallet nonce and funding use one address-mapped snapshot, even for reordered replies', () async {
    api.snapshots = [
      for (final i in [1, 0])
        WalletState(keys[i].address, BigInt.from(42000), i + 3, null, null),
    ];
    final nonces = await launcher.checkBalances([leg(0), leg(1)], BigInt.one);
    expect(nonces[keys[0].address.toLowerCase()], 3);
    expect(nonces[keys[1].address.toLowerCase()], 4);
    api.snapshots.removeLast();
    await expectLater(
      launcher.checkBalances([leg(0), leg(1)], BigInt.one),
      throwsStateError,
    );
  });
  test('liquidation logs an empty round only after checking every participant', () async {
    final node = FakeBackend();
    for (final wallet in keys) {
      node.wallets[wallet.address.toLowerCase()] = {
        'native': '1000000000000000000', 'nonce': 0, 'tokenBalance': '0', 'routerAllowance': '1000',
      };
    }
    final clear = FlapLauncher(node.api(), ExecutionLog())
      ..session = LaunchSession(platform: 'flap', token: token, symbol: 'TEST', dev: keys.first, wallets: [keys.first])
      ..state = LaunchState.launched;
    addTearDown(clear.dispose);
    clear.recordTradeParticipant(token, keys.last);
    final lastWallet = node.wallets[keys.last.address.toLowerCase()]!;
    const message = '本轮钱包已无可卖代币，未提交清仓';
    final emptyLogs = clear.log.entries.where((e) => e.text.contains(message));

    lastWallet.remove('tokenBalance');
    await expectLater(clear.prepareLiquidation(), throwsA(isA<BackendException>()));
    expect(emptyLogs, isEmpty);

    lastWallet['tokenBalance'] = '1000';
    final preview = await clear.prepareLiquidation();
    expect(preview.amounts, {keys.last.address.toLowerCase(): BigInt.from(1000)});
    expect(emptyLogs, isEmpty);

    lastWallet['tokenBalance'] = '0';
    await expectLater(clear.prepareLiquidation(), throwsA(isA<StateError>().having(
      (e) => e.message, 'reason', '没有可执行的钱包：余额不足',
    )));
    expect(emptyLogs, hasLength(1));
    expect(clear.log.entries.last.text, endsWith(message));
    expect(node.signatures, isEmpty);
    expect(node.bundles, isEmpty);
  });
  test('lost approval response can be resolved by original hashes without starting a launch or resending', () async {
    api.sendError = TimeoutException('lost response');
    final txs = [leg(0), leg(1)];
    await launcher.guard(() async {
      await launcher.submitBundle(txs, ['raw0', 'raw1']);
    });
    expect(launcher.state, LaunchState.pending);
    expect(txs.map((t) => t.status), everyElement('unknown'));
    expect(api.lastMaxBlock, 340);
    api.hold = true;
    final query = launcher.query();
    await Future<void>.delayed(Duration.zero);
    expect(api.checked, ['hash0', 'hash1']);
    expect(api.reconciled, ['hash0', 'hash1']);
    await launcher.query();
    await expectLater(launcher.guard(() async {}), throwsStateError);
    api.wait.complete();
    await query;
    expect(launcher.state, LaunchState.idle);
    expect(launcher.session, isNull);
    expect(api.sends, 1);
  });
  test('Four and Flap admit 103 actual transactions, Genius keeps its expanded limit', () {
    for (final (runner, limit) in [
      (launcher as Launcher, 103),
      (FlapLauncher(api, ExecutionLog()), 103),
      (GeniusLauncher(api, ExecutionLog()), 300),
    ]) {
      final txs = [
        for (var i = 0; i < limit; i++) leg(0)..hash = null,
        leg(0, kind: 'tip')..hash = null,
      ];
      final nonces = {keys[0].address.toLowerCase(): 0};
      expect(
        () => runner.signAll(txs, nonces, BigInt.one),
        throwsA(isA<StateError>().having(
          (e) => e.message, 'size', contains('共 ${limit + 1} 笔，超过单个捆绑上限 $limit'),
        )),
      );
      expect(nonces.values.single, 0);
      expect(txs.every((tx) => tx.hash == null), isTrue);
      // Record local signatures right at the boundary. No call reaches a node.
      final raws = runner.signAll(txs.take(limit).toList(), nonces, BigInt.one);
      expect(raws.length, limit);
      expect(nonces.values.single, limit);
    }
    expect(api.sends, 0);
  });
  test('an unresolved tip keeps the original bundle pending; a reverted tip cannot replay the creation', () async {
    final txs = [leg(0, kind: 'create'), leg(0, kind: 'tip')..hash = null];
    final session = LaunchSession(
      platform: 'four',
      token: target,
      symbol: 'TEST',
      dev: keys[0],
      wallets: [keys[0]],
    );
    launcher.signAll(txs, {keys[0].address.toLowerCase(): 0}, BigInt.one);
    final tipHash = txs[1].hash!;
    api.statusByHash[tipHash] = 'accepted';
    await launcher.launchBundle(
      txs,
      {keys[0].address.toLowerCase(): 0},
      BigInt.one,
      session,
    );
    expect(launcher.state, LaunchState.pending);
    expect(launcher.error, contains('有交易尚未确认'));
    await expectLater(launcher.guard(() async {}), throwsStateError);
    expect(launcher.reset, throwsStateError);
    api.statusByHash[tipHash] = 'reverted';
    await launcher.query();
    expect(launcher.state, LaunchState.launched);
    expect(launcher.transactions.map((tx) => tx.status), [
      'confirmed',
      'reverted',
    ]);
    expect(launcher.error, contains('已回滚'));
    await expectLater(launcher.guard(() async {}), throwsStateError);
    expect(api.sends, 1);
  });
  test('missing creation proof keeps the original deployment pending until its address has bytecode', () async {
    api.deployedCode = '0x';
    final creation = LaunchTx(
      '创建',
      keys[0],
      target,
      Uint8List(0),
      BigInt.zero,
      21000,
      kind: 'create',
      protocolCheck: (_) => '缺少官方创建事件',
    );
    await launcher.launchBundle(
      [creation],
      {keys[0].address.toLowerCase(): 0},
      BigInt.one,
      LaunchSession(
        platform: 'Four',
        token: target,
        symbol: 'TEST',
        dev: keys[0],
        wallets: [keys[0]],
      ),
    );
    expect(launcher.state, LaunchState.pending);
    expect(creation.status, 'unknown');
    expect(api.codeReads.single, [target, creation.receipt!['blockNumber']]);
    api.deployedCode = '0x6000';
    await launcher.query();
    expect(launcher.state, LaunchState.launched);
    expect(creation.status, 'protocol_unproven');
    expect(launcher.error, contains('缺少官方创建事件'));
    expect(api.sends, 1);
  });
  test('explicit before-send rejection is terminal and never treated as a submitted creation', () async {
    api.sendError = const BackendException(
      'INVALID_REQUEST',
      '拒绝',
      false,
      notSubmitted: true,
    );
    await launcher.guard(() async {
      await launcher.submitBundle([leg(0, kind: 'create')], ['raw0']);
    });
    expect(launcher.state, LaunchState.failed);
    expect(launcher.transactions.single.status, 'not_submitted');
    expect(api.checked, isEmpty);
  });
}
