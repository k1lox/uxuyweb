import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

class LostRelay extends FakeBackend {
  LostRelay({this.mined = false});
  final bool mined;
  var failures = 1, head = 1030;
  String? tracked, refreshed, pendingHash;
  int? previousWindow;
  bool expiredRoute = false;
  var consumedNonce = false;
  void Function()? afterChecks;
  http.Response Function(String)? claimOverride;
  final firstSend = Completer<void>();
  final payloads = <Map<String, dynamic>>[], sequence = <String>[];

  @override
  http.Client client() {
    final base = super.client();
    return MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/bundles')) {
        sequence.add('send');
        payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (!firstSend.isCompleted) firstSend.complete();
        if (expiredRoute && payloads.length > 1) {
          return http.Response(
            jsonEncode({
              'ok': false,
              'code': 'ACTION_NOT_ALLOWED',
              'message': 'expired quote',
              'notSubmitted': true,
              'retryable': false,
            }),
            403,
          );
        }
        if (payloads.length <= failures) {
          if (mined) {
            await base.post(
              request.url,
              headers: request.headers,
              body: request.body,
            );
          }
          throw TimeoutException('fixture lost acknowledgement');
        }
      } else if (path.endsWith('/rpc/bsc')) {
        final batch = jsonDecode(request.body) as List;
        final method = batch.first['method'];
        if (method == 'eth_getTransactionReceipt' ||
            method == 'eth_blockNumber') {
          sequence.add(method == 'eth_blockNumber' ? 'head' : 'receipts');
          if (method == 'eth_blockNumber' && batch.length == 1)
            afterChecks?.call();
          return http.Response(
            jsonEncode([
              for (final cmd in batch)
                {
                  'id': cmd['id'],
                  'result': switch (cmd['method']) {
                    'eth_blockNumber' => '0x${head.toRadixString(16)}',
                    'eth_getTransactionReceipt' =>
                      chainReceipts[cmd['params'][0]],
                    'eth_getTransactionByHash'
                        when cmd['params'][0] == pendingHash =>
                      {'hash': pendingHash},
                    _ => null,
                  },
                },
            ]),
            200,
          );
        }
        if (method == 'eth_getTransactionCount' &&
            batch.length >= 2 &&
            payloads.isNotEmpty) {
          sequence.add('nonce');
          if (consumedNonce) {
            return http.Response(
              jsonEncode([
                for (final cmd in batch) {'id': cmd['id'], 'result': '0xff'},
              ]),
              200,
            );
          }
        }
      } else if (path.contains('/transactions/') && bundles.isEmpty) {
        sequence.add('claim');
        final hash = request.url.pathSegments.last;
        if (claimOverride != null) return claimOverride!(hash);
        return http.Response(
          jsonEncode({
            'ok': true,
            'result': tracked == null
                ? null
                : {
                    'transactionHash': hash,
                    'status': request.url.queryParameters['tracked'] == 'false'
                        ? refreshed ?? tracked
                        : tracked,
                    if (previousWindow != null)
                      'maxBlockNumber': previousWindow,
                  },
          }),
          200,
        );
      }
      if (request.method == 'GET')
        return base.get(request.url, headers: request.headers);
      return base.post(
        request.url,
        headers: request.headers,
        body: request.body,
      );
    });
  }
}

LegacyTx transfer(int nonce) => LegacyTx(
  nonce: nonce,
  gasPrice: BigInt.one,
  gasLimit: 21000,
  to: token,
  value: BigInt.one,
  data: Uint8List(0),
);

