import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';
import 'support/inner_quote.dart' as official;

final four = Market({
  ...official.innerMarket('four').raw,
  'identity': 'four:$token:$zeroAddress:0',
});

class _Chain extends FakeBackend {
  _Chain(List<TradeWallet> owners) {
    innerQuote = (r) => official.innerQuote(four, r);
    for (final owner in owners) {
      wallets[owner.address.toLowerCase()] = {
        'native': '1000000000000000000',
        'nonce': 3,
        'tokenBalance': '5000000000',
        'routerAllowance': '5000000000',
      };
    }
  }

  int migrateAfter = 1;
  int discoveries = 0;
  String rejection = 'INNER_MARKET_CHANGED';
  Future<void> Function()? delayNextInnerMarket;
  Map<String, dynamic> Function(int)? overrideMarket;
  Map<String, dynamic> Function(Map<String, dynamic>)? overrideOuter;

  @override
  http.Client client() {
    final base = super.client();
    http.Response json(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json'},
    );
    return MockClient((req) async {
      final path = req.url.path.split('/').last;
      if (path == 'bsc' && req.url.path.contains('/platforms/')) {
        if (bundles.length < migrateAfter) {
          final delay = delayNextInnerMarket;
          delayNextInnerMarket = null;
          await delay?.call();
          return json({'ok': true, 'result': four.raw});
        }
        discoveries++;
        return json({
          'ok': true,
          'result': {
            ...four.raw,
            'external': true,
            'pool': pool,
            'block': 1001,
            ...?overrideMarket?.call(discoveries),
          },
        });
      }
      final failure = {'ok': false, 'code': rejection, 'message': rejection};
      if (path == 'routes' || path == 'batch') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (bundles.length >= migrateAfter) {
          if (body['innerPlatform'] == 'four') return json(failure);
          if (path == 'batch' &&
              (body['requests'] as List).every(
                (r) => r['innerPlatform'] == 'four',
              )) {
            return json({
              'ok': true,
              'results': [for (final _ in body['requests']) failure],
            });
          }
        }
      }
      final copy = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes;
      final response = await http.Response.fromStream(await base.send(copy));
      if (path == 'routes' && overrideOuter != null) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['plan']?['source'] == 'uxuy') {
          body['plan'] = overrideOuter!(body['plan'] as Map<String, dynamic>);
          return json(body);
        }
      }
      return response;
    });
  }
}

