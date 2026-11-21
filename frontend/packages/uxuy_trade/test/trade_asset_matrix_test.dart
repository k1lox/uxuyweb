import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

TradeWallet _wallet(int n) =>
    TradeWallet.import('fixture-$n', n.toRadixString(16).padLeft(64, '0'));

final _bnb = BigInt.from(10).pow(18);
final _swapNative = parseUnits('0.01', 18);

/// Synthetic assets have distinct addresses, metadata and token balances.
/// Only wallet signing and the application flows are real; no HTTP leaves the process.
class _AssetBackend extends FakeBackend {
  _AssetBackend(
    this.decimals, {
    this.taxReceiver,
    this.blockTransfer = false,
    this.knownPrecision = true,
  });
  final String? taxReceiver;
  final bool blockTransfer, knownPrecision;
  final int decimals;
  String get address =>
      '0x${(0xa000 + decimals).toRadixString(16).padLeft(40, '0')}';
  String get symbol => 'T$decimals';
  BigInt get lot =>
      BigInt.from(10).pow(decimals) * BigInt.from(13) + BigInt.one;

  void fund(TradeWallet w, BigInt balance, {BigInt? allowance}) {
    wallets[w.address.toLowerCase()] = {
      'native': '$_bnb',
      'nonce': 0,
      'tokenBalance': '$balance',
      'routerAllowance': '${allowance ?? BigInt.zero}',
    };
  }

  @override
  http.Client client() {
    final original = super.client();
    return MockClient((request) async {
      final path = request.url.path;
      if (path.contains('/tokens/') || path.endsWith('/platforms/bsc')) {
        final metadata = {
          'address': address,
          'token': address,
          'name': symbol,
          'symbol': symbol,
          'decimals': knownPrecision ? decimals : null,
          'platform': 'external',
          'external': true,
          'quote': zeroAddress,
          'block': 1000,
        };
        if (path.endsWith('/platforms/bsc')) {
          expect(jsonDecode(request.body)['token'], address);
        } else {
          expect(request.url.pathSegments.last.toLowerCase(), address);
        }
        return http.Response(
          jsonEncode({'ok': true, 'token': metadata, 'result': metadata}),
          200,
        );
      }
      if (blockTransfer && path.endsWith('/rpc/bsc')) {
        final calls = jsonDecode(request.body) as List;
        if (calls.every((c) => c['method'] == 'eth_estimateGas')) {
          return http.Response(
            jsonEncode([
              for (final call in calls)
                {
                  'jsonrpc': '2.0',
                  'id': call['id'],
                  'error': {
                    'code': -32000,
                    'message': 'token transfer is paused',
                  },
                },
            ]),
            200,
          );
        }
      }
      final outgoing = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      final result = await http.Response.fromStream(
        await original.send(outgoing),
      );
      if (path.endsWith('/bundles')) {
        // The shared fixture models one CAKE asset. Use the actual asset in
        // swap receipts as well, so the ledger has to match the correct token.
        for (final raw in bundles.last) {
          final (hash, owner, tx) = signatures[raw]!;
          final row = wallets[owner]!;
          row['nonce'] = tx.nonce + 1;
          row['native'] =
              (BigInt.parse('${row['native']}') -
                      BigInt.from(21000) * tx.gasPrice)
                  .toString();
          if (taxReceiver != null && tx.to?.toLowerCase() == address) {
            final logs =
                chainReceipts[hash]!['logs'] as List<Map<String, Object?>>;
            final log = logs.single;
            final topics = log['topics'] as List;
            final gross = BigInt.parse(log['data'] as String);
            final fee = gross * BigInt.from(5) ~/ BigInt.from(100);
            String word(BigInt value) =>
                '0x${value.toRadixString(16).padLeft(64, '0')}';
            log['data'] = word(gross - fee);
            logs.add({
              ...log,
              'topics': [
                topics[0],
                topics[1],
                '0x${taxReceiver!.toLowerCase().substring(2).padLeft(64, '0')}',
              ],
              'data': word(fee),
            });
          }
          if (tx.data.isEmpty && tx.to != null && wallets.containsKey(tx.to!.toLowerCase())) {
            final dest = wallets[tx.to!.toLowerCase()]!;
            row['native'] = (BigInt.parse('${row['native']}') - tx.value).toString();
            dest['native'] = (BigInt.parse('${dest['native']}') + tx.value).toString();
          }
          if (tx.to?.toLowerCase() == address && bytesToHex(tx.data).startsWith('0xa9059cbb')) {
            for (final event in chainReceipts[hash]!['logs'] as List) {
              final topics = event['topics'] as List;
              final receiver = '0x${(topics[2] as String).substring(26)}';
              final net = BigInt.parse(event['data'] as String);
              row['tokenBalance'] = (BigInt.parse('${row['tokenBalance']}') - net).toString();
              final dest = wallets[receiver];
              if (dest != null) dest['tokenBalance'] = (BigInt.parse('${dest['tokenBalance']}') + net).toString();
            }
          }
          if (tx.to?.toLowerCase() != router.toLowerCase()) continue;
          for (final log in chainReceipts[hash]!['logs'] as List) {
            if (log['address'] == token) log['address'] = address;
            final topics = log['topics'] as List;
            if (topics.length == 4) {
              topics[2] = '0x${address.substring(2).padLeft(64, '0')}';
            }
          }
        }
      }
      return result;
    });
  }