void main() {
  for (final mode in [SendMode.interval, SendMode.bundle]) {
    for (final mined in [true, false]) {
      test(
        'ordinary $mode group recovers lost response (already mined: $mined)',
        () async {
          final relay = LostRelay(mined: mined)..head = 1060;
          final wallet = TradeWallet.import('test', '1'.padLeft(64, '0'));
          final engine = BatchTrader(
            relay.api(),
            ExecutionLog(),
            sleep: (_) async {},
          );
          addTearDown(engine.dispose);
          relay.wallets[wallet.address.toLowerCase()] = {
            'native': '1000000000000000000',
            'tokenBalance': '0',
            'nonce': 3,
            'routerAllowance': '0',
          };
          final out = await engine.run(
            TradePlan(
              token: token,
              buy: true,
              wallets: [wallet],
              mode: mode,
              amount: AmountRule(
                ratio: false,
                min: BigInt.from(10),
                max: BigInt.from(10),
              ),
            ),
          );
          expect(out.confirmed, 1);
          expect(out.stopped, isFalse);
          if (mined) {
            expect(relay.sequence, ['send', 'receipts']);
          } else {
            expect(relay.sequence, [
              'send',
              'receipts',
              'claim',
              'nonce',
              'head',
              'send',
            ]);
            expect(relay.payloads.first['maxBlockNumber'], 1040);
            expect(relay.payloads.last['maxBlockNumber'], relay.head + 40);
            expect(
              relay.payloads.last['transactions'],
              relay.payloads.first['transactions'],
            );
          }
          expect(relay.signatures, hasLength(1));
          expect(relay.bundles, hasLength(1));
        },
      );
    }
  }

  for (final scenario in [
    'accepted',
    'ambiguous',
    'pending-node',
    'consumed-nonce',
    'stop',
    'exhausted',
    'partial',
  ]) {
    test(
      'group recovery with $scenario preserves signed hashes and nonce claims',
      () async {
        final relay = LostRelay();
        final api = relay.api();
        addTearDown(api.http_.close);
        final wallet = TradeWallet.import('fixture', '2'.padLeft(64, '0'));
        final txs = [
          for (var nonce = 0; nonce < (scenario == 'partial' ? 2 : 1); nonce++)
            api.sign(wallet, transfer(nonce)),
        ];
        var active = true;
        relay.tracked = {'accepted', 'ambiguous'}.contains(scenario)
            ? scenario
            : null;
        relay.consumedNonce = scenario == 'consumed-nonce';
        if (scenario == 'pending-node') relay.pendingHash = txs.first.hash;
        if (scenario == 'stop') relay.afterChecks = () => active = false;
        if (scenario == 'exhausted') relay.failures = 3;
        if (scenario == 'partial') {
          relay.chainReceipts[txs.first.hash] = {
            'transactionHash': txs.first.hash,
            'status': '0x1',
            'blockNumber': '0x400',
          };
        }
        final result = api.groupBundle(
          txs.map((s) => s.raw).toList(),
          1020,
          active: () => active,
        );
        if (scenario == 'accepted') {
          expect((await result)['recovered'], isTrue);
        } else {
          await expectLater(
            result,
            throwsA(
              isA<BackendException>()
                  .having((e) => e.code, 'code', 'SUBMISSION_UNKNOWN')
                  .having(
                    (e) => e.notSubmitted,
                    'nonce remains uncertain',
                    false,
                  ),
            ),
          );
        }
        expect(relay.payloads.length, scenario == 'exhausted' ? 3 : 1);
        for (final payload in relay.payloads) {
          expect(payload['transactions'], txs.map((tx) => tx.raw).toList());
        }
        if (scenario == 'exhausted') {
          relay.head = 1040;
          expect(
            (await api.reconcileStatus(txs.single.hash)).status,
            'ambiguous',
          );
          relay.head = 1074;
          expect(
            (await api.reconcileStatus(txs.single.hash)).status,
            'not_included',
          );
        }
        if (scenario == 'pending-node') {
          relay.head = 1100;
          expect(
            (await api.reconcileStatus(txs.single.hash)).status,
            'ambiguous',
          );
        }
      },
    );
  }

  test('a lagging read cannot erase a previously seen claim after another read times out', () async {
    final relay = LostRelay();
    final api = relay.api();
    addTearDown(api.http_.close);
    final wallet = TradeWallet.import('fixture', '5'.padLeft(64, '0'));
    final txs = [api.sign(wallet, transfer(0)), api.sign(wallet, transfer(1))];
    final reads = <String, int>{};
    relay.claimOverride = (hash) {
      final n = reads.update(hash, (n) => n + 1, ifAbsent: () => 1);
      if (n == 1 && hash == txs.last.hash) throw TimeoutException('fixture');
      return http.Response(
        jsonEncode({
          'ok': true,
          'result': n == 1
              ? {'transactionHash': hash, 'status': 'accepted'}
              : null,
        }),
        200,
      );
    };
    await expectLater(
      api.groupBundle(
        txs.map((tx) => tx.raw).toList(),
        1020,
        active: () => true,
      ),
      throwsA(
        isA<BackendException>().having(
          (e) => e.code,
          'code',
          'SUBMISSION_UNKNOWN',
        ),
      ),
    );
    expect(relay.payloads, hasLength(1));
    expect(reads.values, everyElement(2));
  });

  for (final scenario in [
    'expired',
    'route-expired',
    'head-behind',
    'still-claimed',
  ]) {
    test(
      'an unresolved service nonce must first prove non-inclusion: $scenario',
      () async {
        final relay = LostRelay()
          ..tracked = 'ambiguous'
          ..refreshed = scenario == 'still-claimed'
              ? 'ambiguous'
              : 'not_included'
          ..previousWindow = 1020
          ..expiredRoute = scenario == 'route-expired';
        if (scenario == 'head-behind') relay.head = 1023;
        final api = relay.api();
        addTearDown(api.http_.close);
        final wallet = TradeWallet.import('fixture', '4'.padLeft(64, '0'));
        final tx = api.sign(wallet, transfer(0));
        final result = api.groupBundle([tx.raw], 1020, active: () => true);
        if (scenario == 'expired') {
          expect((await result)['bundleHash'], isNotNull);
        } else {
          await expectLater(
            result,
            throwsA(
              isA<BackendException>().having(
                (e) => e.code,
                'code',
                'SUBMISSION_UNKNOWN',
              ),
            ),
          );
        }
        final attempts = scenario == 'expired' || scenario == 'route-expired'
            ? 2
            : 1;
        expect(relay.payloads, hasLength(attempts));
        for (final p in relay.payloads) {
          expect(p['transactions'], [tx.raw]);
        }
        if (attempts == 2) expect(relay.payloads.last['maxBlockNumber'], 1070);
        if (scenario == 'route-expired') {
          expect((await api.reconcileStatus(tx.hash)).status, 'ambiguous');
          relay.head = 1074;
          expect((await api.reconcileStatus(tx.hash)).status, 'not_included');
        }
      },
    );
  }

  test(
    'manual query during recovery cannot release the original nonce',
    () async {
      final relay = LostRelay();
      final api = relay.api();
      addTearDown(api.http_.close);
      final wallet = TradeWallet.import('fixture', '3'.padLeft(64, '0'));
      final tx = api.sign(wallet, transfer(0));
      final submitting = api.groupBundle([tx.raw], 1000, active: () => true);
      await relay.firstSend.future;
      expect((await api.reconcileStatus(tx.hash)).status, 'ambiguous');
      await expectLater(
        api.bundle([tx.raw], 1100),
        throwsA(
          isA<BackendException>().having(
            (e) => e.code,
            'nonce lock',
            'WALLET_BUSY',
          ),
        ),
      );
      expect((await submitting)['bundleHash'], isNotNull);
      expect(relay.payloads, hasLength(2));
    },
  );
}