void main() {
  final owners = [
    for (var i = 0; i < 3; i++)
      TradeWallet.import(
        'Synthetic $i',
        (500 + i).toRadixString(16).padLeft(64, '0'),
      ),
  ];
  final amounts = {
    for (final (i, w) in owners.indexed)
      w.address.toLowerCase(): BigInt.from((i + 1) * 1000000000),
  };
  TradePlan plan({bool buy = true, bool loop = false, bool linked = false}) =>
      TradePlan(
        token: token,
        buy: buy,
        wallets: owners,
        market: four,
        mode: SendMode.interval,
        resume: amounts,
        loop: loop,
        exact: linked ? amounts : null,
        maxImpactPercent: 3,
        amount: AmountRule(
          ratio: false,
          min: BigInt.from(500),
          max: BigInt.from(500),
        ),
      );
  BatchTrader trader(_Chain node) =>
      BatchTrader(node.api(), ExecutionLog(), sleep: (_) async {});

  test('ordinary group prepares on the curve and resumes only the two unsent wallets on UXUY', () async {
    final node = _Chain(owners);
    // Refuse the UXUY route after the first wallet's official buy has confirmed.
    node.afterSubmit = () {
      if (node.bundles.length == 1)
        node.refuse.add(owners[1].address.toLowerCase());
    };
    final state = AppState(node.api(), MemoryKeyStore())
      ..token = const TokenMeta(token, 'Synthetic', 'TEST', 18);
    addTearDown(state.dispose);
    final group = state.addGroup()
      ..wallets = owners
      ..selected.addAll(owners.map((w) => w.address))
      ..intervalMin = '0'
      ..intervalMax = '0';
    final prepared = await state.prepare(group);
    expect(prepared.amounts, hasLength(3));
    expect(node.signatures, isEmpty);
    final first = await state.start(group, prepared: prepared);
    expect(first.confirmed, 1);
    expect(state.market?.label, 'Four.meme · 外盘 · BNB 结算');
    expect(group.remaining?.keys, amounts.keys.skip(1));
    node.refuse.clear();
    final remaining = await state.prepare(group, resume: true);
    final finished = await state.start(
      group,
      resume: true,
      prepared: remaining,
    );
    expect(finished.confirmed, 2);
    expect(group.remaining, isNull);
    expect(node.signatures.values.map((s) => s.$2), amounts.keys);
  });

  test('workbench switches before the outer quote and a concurrent older read cannot restore the curve', () async {
    final otherOwner = TradeWallet.import(
      'Synthetic spare',
      '999'.padLeft(64, '0'),
    );
    final node = _Chain([...owners, otherOwner]);
    final state = AppState(node.api(), MemoryKeyStore())
      ..token = const TokenMeta(token, 'Synthetic', 'TEST', 18);
    addTearDown(state.dispose);
    final main = state.addGroup()
      ..wallets = owners
      ..selected.addAll(owners.map((w) => w.address))
      ..intervalMin = '0'
      ..intervalMax = '0';
    final other = state.addGroup()
      ..wallets = [otherOwner]
      ..selected.add(otherOwner.address);
    final prepared = await state.prepare(main);
    final started = Completer<void>(), resume = Completer<void>();
    node.delayNextInnerMarket = () {
      started.complete();
      return resume.future;
    };
    final oldRead = expectLater(
      state.prepare(other),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Four 外盘状态已更新'),
        ),
      ),
    );
    await started.future;
    var checked = false;
    node.overrideOuter = (route) {
      final displayed = state.market!;
      expect(displayed.label, 'Four.meme · 外盘 · BNB 结算');
      if (!checked) {
        checked = true;
        expect(node.signatures, hasLength(1));
        for (final changes in [
          {'address': router, 'block': 1002},
          {'identity': 'different', 'block': 1002},
          {'block': 1000},
          {'pool': router, 'block': 1002},
        ]) {
          main.trader.onFourExternalVerified!.call(
            Market({...displayed.raw, ...changes}),
          );
          expect(identical(state.market, displayed), isTrue);
        }
      }
      return route;
    };
    try {
      final out = await state.start(main, prepared: prepared);
      expect(out.confirmed, 3);
      expect(checked, isTrue);
    } finally {
      resume.complete();
    }
    await oldRead;
    expect(node.signatures.values.map((s) => s.$2), amounts.keys);
    expect(state.market!.block, 1001);
    expect(state.market!.external, isTrue);
  });

  test('only unsent wallets obtain fresh UXUY calldata for the confirmed BNB amount', () async {
    final node = _Chain(owners);
    final result = await trader(node).run(plan());
    expect(result.confirmed, 3);
    expect(result.remaining, isEmpty);
    expect(node.discoveries, 2);
    expect(node.signatures.values.map((s) => s.$2), amounts.keys);
    expect(node.signatures.values.map((s) => s.$3.to!.toLowerCase()), [
      fourManager.toLowerCase(),
      router.toLowerCase(),
      router.toLowerCase(),
    ]);
    expect(node.signatures.values.map((s) => s.$3.value), amounts.values);
    final external = node.routeBodies.where((r) => r['innerPlatform'] == null);
    expect(
      external.map((r) => r['wallet'].toString().toLowerCase()),
      amounts.keys.skip(1),
    );
    expect(
      external.every(
        (r) => r['slippageBps'] == 50 && r['maxImpactPercent'] == 3,
      ),
      isTrue,
    );
  });

  test(
    'external route persists across rounds and exhaustion ends the loop',
    () async {
      final node = _Chain(owners);
      node.afterSubmit = () {
        if (node.bundles.length == 4) {
          for (final wallet in node.wallets.values) {
            wallet['native'] = '0';
          }
        }
      };
      final result = await trader(node).run(plan(loop: true));
      expect(result.stopped, false);
      expect(result.confirmed, 4);
      expect(result.rounds, 3);
      expect(
        node.signatures.values.last.$3.to!.toLowerCase(),
        router.toLowerCase(),
      );
    },
  );

  test(
    'graduation during gas measurement is recovered before signing',
    () async {
      final node = _Chain(owners)..migrateAfter = 0;
      for (final row in node.wallets.values) {
        row['native'] = '20000000000000';
      }
      final result = await trader(node).run(plan());
      expect(result.confirmed, 3);
      expect(
        node.signatures.values.every(
          (s) => s.$3.to!.toLowerCase() == router.toLowerCase(),
        ),
        true,
      );
    },
  );

  for (final entry in <String, Map<String, dynamic>>{
    'other token': {'address': router},
    'different registry': {'identity': 'other'},
    'different quote asset': {'quote': wbnb},
    'missing pair': {'pool': null},
    'unreadable block': {'block': 'invalid'},
    'unreadable pair': {'pool': 55},
    'same pre-graduation block': {'block': 1000},
    'stage reversal': {'external': false},
  }.entries) {
    test('unverified graduation stops before signing: ${entry.key}', () async {
      final node = _Chain(owners)..overrideMarket = (_) => entry.value;
      final result = await trader(node).run(plan());
      expect(result.stopped, true);
      expect(result.confirmed, 1);
      expect(node.signatures, hasLength(1));
      expect(result.remaining.keys, amounts.keys.skip(1));
    });
  }

  for (final field in [
    'impact',
    'minOut',
    'to',
    'wallet',
    'slippage',
    'disabled quote',
  ]) {
    test('rejects an invalid outer quote before signing: $field', () async {
      final node = _Chain(owners);
      if (field == 'disabled quote')
        node.refuse.add(owners[1].address.toLowerCase());
      node.overrideOuter = (r) => {
        ...r,
        ...switch (field) {
          'impact' => {'adversePriceImpactPercent': 4},
          'minOut' => {'minOut': '1'},
          'to' => {'to': pool},
          'wallet' => {'wallet': owners.first.address},
          'slippage' => {'slippagePpm': 10000},
          _ => {},
        },
      };
      final result = await trader(node).run(plan());
      expect(result.stopped, true);
      expect(result.remaining.keys, amounts.keys.skip(1));
      expect(node.signatures, hasLength(1));
    });
  }

  test(
    'wallet balance and mined nonce are rechecked after discovery',
    () async {
      for (final pending in [false, true]) {
        final node = _Chain(owners);
        final owner = owners[1].address.toLowerCase();
        node.overrideMarket = (i) {
          if (i == 1) {
            if (pending) {
              node.minedNonces[owner] =
                  2; // The wallet state still has pending nonce 3.
            } else {
              node.wallets[owner]!['native'] =
                  (gasPrice * BigInt.from(350000) + BigInt.from(500))
                      .toString();
            }
          }
          return {};
        };
        final result = await trader(node).run(plan());
        expect(result.confirmed, pending ? 1 : 3);
        if (pending) {
          expect(result.remaining.keys, amounts.keys.skip(1));
          expect(node.signatures, hasLength(1));
        } else {
          expect(
            node.signatures.values.elementAt(1).$3.value,
            BigInt.from(500),
          );
        }
      }
    },
  );

  test('an unconfirmed submission blocks the next wallet and reruns until reconciled', () async {
    final node = _Chain(owners)..receipt = 'unknown';
    final t = trader(node);
    final result = await t.run(plan());
    expect(result.stopped, true);
    expect(node.signatures, hasLength(1));
    expect(result.remaining.keys, amounts.keys.skip(1));
    expect(t.unresolved, isNotEmpty);
    expect(node.discoveries, 0);
    await expectLater(t.run(plan()), throwsStateError);
    expect(node.bundles, hasLength(1));
  });

  test(
    'external pooling stays pinned and cannot return to the curve',
    () async {
      final node = _Chain(owners)
        ..overrideMarket = (i) => i == 2 ? {'external': false} : {};
      final result = await trader(node).run(plan());
      expect(result.stopped, true);
      expect(result.confirmed, 2);
      expect(node.signatures, hasLength(2));
      expect(result.remaining.keys, [amounts.keys.last]);
    },
  );

  test('migration before selling preserves the queue for fresh external approval checks', () async {
    final node = _Chain(owners)..migrateAfter = 0;
    final t = trader(node);
    final result = await t.run(plan(buy: false));
    expect(result.stopped, true);
    expect(result.remaining, amounts);
    expect(node.signatures, isEmpty);
    expect(t.log.entries.any((e) => e.text.contains('外盘授权')), true);
  });

  test(
    'an unrelated failure or a linked group cannot trigger the handover',
    () async {
      for (final linked in [true, false]) {
        final node = _Chain(owners)..migrateAfter = 0;
        if (!linked) node.rejection = 'LIQUIDITY_INSUFFICIENT';
        final result = await trader(node).run(plan(linked: linked));
        expect(result.stopped, true);
        expect(node.discoveries, 0);
        expect(node.signatures, isEmpty);
      }
    },
  );
}