  /// Execute the deterministic swap economics against the mock ledger.
  void tradeMarket() {
    onBundle = (raws) {
      for (final raw in raws) {
        final (_, owner, tx) = signatures[raw]!;
        if (tx.to?.toLowerCase() != router.toLowerCase()) continue;
        final row = wallets[owner]!;
        final native = BigInt.parse('${row['native']}');
        final balance = BigInt.parse('${row['tokenBalance']}');
        final buy = tx.value > BigInt.zero;
        final delta = buy ? tx.value * lot ~/ _swapNative : lot;
        row['native'] = '${buy ? native - tx.value : native + _swapNative}';
        row['tokenBalance'] = '${buy ? balance + delta : balance - delta}';
      }
    };
  }
}

void main() {
  // Covers indivisible units, stablecoin-like and BTC-like precisions, nine
  // decimals, standard ERC-20 and balances far beyond IEEE-754 exact integers.
  for (final d in [0, 6, 8, 9, 18, 24]) {
    final fake = _AssetBackend(d);
    final exact = d == 0 ? '14' : '13.${'0' * (d - 1)}1';

    test(
      '$d decimals: form → bundle buy → interval sell → receipt balances',
      () async {
        final api = fake.api();
        final market = Market(await api.platform(fake.address));
        final w = _wallet(80);
        fake.fund(w, BigInt.zero);
        fake.tradeMarket();
        final log = ExecutionLog();
        final group = TradeGroup(1, api, log)
          ..wallets = [w]
          ..selected.add(w.address)
          ..mode = SendMode.bundle
          ..min = '0.01'
          ..max = '';
        addTearDown(group.dispose);
        final buy = group.plan(fake.address, market.decimals, market: market);
        expect(buy.amount.min, _swapNative);
        expect((await group.trader.run(buy)).confirmed, 1);
        final bought = (await api.walletStates([
          w.address,
        ], token: fake.address)).single;
        expect(bought.tokenBalance, fake.lot);
        group
          ..setBuy(false)
          ..setRatio(false)
          ..mode = SendMode.interval
          ..intervalMin = '0'
          ..intervalMax = '0'
          ..min = exact
          ..max = exact;
        final sell = group.plan(fake.address, market.decimals, market: market);
        expect(sell.amount.min, fake.lot);
        final preview=await group.trader.prepare(sell);
        await group.trader.prepareSellApprovals(token:sell.token,wallets:sell.wallets,amounts:preview.amounts);
        expect(
          (await group.trader.run(sell)).confirmed,
          1,
          reason: log.entries.map((e) => e.text).join('\n'),
        );
        expect(fake.bundles.map((raws) => raws.length), [1, 1, 1]);
        final approve = fake.signatures[fake.bundles[1].single]!.$3;
        expect(approve.to!.toLowerCase(), fake.address);
        expect(approve.data, erc20Approve(router, fake.lot));
        expect(
          fake.routeBodies
              .where((r) => r['side'] == 'sell')
              .map((r) => r['amount'])
              .toSet(),
          {'${fake.lot}'},
        );
        final sold = (await api.walletStates([
          w.address,
        ], token: fake.address)).single;
        expect(sold.tokenBalance, BigInt.zero);
        expect(sold.nonce, 3);
      },
    );

    test(
      '$d decimals: one-to-many → many-to-many → collect from receipt ledger',
      () async {
        final src = _wallet(111);
        final first = [_wallet(112), _wallet(113)];
        final second = [_wallet(114), _wallet(115)];
        final target = _wallet(116);
        final b = _AssetBackend(d);
        final api = b.api();
        final engine = TransferEngine(api, ExecutionLog(), sleep: (_) async {});
        final asset = await engine.asset(b.address);
        expect((asset.decimals, asset.symbol), (d, b.symbol));
        final amount = parseUnits(exact, asset.decimals);
        expect(amount, b.lot);
        for (final w in [src, ...first, ...second, target]) {
          b.fund(w, w == src ? amount * BigInt.two : BigInt.zero);
        }
        final addresses = [
          src,
          ...first,
          ...second,
          target,
        ].map((w) => w.address).toList();
        await api.transferWalletStates(addresses, token: asset.address);
        final initialReads = b.calls.where((p) => p == 'wallets/state').length;
        final dist = await engine.prepareDistribution(
          engine.drawOneToMany(
            src,
            first.map((w) => w.address).toList(),
            amount,
            amount,
          ),
          asset,
          source: src,
        );
        await engine.execute(dist);
        expect(dist.complete, true);
        final paired = await engine.drawPaired(
          first,
          second.map((w) => w.address).toList(),
          asset,
          ratio: true,
          min: BigInt.from(10000),
          max: BigInt.from(10000),
        );
        expect(paired.map((r) => r.amount), [amount, amount]);
        final next = await engine.prepareDistribution(
          paired,
          asset,
          source: first.first,
          intervalMin: 1,
          intervalMax: 1,
        );
        await engine.execute(next);
        expect(next.complete, true);
        final collect = await engine.prepareCollection(
          second,
          target.address,
          asset,
        );
        expect(collect.total, amount * BigInt.two);
        await engine.execute(collect);
        expect(collect.complete, true);
        final balances = await api.transferWalletStates(
          addresses,
          token: asset.address,
        );
        expect(balances.map((s) => s.tokenBalance), [
          for (var i = 0; i < 5; i++) BigInt.zero,
          amount * BigInt.two,
        ]);
        expect(b.calls.where((p) => p == 'wallets/state').length, greaterThan(initialReads), reason: 'fresh chain balances are read before each new transfer');
        expect(b.calls, isNot(contains('transactions/bsc')));
      },
    );

    test(
      '$d decimals: linked sellers → buyback uses exact observed native proceeds',
      () async {
        final b = _AssetBackend(d);
        final api = b.api();
        final market = Market(await api.platform(b.address));
        final sellers = [_wallet(121), _wallet(122)], buyer = _wallet(123);
        for (final w in sellers) {
          b.fund(w, b.lot, allowance: b.lot);
        }
        b.fund(buyer, BigInt.zero);
        b.tradeMarket();
        final trader = LinkedTrader(api, ExecutionLog(), sleep: (_) async {});
        addTearDown(trader.dispose);
        final out = await trader.run(
          LinkedPlan(
            token: b.address,
            market: market,
            sellers: sellers,
            buyers: [buyer],
            sizing: LinkedSizing.percent(10000),
            loop: false,
          ),
        );
        expect(out.finished, true, reason: trader.error);
        expect(out.sold, b.lot * BigInt.two);
        expect(out.spent, _swapNative * BigInt.two);
        expect(out.spent, out.received);
        final owned = (await api.walletStates([
          buyer.address,
        ], token: b.address)).single;
        expect(owned.tokenBalance, b.lot * BigInt.two);
      },
    );
  }

  test('taxed relay forwards actual receipt balance and final credit includes the second tax', () async {
    final sender = _wallet(181),
        relay = _wallet(182),
        recipient = _wallet(183),
        feeTo = _wallet(184);
    final b = _AssetBackend(6, taxReceiver: feeTo.address);
    final api = b.api();
    for (final w in [sender, relay, recipient, feeTo]) {
      b.fund(w, w == sender ? BigInt.from(10000) : BigInt.zero);
    }
    b.wallets[relay.address.toLowerCase()]!['native'] = '0';
    final addresses = [
      sender.address,
      relay.address,
      recipient.address,
      feeTo.address,
    ];
    await api.transferWalletStates(addresses, token: b.address);
    final engine = TransferEngine(api, ExecutionLog(), sleep: (_) async {});
    final asset = await engine.asset(b.address);
    final amount = BigInt.from(10000);
    final plan = await engine.prepareDistribution(
      engine.drawOneToMany(
        sender,
        [recipient.address],
        amount,
        amount,
        transits: {recipient.address.toLowerCase(): relay},
      ),
      asset,
      source: sender,
    );
    await engine.execute(plan);
    expect(plan.complete, true);
    expect(b.bundles.map((raws) => raws.length), [2, 1]);
    expect(plan.legs.last.amount, BigInt.from(9500));
    final rows = await api.transferWalletStates(addresses, token: b.address);
    expect(rows.map((s) => s.tokenBalance), [
      BigInt.zero,
      BigInt.zero,
      BigInt.from(9025),
      BigInt.from(975),
    ]);
  });

  test('paused ERC20 blocks collection during gas estimation and sends no transaction', () async {
    final sender = _wallet(191);
    final b = _AssetBackend(8, blockTransfer: true);
    b.fund(sender, b.lot);
    final engine = TransferEngine(b.api(), ExecutionLog());
    final asset = await engine.asset(b.address);
    await expectLater(
      engine.prepareCollection([sender], _wallet(192).address, asset),
      throwsA(
        predicate((e) => e.toString().contains('token transfer is paused')),
      ),
    );
    expect(b.signatures, isEmpty);
    expect(b.bundles, isEmpty);
  });

  test('unknown token precision blocks amount-based transfer and sell but permits a percentage sale plan', () async {
    final w = _wallet(201);
    final b = _AssetBackend(9, knownPrecision: false);
    final api = b.api();
    final engine = TransferEngine(api, ExecutionLog());
    await expectLater(engine.asset(b.address), throwsStateError);
    final group = TradeGroup(1, api, ExecutionLog())
      ..wallets = [w]
      ..selected.add(w.address)
      ..setBuy(false)
      ..setRatio(false)
      ..min = '1'
      ..max = '1';
    addTearDown(group.dispose);
    expect(() => group.plan(b.address, null), throwsFormatException);
    group.setRatio(true);
    expect(group.plan(b.address, null).amount.min, BigInt.from(10000));
    expect(b.bundles, isEmpty);
  });
}
