import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  final alice = TradeWallet.import('A', '1'.padLeft(64, '0'));
  final bob = TradeWallet.import('B', '2'.padLeft(64, '0'));
  final start = BigInt.from(1000000);
  late FakeBackend fake;
  late BackendClient api;
  Map<String, Object> row(BigInt cash) => {
    'native': '$cash',
    'nonce': 0,
    'tokenBalance': '1500',
    'routerAllowance': '1200',
  };
  setUp(() {
    fake = FakeBackend();
    for (final w in [alice, bob]) {
      fake.wallets[w.address.toLowerCase()] = row(start);
    }
    api = fake.api();
  });
  int stateReads() => fake.calls.where((c) => c == 'wallets/state').length;
  Future<WalletState> wallet(TradeWallet w, {String? spender}) async =>
      (await api.walletStates(
        [w.address],
        token: token,
        spender: spender,
      )).single;
  SignedTx sign({
    required String to,
    required int nonce,
    int amount = 0,
    Uint8List? data,
  }) => api.sign(
    alice,
    LegacyTx(
      nonce: nonce,
      gasPrice: BigInt.one,
      gasLimit: 60000,
      to: to,
      value: BigInt.from(amount),
      data: data ?? Uint8List(0),
    ),
  );
  Matcher code(String text) =>
      throwsA(isA<BackendException>().having((e) => e.code, 'code', text));

  test('cold reads batch by asset; overlapping callers share one request and manual refresh replaces the snapshot', () async {
    for (final n in [1, 30, 100, 300]) {
      final f = FakeBackend(), a = f.api();
      final ws = [
        for (var i = 0; i < n; i++)
          '0x${(1000 + i).toRadixString(16).padLeft(40, '0')}',
      ];
      for (final w in ws) {
        f.wallets[w] = row(start);
      }
      final requests = await Future.wait([
        a.walletStates(ws, token: token),
        a.walletStates(ws.reversed.toList(), token: token),
      ]);
      expect(requests.first.map((s) => s.wallet), ws);
      expect(requests.last.map((s) => s.wallet), ws.reversed);
      expect(f.calls, ['config', 'wallets/state']);
      final warm = Stopwatch()..start();
      final old = await a.transferWalletStates(ws, token: token);
      expect(old.length, n);
      expect(f.calls, ['config', 'wallets/state']);
      expect(warm.elapsed, lessThan(const Duration(seconds: 2)));
      f.wallets[ws.first]!['native'] = '7';
      expect((await a.walletStates([ws.first])).single.native, start);
      await a.refreshKnownWallets();
      expect(
        (await a.walletStates([ws.first], token: token)).single.native,
        BigInt.from(7),
      );
    }
  });

  test('changing the UXUY approval spender discards the obsolete allowance view', () async {
    final previous = await api.config();
    expect((await wallet(alice)).routerAllowance, BigInt.from(1200));
    fake.activeSpender = bob.address;
    await api.config();
    fake.wallets[alice.address.toLowerCase()]!['routerAllowance'] = '0';
    expect((await wallet(alice)).routerAllowance, BigInt.zero);
    expect((await wallet(alice, spender: previous.approvalSpender)).routerAllowance, BigInt.from(1200));
    expect(stateReads(), 2);
  });

  test('manual transfer refresh batches balances without opening allowance views', () async {
    final requests = <Map<String, dynamic>>[];
    final transport = fake.client();
    final a = BackendClient(
      Uri.parse('http://backend.test/'),
      MockClient((r) {
        if (r.url.path.endsWith('wallets/state')) {
          requests.add(jsonDecode(r.body) as Map<String, dynamic>);
        }
        return transport.post(r.url, headers: r.headers, body: r.body);
      }),
    );
    final addresses = [alice.address, bob.address];
    final first = await a.transferWalletStates(addresses, token: token, refresh: true);
    expect(first.first.tokenBalance, BigInt.from(1500));
    fake.wallets[alice.address.toLowerCase()]!
      ..['tokenBalance'] = '790'
      ..['native'] = '2222'
      ..['nonce'] = 5;
    final warm = await a.transferWalletStates(addresses, token: token);
    expect(warm.first.tokenBalance, first.first.tokenBalance);
    final fresh = await a.transferWalletStates(addresses, token: token, refresh: true);
    expect(fresh.first.tokenBalance, BigInt.from(790));
    expect(fresh.first.native, BigInt.from(2222));
    expect(fresh.first.nonce, 5);
    expect((await a.walletStates([alice.address])).single.nonce, 5);
    expect(requests, hasLength(2));
    for (final req in requests) {
      expect(req['skipAllowance'], isTrue);
      expect(req['wallets'], hasLength(2));
    }

    await a.walletStates([alice.address], token: token, spender: bob.address);
    fake.wallets[alice.address.toLowerCase()]!['routerAllowance'] = '99';
    await a.transferWalletStates([alice.address], token: token, refresh: true);
    final allowance = await a.walletStates([alice.address], token: token, spender: bob.address);
    expect(allowance.single.routerAllowance, BigInt.from(99));
  });

  test('pending native send locks sender and recipient; confirmed transfer applies net gas, receiver and nonce exactly once', () async {
    await api.walletStates([alice.address, bob.address], token: token);
    final tx = sign(to: bob.address, nonce: 0, amount: 2700);
    fake.receipt = 'pending';
    await api.bundle([tx.raw], 1020);
    await expectLater(wallet(alice), code('WALLET_PENDING'));
    await expectLater(
      api.transferWalletStates([bob.address], token: token, refresh: true),
      code('WALLET_PENDING'),
    );
    await expectLater(
      api.refreshWalletStates([bob.address]),
      code('WALLET_PENDING'),
    );
    await expectLater(api.bundle([tx.raw], 1020), code('WALLET_BUSY'));
    expect(fake.bundles, hasLength(1));
    expect(stateReads(), 1);
    fake.receipt = 'confirmed';
    await api.status(tx.hash);
    await api.status(tx.hash);
    expect((await wallet(alice)).native, start - BigInt.from(23700));
    expect((await wallet(alice)).nonce, 1);
    expect((await wallet(bob)).native, start + BigInt.from(2700));
    expect(stateReads(), 1);
  });

  test('revert charges actual gas and nonce, exclusion changes neither; no duplicate debit', () async {
    await wallet(alice);
    var tx = sign(to: bob.address, nonce: 0, amount: 80);
    fake.receipt = 'not_included';
    await api.bundle([tx.raw], 1020);
    await api.status(tx.hash);
    expect((await wallet(alice)).nonce, 0);
    fake.receipt = 'reverted';
    tx = sign(to: bob.address, nonce: 0, amount: 81);
    await api.bundle([tx.raw], 1020);
    await api.status(tx.hash);
    expect((await wallet(alice)).native, start - BigInt.from(21000));
    expect((await wallet(alice)).nonce, 1);
    expect(stateReads(), 1);
  });

  test('approve first, then sell: later receipt may arrive first; allowance is a lower bound for its spender and native output is already net', () async {
    fake.applyApproval = false; // This test sets the final post-swap ledger explicitly.
    await api.config();
    await wallet(alice);
    await wallet(alice, spender: bob.address);
    final approval = sign(
      to: token,
      nonce: 0,
      data: erc20Approve(router, BigInt.from(4000)),
    );
    final sell = sign(to: router, nonce: 1, data: hexToBytes('0xabcdef01'));
    fake.onBundle = (_) {
      final w = fake.wallets[alice.address.toLowerCase()]!;
      w['native'] = '963000';
      w['nonce'] = 2;
      w['routerAllowance'] = '3700';
      w['tokenBalance'] = '1200';
    };
    await api.bundle([approval.raw, sell.raw], 1020);
    await api.status(sell.hash);
    final sold = await wallet(alice);
    expect(sold.nonce, 2);
    expect(sold.native, start + BigInt.from(5000 - 42000));
    expect(sold.tokenBalance, BigInt.from(1200));
    expect(sold.routerAllowance, BigInt.from(3700));
    fake.wallets[alice.address.toLowerCase()]!['routerAllowance'] = '1200';
    expect((await wallet(alice, spender: bob.address)).routerAllowance, BigInt.from(1200));
    expect(stateReads(), 4);
  });

  test('unverifiable confirmed settlement requests manual refresh and never uses a quoted or zero amount', () async {
    await wallet(alice);
    final tx = sign(to: token, nonce: 0, data: hexToBytes('0xabcdef01'));
    await api.bundle([tx.raw], 1020);
    fake.chainReceipts.remove(tx.hash);
    await api.status(tx.hash);
    await expectLater(wallet(alice), code('WALLET_REFRESH_REQUIRED'));
    expect(stateReads(), 1);
    fake.wallets[alice.address.toLowerCase()]!['native'] = '700001';
    final result = await api.refreshWalletStates([alice.address], token: token);
    expect(result.single.native, BigInt.from(700001));
    expect((await wallet(alice)).native, result.single.native);
    expect(stateReads(), 2);
  });

  test('refresh in flight cannot race a send; incompletely returned RPC batch is not evidence of absence', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final f = FakeBackend(), inner = f.client();
    f.wallets[alice.address.toLowerCase()] = row(start);
    var delay = false;
    final a = BackendClient(
      Uri.parse('http://backend.test/'),
      MockClient((r) async {
        if (r.url.path.endsWith('rpc/bsc')) return http.Response('[]', 200);
        if (delay && r.url.path.endsWith('wallets/state')) {
          entered.complete();
          await release.future;
        }
        return inner.post(r.url, headers: r.headers, body: r.body);
      }),
    );
    await a.walletStates([alice.address], token: token);
    final tx = a.sign(
      alice,
      LegacyTx(
        nonce: 0,
        gasPrice: BigInt.one,
        gasLimit: 21000,
        to: bob.address,
        value: BigInt.one,
        data: Uint8List(0),
      ),
    );
    delay = true;
    final refreshing = a.refreshKnownWallets();
    await entered.future;
    await expectLater(a.bundle([tx.raw], 1020), code('WALLET_BUSY'));
    release.complete();
    await refreshing;
    expect(f.bundles, isEmpty);
    await expectLater(
      a.rpc([
        ('eth_getTransactionReceipt', [tx.hash]),
      ]),
      code('BAD_RESPONSE'),
    );
  });

  test('loss of backend record unlocks the original action only with a receipt or proof of bundle expiry', () async {
    var height = 1020, proofs = 0;
    final a = BackendClient(
      Uri.parse('http://backend.test/'),
      MockClient((r) async {
        final path = r.url.path;
        final Object result;
        if (path.endsWith('wallets/state')) {
          result = {
            'ok': true,
            'wallets': [
              {'wallet': alice.address, ...row(start)},
            ],
          };
        } else if (path.endsWith('bundles')) {
          throw const FormatException('simulated response loss');
        } else if (path.endsWith('rpc/bsc')) {
          proofs++;
          result = [
            {'id': 0, 'result': '0x${height.toRadixString(16)}'},
            {'id': 1, 'result': null},
          ];
        } else {
          result = {'ok': true, 'result': null};
        }
        return http.Response(jsonEncode(result), 200);
      }),
    );
    await a.walletStates([alice.address]);
    final tx = a.sign(
      alice,
      LegacyTx(
        nonce: 0,
        gasPrice: BigInt.one,
        gasLimit: 21000,
        to: bob.address,
        value: BigInt.one,
        data: Uint8List(0),
      ),
    );
    await expectLater(a.bundle([tx.raw], 1020), throwsFormatException);
    expect((await a.status(tx.hash)).status, 'ambiguous');
    expect((await a.status(tx.hash)).status, 'ambiguous');
    expect(proofs, 1);
    await expectLater(a.walletStates([alice.address]), code('WALLET_PENDING'));
    height = 1024;
    await a.refreshKnownWallets();
    expect((await a.status(tx.hash)).status, 'not_included');
    expect((await a.walletStates([alice.address])).single.nonce, 0);
    expect(proofs, 2);
  });

  test('a removed approval log keeps the original nonce pending until canonical evidence returns', () async {
    await api.config();
    await wallet(alice);
    final approval = sign(to: token, nonce: 0, data: erc20Approve(router, BigInt.from(3000)));
    await api.bundle([approval.raw], 1020);
    final log = (fake.chainReceipts[approval.hash]!['logs'] as List).first as Map;
    log['removed'] = true;
    expect((await api.status(approval.hash)).status, 'ambiguous');
    await expectLater(wallet(alice), code('WALLET_PENDING'));
    log['removed'] = false;
    expect((await api.reconcileStatus(approval.hash)).status, 'confirmed');
    expect((await wallet(alice)).routerAllowance, BigInt.from(3000));
    expect(fake.bundles, hasLength(1));
  });

  test('missing approval event requires manual reconciliation of that spender only', () async {
    fake.applyApproval = false; // Simulate a token that reports success without granting the allowance.
    await api.config();
    await wallet(alice);
    await wallet(alice, spender: bob.address);
    final approval = sign(
      to: token,
      nonce: 0,
      data: erc20Approve(router, BigInt.from(3000)),
    );
    await api.bundle([approval.raw], 1020);
    fake.chainReceipts[approval.hash]!['logs'] = [];
    await api.status(approval.hash);
    await expectLater(wallet(alice), code('WALLET_REFRESH_REQUIRED'));
    expect((await wallet(alice, spender: bob.address)).routerAllowance, BigInt.from(1200));
    expect(stateReads(), 2);
    await api.refreshWalletStates([alice.address], token: token);
    expect((await wallet(alice)).routerAllowance, BigInt.from(1200));
  });

  test('old schema fallback only retries an explicit read-only unknown-field 422, then remembers it', () async {
    final requests = <Map<String, dynamic>>[];
    final a = BackendClient(
      Uri.parse('http://backend.test/'),
      MockClient((r) async {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        requests.add(body);
        if (body['skipAllowance'] == true)
          return http.Response(
            'unknown field `skipAllowance`, expected wallets',
            422,
          );
        return http.Response(
          jsonEncode({
            'ok': true,
            'wallets': [
              for (final w in body['wallets']) {'wallet': w, ...row(start)},
            ],
          }),
          200,
        );
      }),
    );
    await a.transferWalletStates([alice.address], token: token);
    await a.transferWalletStates([bob.address], token: token);
    expect(requests.map((r) => r['skipAllowance']), [true, null, null]);
  });
}
