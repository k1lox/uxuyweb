import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

final unit = BigInt.from(10).pow(18);
final proceeds = unit ~/ BigInt.from(10);
final sold = BigInt.from(500);

class _FaultClient extends BackendClient {
  _FaultClient(this.backend)
    : super(Uri.parse('http://in-memory.test/'), backend.client());
  final FakeBackend backend;
  final reads = <({bool buy, List<String> hashes})>[];
  bool failBuy = false;
  int failures = 0;
  Completer<void>? gate;

  @override
  SignedTx sign(TradeWallet wallet, LegacyTx tx) {
    final signed = super.sign(wallet, tx);
    backend.signatures[signed.raw] = (
      signed.hash,
      wallet.address.toLowerCase(),
      tx,
    );
    return signed;
  }

  @override
  Future<({BigInt native, BigInt tokens})> linkedTradeDelta(
    List<String> hashes, {
    required String token,
    required bool buy,
  }) async {
    reads.add((buy: buy, hashes: List.of(hashes)));
    if (buy == failBuy) {
      if (gate != null) await gate!.future;
      if (failures > 0) {
        failures--;
        throw const BackendException('UNAVAILABLE', '回执服务暂不可用', true);
      }
    }
    return (native: proceeds, tokens: sold);
  }
}

class _ReceiptOutageBackend extends FakeBackend {
  bool unavailable = true;
  final proofReads = <List<String>>[];

  @override
  http.Client client() {
    final mock = super.client();
    return MockClient((req) async {
      if (req.url.path.endsWith('/rpc/bsc')) {
        final calls = (jsonDecode(req.body) as List).cast<Map>();
        final receiptHashes = [
          for (final c in calls)
            if (c['method'] == 'eth_getTransactionReceipt')
              c['params'][0] as String,
        ];
        if (receiptHashes.isNotEmpty) {
          proofReads.add(receiptHashes);
          if (unavailable) {
            unavailable = false;
            return http.Response('temporary test outage', 503);
          }
        }
      }
      final forwarded = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes;
      return http.Response.fromStream(await mock.send(forwarded));
    });
  }
}

class _Alarm implements Timer {
  _Alarm(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    expect(isActive, isTrue);
    tick++;
    cancel();
    callback();
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'state transition did not complete');
}

