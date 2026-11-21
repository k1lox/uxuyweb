import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

TradeWallet key(int i) => TradeWallet.import(
  'K$i',
  '0x${(i + 100).toRadixString(16).padLeft(64, '0')}',
);

/// Port of the web wallet-tools transfer rules (transfers.ts / transferAmounts.ts / transferLanes.ts).
void main() {
  late FakeBackend backend;
  late TransferEngine engine;
  final e18 = BigInt.from(10).pow(18);
  const tokenAddr = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';
  final asset = TransferAsset(checksumAddress(tokenAddr), 'Cake', 18);

  void put(TradeWallet w, {BigInt? native, BigInt? token, int nonce = 0}) =>
      backend.wallets[w.address.toLowerCase()] = {
        'native': '${native ?? e18}',
        'nonce': nonce,
        'tokenBalance': '${token ?? BigInt.zero}',
        'routerAllowance': '0',
      };

  setUp(() {
    backend = FakeBackend();
    engine = TransferEngine(
      backend.api(),
      ExecutionLog(),
      sleep: (_) async {},
    );
  });

  test('collection warmup reads without signing and a changed balance requires a new review', () async {
    final source = key(1), recipient = key(2);
    put(source, native: e18);
    final review = await engine.prepareCollection([source], recipient.address, TransferAsset.bnb, checkPreview: () {});
    expect(engine.current, isNull);
    expect(backend.bundles, isEmpty);
    expect(review.legs.every((l) => l.raw == null), isTrue);
    final unchanged = await engine.prepareCollection([source], recipient.address, TransferAsset.bnb);
    expect(review.covers(unchanged), isTrue);
    put(source, native: e18 ~/ BigInt.two);
    final changed = await engine.prepareCollection([source], recipient.address, TransferAsset.bnb);
    expect(review.covers(changed), isFalse);
    expect(backend.bundles, isEmpty);
  });
  test('distribution preview can stop its reads without entering execution', () async {
    final source = key(1), destination = key(2);
    put(source);
    final rows = engine.drawOneToMany(source, [destination.address], BigInt.one, BigInt.one);
    await expectLater(engine.prepareDistribution(rows, TransferAsset.bnb, source:source,
        checkPreview: () => throw StateError('draft changed')), throwsA(anything));
    expect(engine.current,isNull);
    expect(backend.bundles,isEmpty);
  });
  test('recipients: split, checksum, zero refused, duplicates refused only when paired', () {
    final a = key(1).address, b = key(2).address;
    expect(parseRecipients('$a, ${b.toLowerCase()}；$a'), [a, b]);
    expect(
      () => parseRecipients('$a\n$a', rejectDuplicates: true),
      throwsFormatException,
    );
    expect(() => parseRecipients('0x${'0' * 40}'), throwsFormatException);
    expect(() => parseRecipients('0x123'), throwsFormatException);
  });

  test(
    'lanes: a relay shares its funder lane; unrelated senders are independent',
    () {
      final s1 = key(1), s2 = key(2), relay = key(3);
      TransferLeg leg(TradeWallet from, String to) => TransferLeg(
        row: 0,
        from: from,
        recipient: to,
        to: to,
        data: Uint8List(0),
        value: BigInt.one,
        amount: BigInt.one,
        gasLimit: 21000,
      );
      final lanes = transferLanes([
        leg(s1, relay.address),
        leg(relay, key(9).address),
        leg(s2, key(8).address),
      ]);
      expect(lanes, hasLength(2));
      expect(lanes.first, hasLength(2));
    },
  );

  test('one-to-many BNB in one bundle: exact amounts, sequential nonces, 21000 gas', () async {
    final src = key(1);
    put(src, nonce: 7);
    final to = [key(2).address, key(3).address];
    final rows = engine.drawOneToMany(
      src,
      to,
      BigInt.from(1000),
      BigInt.from(1000),
    );
    final run = await engine.prepareDistribution(
      rows,
      TransferAsset.bnb,
      source: src,
    );
    await engine.execute(run);
    expect(run.complete, isTrue);
    expect(backend.bundles.single, [
      src
          .sign(
            LegacyTx(
              nonce: 7,
              gasPrice: gasPrice,
              gasLimit: 21000,
              to: to[0],
              value: BigInt.from(1000),
              data: Uint8List(0),
            ),
          )
          .raw,
      src
          .sign(
            LegacyTx(
              nonce: 8,
              gasPrice: gasPrice,
              gasLimit: 21000,
              to: to[1],
              value: BigInt.from(1000),
              data: Uint8List(0),
            ),
          )
          .raw,
    ]);
  });

  test('BNB relay: sender pays amount plus the forward gas to the relay; relay forwards the amount', () async {
    final src = key(1),
        relay = TradeWallet.import('R', '0x${'77'.padLeft(64, '0')}');
    put(src, nonce: 1);
    put(relay);
    final r = key(2).address;
    final rows = engine.drawOneToMany(
      src,
      [r],
      BigInt.from(5000),
      BigInt.from(5000),
      transits: {r.toLowerCase(): relay},
    );
    final run = await engine.prepareDistribution(
      rows,
      TransferAsset.bnb,
      source: src,
    );
    expect(run.legs.map((l) => (l.from.address, l.recipient, l.value)), [
      (
        src.address,
        relay.address,
        BigInt.from(5000) + BigInt.from(21000) * gasPrice,
      ),
      (relay.address, r, BigInt.from(5000)),
    ]);
    await engine.execute(run);
    expect(run.complete, isTrue);
  });

  test('token relay: gas leg, token leg, then a forward capped to what the relay received', () async {
    final src = key(1),
        relay = TradeWallet.import('R', '0x${'78'.padLeft(64, '0')}');
    put(src, token: BigInt.from(1000000));
    put(relay, native: BigInt.zero);
    final r = key(2).address;
    backend.onBundle = (raws) {
      if (backend.bundles.length == 1) {
        put(
          relay,
          native: e18,
          token: BigInt.from(9500),
        ); // 5% transfer tax on arrival
      }
    };
    final rows = engine.drawOneToMany(
      src,
      [r],
      BigInt.from(10000),
      BigInt.from(10000),
      transits: {r.toLowerCase(): relay},
    );
    final run = await engine.prepareDistribution(rows, asset, source: src);
    expect(run.legs.map((l) => l.capToBalance), [false, false, true]);
    expect(
      run.legs.first.value,
      BigInt.from(120000) * gasPrice,
      reason: 'relay forwarding floor',
    );
    await engine.execute(run);
    expect(
      backend.bundles,
      hasLength(2),
      reason: 'forward is sent after the relay is funded',
    );
    expect(run.legs.last.amount, BigInt.from(9500));
    expect(run.complete, isTrue);
  });

  test(
    'unbacked generated recipients and unbacked relays cannot receive funds',
    () async {
      final src = key(1);
      put(src);
      final fresh = TradeWallet.generate('N');
      final rows = engine.drawOneToMany(
        src,
        [fresh.address],
        BigInt.one,
        BigInt.one,
      );
      await expectLater(
        engine.prepareDistribution(
          rows,
          TransferAsset.bnb,
          source: src,
          unbacked: {fresh.address.toLowerCase()},
        ),
        throwsStateError,
      );
      final r = key(5).address;
      final relayRows = engine.drawOneToMany(
        src,
        [r],
        BigInt.one,
        BigInt.one,
        transits: {r.toLowerCase(): TradeWallet.generate('T')},
      );
      await expectLater(
        engine.prepareDistribution(relayRows, TransferAsset.bnb, source: src),
        throwsStateError,
      );
    },
  );

  test('sender must cover amounts and every network fee', () async {
    final src = key(1);
    put(src, native: BigInt.from(1000));
    final rows = engine.drawOneToMany(
      src,
      [key(2).address],
      BigInt.from(500),
      BigInt.from(500),
    );
    await expectLater(
      engine.prepareDistribution(rows, TransferAsset.bnb, source: src),
      throwsA(
        isA<StateError>().having((e) => e.message, 'm', contains('BNB 不足')),
      ),
    );
  });

  test(
    'many-to-many: counts must match; 100% keeps the transfer gas back',
    () async {
      final senders = [key(1), key(2)];
      for (final s in senders) {
        put(s, native: e18);
      }
      final to = [key(3).address, key(4).address];
      await expectLater(
        engine.drawPaired(
          senders,
          [to.first],
          TransferAsset.bnb,
          ratio: true,
          min: BigInt.from(10000),
          max: BigInt.from(10000),
        ),
        throwsStateError,
      );
      final rows = await engine.drawPaired(
        senders,
        to,
        TransferAsset.bnb,
        ratio: true,
        min: BigInt.from(10000),
        max: BigInt.from(10000),
      );
      expect(
        rows.map((r) => r.amount),
        everyElement(e18 - BigInt.from(21000) * gasPrice),
      );
      expect(rows.map((r) => r.sender), senders);
      final run = await engine.prepareDistribution(
        rows,
        TransferAsset.bnb,
        source: senders.first,
        intervalMin: 1,
        intervalMax: 1,
      );
      expect(run.label, '多对多分发');
      await engine.execute(run);
      expect(
        backend.bundles,
        hasLength(2),
        reason:
            'interval mode: one private bundle per transfer, independent lanes',
      );
      expect(run.complete, isTrue);
    },
  );

  test('not included: the same signed transfer is resubmitted, never re-signed; retry keeps the signature', () async {
    final src = key(1);
    put(src);
    backend.onBundle = (_) { if (backend.bundles.length == 3) engine.stop(); };
    backend.receipts.addAll(['not_included', 'not_included', 'not_included']);
    final rows = engine.drawOneToMany(
      src,
      [key(2).address],
      BigInt.from(10),
      BigInt.from(10),
    );
    final run = await engine.prepareDistribution(
      rows,
      TransferAsset.bnb,
      source: src,
    );
    await engine.execute(run);
    expect(run.statusOf(0), TransferStatus.notIncluded);
    expect(backend.bundles, hasLength(3));
    expect(
      backend.bundles.map((b) => b.single).toSet(),
      hasLength(1),
      reason: 'identical raw transaction each time',
    );
    await engine.execute(run);
    expect(run.complete, isTrue);
    expect(backend.bundles.map((b) => b.single).toSet(), hasLength(1));
  });

  test('resuming a split distribution reuses the original bundle and advances its nonce', () async {
    final sender = key(1);
    put(sender, nonce: 5);
    final recipients = [
      for (var i = 0; i < 104; i++)
        '0x${(10000 + i).toRadixString(16).padLeft(40, '0')}',
    ];
    final rows = engine.drawOneToMany(
      sender, recipients, BigInt.one, BigInt.one,
    );
    final run = await engine.prepareDistribution(
      rows, TransferAsset.bnb, source: sender,
    );
    final beforeSubmit = backend.onBundle;
    backend.onBundle = (raws) { beforeSubmit?.call(raws); if (backend.bundles.length == 3) engine.stop(); };
    backend.receipts.addAll(List.filled(3, 'not_included'));
    await engine.execute(run);

    final original = backend.bundles.first;
    expect(original, hasLength(103));
    expect(backend.bundles, [original, original, original]);
    expect(run.legs.last.raw, isNull);

    await engine.execute(run);
    expect(run.complete, isTrue);
    expect(run.legs.map((leg) => leg.nonce), List.generate(104, (i) => 5 + i));
    expect(backend.bundles.skip(3), [original, [run.legs.last.raw]]);
  });

  test('resuming a relay gas payment uses the next nonce for its token transfer', () async {
    final sender = key(1), relay = key(2), target = key(3).address;
    final amount = BigInt.from(1000);
    put(sender, nonce: 5, token: amount);
    put(relay, nonce: 2, native: BigInt.zero);
    final rows = engine.drawOneToMany(
      sender, [target], amount, amount,
      transits: {target.toLowerCase(): relay},
    );
    final run = await engine.prepareDistribution(
      rows, asset, source: sender, intervalMin: 1, intervalMax: 1,
    );
    final gasLeg = run.legs[0], tokenLeg = run.legs[1], forward = run.legs[2];
    backend.onBundle = (raws) {
      if (raws.contains(tokenLeg.raw)) {
        put(relay, nonce: 2, native: gasLeg.value, token: amount);
      }
    };
    final beforeSubmit = backend.onBundle;
    backend.onBundle = (raws) { beforeSubmit?.call(raws); if (backend.bundles.length == 3) engine.stop(); };
    backend.receipts.addAll(List.filled(3, 'not_included'));
    await engine.execute(run);
    final original = gasLeg.raw!;
    expect(backend.bundles, List.filled(3, [original]));
    expect(tokenLeg.raw, isNull);
    expect(forward.raw, isNull);

    await engine.execute(run);
    expect(run.complete, isTrue);
    expect([gasLeg.nonce, tokenLeg.nonce, forward.nonce], [5, 6, 2]);
    expect(backend.bundles.skip(3), [[original], [tokenLeg.raw], [forward.raw]]);
  });

  test(
    'unknown status blocks a retry until the original transfer is queried',
    () async {
      final src = key(1);
      put(src);
      backend.receipts.add('pending');
      final rows = engine.drawOneToMany(
        src,
        [key(2).address],
        BigInt.from(10),
        BigInt.from(10),
      );
      final run = await engine.prepareDistribution(
        rows,
        TransferAsset.bnb,
        source: src,
      );
      await engine.execute(run);
      expect(run.hasUnknown, isTrue);
      await expectLater(engine.execute(run), throwsStateError);
      backend.bundleStatus = 'confirmed';
      await engine.query();
      expect(run.complete, isTrue);
      expect(backend.bundles, hasLength(1));
    },
  );

  test('older collection can be queried while another wallet is sending', () async {
    final waiting = Completer<void>();
    final resume = Completer<void>();
    var holdNextPoll = false;
    engine = TransferEngine(backend.api(), ExecutionLog(), sleep: (_) async {
      if (!holdNextPoll) return;
      if (!waiting.isCompleted) waiting.complete();
      await resume.future;
    });
    final a = key(1), b = key(2);
    put(a);
    put(b);
    final first = await engine.prepareCollection([a], key(3).address, TransferAsset.bnb);
    final second = await engine.prepareCollection([b], key(4).address, TransferAsset.bnb);
    backend.receipts.addAll(['pending', 'pending']);
    await engine.execute(first);
    expect(first.hasUnknown, isTrue);
    expect(() => engine.finish(first), throwsStateError);
    holdNextPoll = true;
    final sending = engine.execute(second);
    await waiting.future;
    try {
      expect(engine.current, same(second));
      expect(engine.retainedRuns, [first]);
      expect(engine.unresolvedRuns, contains(first));
      final before = backend.calls.length;
      await engine.query(first);
      expect(first.hasUnknown, isTrue);
      backend.bundleStatus = 'confirmed';
      await Future.wait([engine.query(first), engine.query(first)]);
      expect(backend.calls.skip(before), [
        'transactions/bsc/${first.legs.single.hash}',
        'transactions/bsc/${first.legs.single.hash}',
      ]);
      expect(first.complete, isTrue);
      expect(engine.running, isTrue);
      expect(engine.unresolvedRuns, isNot(contains(first)));
      engine.finish(first);
      expect(engine.current, same(second));
      expect(engine.retainedRuns, isEmpty);
    } finally {
      resume.complete();
      await sending;
    }
    expect(second.complete, isTrue);
    expect(backend.bundles, hasLength(2));
  });

  test('a lost transfer response recovers a recorded original without a duplicate submit', () async {
    final sender = key(1);
    put(sender);
    final transport = backend.client();
    final windows = <int>[];
    final client = MockClient((req) async {
      final copy = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes;
      final response = await http.Response.fromStream(await transport.send(copy));
      if (req.url.path.endsWith('/bundles')) {
        windows.add((jsonDecode(req.body) as Map)['maxBlockNumber'] as int);
        throw http.ClientException('lost reply after acceptance');
      }
      return response;
    });
    addTearDown(client.close);
    addTearDown(transport.close);
    final checker = TransferEngine(
      BackendClient(Uri.parse('http://isolated.test/'), client),
      ExecutionLog(), pollEvery: Duration.zero,
    );
    addTearDown(checker.dispose);
    final run = await checker.prepareCollection([sender], key(3).address, TransferAsset.bnb);
    await checker.execute(run);
    expect(windows, [1040]);
    expect(backend.bundles.single.single, run.legs.single.raw);
    expect(run.complete, isTrue);
  });

  test('one receipt read failure preserves both the original hash and sibling results', () async {
    final sources = [key(1), key(2)];
    for (final wallet in sources) {
      put(wallet);
    }
    final run = await engine.prepareCollection(sources, key(3).address, TransferAsset.bnb);
    final hashes = ['0x${'aa' * 32}', '0x${'bb' * 32}'];
    for (var i = 0; i < hashes.length; i++) {
      run.legs[i]
        ..hash = hashes[i]
        ..status = TransferStatus.unknown;
    }
    final reads = <String>[];
    var offline = true;
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.queryParameters['tracked'], 'false');
      final hash = request.url.pathSegments.last;
      reads.add(hash);
      if (offline && hash == hashes.first) throw http.ClientException('offline');
      return http.Response(jsonEncode({
        'ok': true,
        'result': {
          'transactionHash': hash,
          'status': hash == hashes.first ? 'reverted' : 'confirmed',
        },
      }), 200);
    });
    final checker = TransferEngine(
      BackendClient(Uri.parse('http://isolated.test/'), client),
      ExecutionLog(),
    )..current = run;
    await expectLater(checker.query(run), throwsA(isA<http.ClientException>()));
    expect(reads, unorderedEquals(hashes));
    expect(checker.unresolvedRuns, [run]);
    expect(run.legs.first.status, TransferStatus.unknown);
    expect(run.legs.last.status, TransferStatus.confirmed);
    reads.clear();
    offline = false;
    await checker.query(run);
    expect(reads, [hashes.first]);
    expect(run.legs.first.status, TransferStatus.failed);
    expect(checker.unresolvedRuns, isEmpty);
    expect(backend.bundles, isEmpty);
  });

  test(
    'collect BNB: balance minus gas from each wallet; token: whole balance',
    () async {
      final a = key(1), b = key(2);
      put(a, native: BigInt.from(10).pow(15), nonce: 9);
      put(b, native: BigInt.zero);
      final target = key(9).address;
      final run = await engine.prepareCollection(
        [a, b],
        target,
        TransferAsset.bnb,
      );
      expect(run.rows, hasLength(1), reason: 'empty wallet skipped');
      await engine.execute(run);
      expect(
        backend.bundles.single.single,
        a
            .sign(
              LegacyTx(
                nonce: 9,
                gasPrice: gasPrice,
                gasLimit: 21000,
                to: target,
                value: BigInt.from(10).pow(15) - BigInt.from(21000) * gasPrice,
                data: Uint8List(0),
              ),
            )
            .raw,
      );
      put(a, token: BigInt.from(777));
      final tokenRun = await engine.prepareCollection([a], target, asset);
      expect(tokenRun.legs.single.amount, BigInt.from(777));
      expect(
        tokenRun.legs.single.gasLimit,
        60000,
        reason: 'estimate 50000 + 20%',
      );
    },
  );
}