void main() {
  late FakeBackend backend;
  late _FaultClient api;
  late ExecutionLog log;
  late LinkedTrader linked;
  late LinkedPlan plan;
  late bool disposed;
  late List<_Alarm> alarms;
  final seller = TradeWallet.import('seller', '0x${'1'.padLeft(64, '0')}');
  final buyer = TradeWallet.import('buyer', '0x${'2'.padLeft(64, '0')}');

  void wallet(TradeWallet wallet, BigInt native, BigInt tokens) {
    backend.wallets[wallet.address.toLowerCase()] = {
      'native': '$native',
      'nonce': 1,
      'tokenBalance': '$tokens',
      'routerAllowance': '${BigInt.two.pow(255)}',
    };
  }

  setUp(() {
    disposed = false;
    backend = FakeBackend();
    api = _FaultClient(backend);
    log = ExecutionLog();
    alarms = [];
    linked = LinkedTrader(
      api,
      log,
      sleep: (_) async {},
      retryTimer: (duration, callback) {
        final alarm = _Alarm(duration, callback);
        alarms.add(alarm);
        return alarm;
      },
    );
    plan = LinkedPlan(
      token: token,
      market: null,
      sellers: [seller],
      buyers: [buyer],
      sizing: LinkedSizing.percent(5000),
      loop: false,
    );
    wallet(seller, unit, sold * BigInt.two);
    wallet(buyer, unit, BigInt.zero);
    backend.onBundle = (_) {
      if (backend.bundles.length == 1) {
        wallet(seller, unit + proceeds, sold);
      } else {
        wallet(buyer, unit - proceeds, sold);
      }
    };
  });

  tearDown(() {
    if (!disposed) linked.dispose();
    log.dispose();
  });

  Future<void> failFirstThree() async {
    for (var i = 0; i < 3; i++) {
      await until(() => alarms.length == i + 1);
      expect(alarms[i].delay.inSeconds, 1 << i);
      expect(linked.reconciliationWarning, isFalse);
      expect(linked.error, isNull);
      alarms[i].fire();
    }
  }

  test('real receipt endpoint 503 then an unrelated deposit and manual chain refresh cannot change the original proceeds', () async {
    final rpc = _ReceiptOutageBackend();
    backend = rpc;
    wallet(seller, unit, sold * BigInt.two);
    wallet(buyer, unit, BigInt.zero);
    backend.onBundle = (_) {
      if (backend.bundles.length == 1) {
        wallet(seller, unit + proceeds, sold);
      } else {
        wallet(buyer, unit - proceeds, sold);
      }
    };
    final client = backend.api();
    linked.dispose();
    linked = LinkedTrader(
      client,
      log,
      sleep: (_) async {},
      retryTimer: (delay, callback) {
        final timer = _Alarm(delay, callback);
        alarms.add(timer);
        return timer;
      },
    );
    final running = linked.run(plan);
    await until(() => alarms.isNotEmpty);
    expect(backend.bundles.length, 1);
    wallet(seller, unit * BigInt.from(7), BigInt.one);
    expect(
      (await client.refreshWalletStates([
        seller.address,
      ], token: token)).single.native,
      unit * BigInt.from(7),
    );
    alarms.single.fire();
    final p = await running;
    expect(p.finished, isTrue);
    expect(p.sold, sold);
    expect(p.received, proceeds);
    expect(p.spent, proceeds);
    expect(rpc.proofReads[1], rpc.proofReads[0]);
    expect(backend.bundles, hasLength(2));
  });
  test('transient confirmed sell retries silently using the original hash, then continues', () async {
    api.failures = 2; // Initial read and first retry fail.
    final running = linked.run(plan);
    await until(() => alarms.isNotEmpty);
    final original = linked.unsettledHashes.single;
    alarms.single.fire();
    await until(() => alarms.length == 2);
    expect(backend.bundles, hasLength(1));
    expect(
      log.entries.where((entry) => entry.level == LogLevel.error),
      isEmpty,
    );
    expect(linked.needsQuery, isTrue);
    alarms.last.fire();
    final done = await running;
    expect(done.finished, isTrue);
    expect(done.sold, sold);
    expect(done.spent, proceeds);
    expect(api.reads.where((r) => !r.buy).map((r) => r.hashes.single), [
      original,
      original,
      original,
    ]);
    expect(backend.bundles, hasLength(2));
    expect(alarms.where((t) => t.isActive), isEmpty);
  });

  test('reports after three silent retries, caps at 30 minutes, then settles exactly once on manual/automatic overlap', () async {
    api.failures = 99;
    final running = linked.run(plan);
    await failFirstThree();
    final progress = await running;
    expect(linked.running, isFalse);
    expect(linked.reconciliationWarning, isTrue);
    expect(progress.stopped, isTrue);
    expect(linked.error, contains('3 次'));
    await expectLater(linked.run(plan), throwsStateError);
    expect(linked.finish, throwsStateError);
    for (final seconds in [8, 16, 32, 64, 128, 256, 512, 1024, 1800, 1800]) {
      expect(alarms.last.delay.inSeconds, seconds);
      final count = alarms.length;
      alarms.last.fire();
      await until(() => alarms.length > count);
    }
    expect(log.entries.where((e) => e.text.contains('3 次重试失败')), hasLength(1));
    expect(backend.bundles, hasLength(1));

    final reads = api.reads.length;
    api.failures = 0;
    api.gate = Completer();
    final manual = linked.query(plan);
    final secondClick = linked.query(plan);
    alarms.last.fire(); // Same original hash is already in flight.
    expect(api.reads, hasLength(reads + 1));
    api.gate!.complete();
    await Future.wait([manual, secondClick]);
    expect(progress.sold, sold);
    expect(progress.received, proceeds);
    expect(progress.buyRemaining, proceeds);
    expect(linked.needsQuery, isFalse);
    expect(linked.error, isNull);
    expect(backend.bundles, hasLength(1));
    expect((await linked.run(plan)).finished, isTrue);
    expect(backend.bundles, hasLength(2));
  });

  test('recovery of a confirmed buy never buys again, and manual failures leave the automatic deadline intact', () async {
    api.failBuy = true;
    api.failures = 9;
    final running = linked.run(plan);
    await failFirstThree();
    final progress = await running;
    expect(progress.phase, 'buy');
    final scheduled = alarms.last;
    await linked.query(plan);
    expect(alarms.last, same(scheduled));
    expect(scheduled.isActive, isTrue);
    api.failures = 0;
    scheduled.fire();
    await until(() => !linked.reconciling);
    expect(progress.spent, proceeds);
    expect(progress.buyRemaining, BigInt.zero);
    expect((await linked.run(plan)).finished, isTrue);
    expect(backend.bundles, hasLength(2));
  });

  test('explicit stop during silent recovery returns promptly but keeps reading the original sale', () async {
    api.failures = 1;
    final running = linked.run(plan);
    await until(() => alarms.isNotEmpty);
    linked.cancel();
    final p = await running;
    expect(p.stopped, isTrue);
    expect(linked.needsQuery, isTrue);
    alarms.last.fire();
    await until(() => !linked.needsQuery);
    expect(p.buyRemaining, proceeds);
    expect(backend.bundles, hasLength(1));
  });
  test(
    'disposal during a receipt read clears the timer and ignores late results',
    () async {
      api.failures = 1;
      final running = linked.run(plan);
      await until(() => alarms.isNotEmpty);
      api.gate = Completer();
      final lookup = linked.query(plan);
      linked.dispose();
      disposed = true;
      expect(alarms.single.isActive, isFalse);
      api.gate!.complete();
      await lookup;
      final p = await running;
      expect(p.received, BigInt.zero);
      expect(backend.bundles, hasLength(1));
      expect(alarms, hasLength(1));
    },
  );
}
