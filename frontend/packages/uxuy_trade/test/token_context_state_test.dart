import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/linked.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/exec/transfers.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart' as fake;

const oldCa = '0x0000000000000000000000000000000000000011';
const newCa = '0x0000000000000000000000000000000000000022';
const otherCa = '0x0000000000000000000000000000000000000033';

class AuditClient extends BackendClient {
  AuditClient(this.backend)
    : super(Uri.parse('http://isolated.invalid'), backend.client());
  final fake.FakeBackend backend;
  Completer<void>? marketGate;
  Completer<void>? tokenGate;
  bool failMarket = false;
  String? wrongAddress;
  int tokenReads = 0;
  Completer<List<WalletState>>? oldBalances;
  @override
  Future<TokenMeta> token(String address) async {
    tokenReads++;
    await tokenGate?.future;
    return TokenMeta(
      wrongAddress ?? address,
      address,
      address == oldCa ? 'OLD' : 'NEW',
      18,
    );
  }

  @override
  Future<Map<String, dynamic>> platform(
    String address, {
    int? blockNumber,
  }) async {
    await marketGate?.future;
    if (failMarket) throw StateError('market unavailable');
    return {
      'address': wrongAddress ?? address,
      'symbol': 'TEST',
      'decimals': 18,
      'platform': 'external',
      'external': true,
      'quote': zeroAddress,
      'block': 100,
    };
  }

  @override
  Future<List<WalletState>> walletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async {
    if (token == oldCa && oldBalances != null) return oldBalances!.future;
    return super.walletStates(wallets, token: token, spender: spender);
  }
}

void main() {
  late fake.FakeBackend backend;
  late AuditClient api;
  late AppState state;
  TradeWallet wallet(int n) {
    final w = TradeWallet.import(
      'Synthetic',
      '0x${n.toRadixString(16).padLeft(64, '0')}',
    );
    backend.wallets[w.address.toLowerCase()] = {
      'native': '1000000000000000000',
      'nonce': 0,
      'tokenBalance': '1000000000000000000',
      'routerAllowance': '0',
    };
    return w;
  }

  TradeGroup group(int n) {
    final g = state.addGroup();
    final w = wallet(n);
    g.wallets = [w];
    g.selected.add(w.address);
    return g;
  }

  LinkedGroup linked(int n) {
    final g = state.addLinkedGroup();
    g.sellers = [wallet(n)];
    g.buyers = [wallet(n + 1)];
    g.transitByBuyer[g.buyers.single.address.toLowerCase()] = wallet(n + 2);
    return g;
  }

  Future<void> tick() => Future<void>.delayed(Duration.zero);
  void launched(Launcher launcher, String ca) {
    launcher.session = LaunchSession(
      platform: launcher.label,
      token: ca,
      symbol: 'NEW',
      dev: wallet(91),
      wallets: [],
    );
    launcher.state = LaunchState.launched;
    launcher.changed();
  }

  setUp(() async {
    backend = fake.FakeBackend();
    api = AuditClient(backend);
    state = AppState(api, MemoryKeyStore());
    await state.loadToken(oldCa);
  });
  tearDown(() {
    state.dispose();
    api.http_.close();
  });

  test('ordinary running, paused, unresolved and resumable states refuse token switches', () async {
    final g = group(1);
    g.trader.running = true;
    await expectLater(state.loadToken(newCa), throwsStateError);
    g.trader.paused = true;
    await expectLater(state.loadToken(newCa), throwsStateError);
    g.trader.running = false;
    g.trader.unresolved.add('synthetic-hash');
    await expectLater(state.loadToken(newCa), throwsStateError);
    expect(() => state.endGroup(g), throwsStateError);
    g.trader.unresolved.clear();
    g.remaining = {g.wallets.single.address.toLowerCase(): BigInt.one};
    await expectLater(state.loadToken(newCa), throwsStateError);
    expect(() => state.removeGroup(g), throwsStateError);
    state.endGroup(g);
    await state.loadToken(newCa);
    expect(state.token!.address, newCa);
  });

  test('unfinished linked round and tools execution also lock token', () async {
    final g = linked(2);
    g.trader.progress = LinkedProgress();
    await expectLater(state.loadToken(newCa), throwsStateError);
    g.trader.progress!.finished = true;
    state.transfers.running = true;
    await expectLater(state.loadToken(newCa), throwsStateError);
    state.transfers.running = false;
    await state.loadToken(newCa);
  });

  test('transfer execution and launcher entry enforce the group workspace lock', () async {
    final engine = state.transfers;
    final run = await engine.prepareCollection([wallet(71)], wallet(72).address, TransferAsset.bnb);
    final g = state.addGroup();
    final hold = Completer<void>();
    final active = state.withWalletUse(owner: g, label: g.name,
        addresses: [wallet(73).address], action: () => hold.future);
    await expectLater(engine.execute(run), throwsA(isA<WorkspaceConflict>()));
    await expectLater(state.four.guard(() async => fail('cross-page launch')), throwsA(isA<WorkspaceConflict>()));
    expect(backend.bundles, isEmpty);
    hold.complete();
    await active;
    engine.current = run;
    run.legs.single.status = TransferStatus.notIncluded;
    expect(state.workspaceBlockReason(WorkspacePage.batch), isNotNull);
    expect(state.workspaceBlockReason(WorkspacePage.tools), isNull);
    engine.finish(run);
    expect(state.workspaceBlockReason(WorkspacePage.batch), isNull);
  });

  test('a retained collection keeps its token lock and wallet warning until its own receipt settles', () async {
    final tools = state.transfers;
    final sender = wallet(70);
    final destination = wallet(71).address;
    final older = await tools.prepareCollection([sender], destination, TransferAsset.bnb);
    final hash = '0x${'a' * 64}';
    older.legs.single
      ..hash = hash
      ..status = TransferStatus.unknown;
    tools.current = older;

    final newer = await tools.prepareCollection([wallet(72)], wallet(73).address, TransferAsset.bnb);
    await tools.execute(newer);
    expect(newer.complete, isTrue);
    expect(tools.unresolvedRuns, contains(older));
    expect(state.walletOverlaps(Object(), [sender.address]), {
      sender.address.toLowerCase(): {'归集'},
    });
    await expectLater(state.loadToken(newCa), throwsStateError);

    final sends = backend.bundles.length;
    await tools.query(older);
    expect(older.complete, isTrue);
    expect(backend.bundles, hasLength(sends));
    expect(state.walletOverlaps(Object(), [sender.address]), isEmpty);
    await state.loadToken(newCa);
    expect(state.token!.address, newCa);
  });

  test('preparation locks before its first await, cancellation drains the old request', () async {
    final g = group(5);
    api.marketGate = Completer<void>();
    final preparing = state.prepare(g);
    final failed = expectLater(preparing, throwsStateError);
    final handle = state.operationHandle(g);
    expect(state.tokenLockReason, isNotNull);
    await expectLater(state.loadToken(newCa), throwsStateError);
    await expectLater(state.prepare(g), throwsStateError);
    state.cancelPreparation(g, handle: handle);
    expect(state.groupOperationBusy(g), isTrue);
    await expectLater(state.prepare(g), throwsStateError);
    api.marketGate!.complete();
    await failed;
    expect(state.groupOperationBusy(g), isFalse);
    expect(backend.routeBodies, isEmpty);
    expect(backend.submitted, isEmpty);
  });

  test('confirmed plan is locked, cancelled results cannot execute and old handles cannot cancel new plans', () async {
    final g = group(6);
    final old = await state.prepare(g);
    final oldHandle = state.operationHandle(g);
    expect(state.preparedToken(g)!.address, oldCa);
    await expectLater(state.loadToken(newCa), throwsStateError);
    state.cancelPreparation(g, handle: oldHandle);
    await state.loadToken(newCa);
    await expectLater(state.start(g, prepared: old), throwsStateError);
    await state.prepare(g);
    state.cancelPreparation(g, handle: oldHandle);
    expect(state.groupOperationBusy(g), isTrue);
    expect(state.preparedToken(g)!.address, newCa);
    state.cancelPreparation(g);
    expect(backend.submitted, isEmpty);
  });

  test('random interval previews and executes every wallet in the same order and amount', () async {
    final g = group(10)
      ..randomOrder = true
      ..intervalMin = '0'
      ..intervalMax = '0'
      ..max = '0.025';
    for (var i = 11; i < 16; i++) {
      final next = wallet(i);
      g.wallets.add(next);
      g.selected.add(next.address);
    }
    final preview = await state.prepare(g);
    expect(preview.amounts.length, 6);
    expect(backend.routeBodies.length, 6);
    final read = backend.routeBodies.first;
    expect(read['forecastOnly'], true);
    expect(read['wallet'].toLowerCase(), preview.amounts.keys.first);
    expect(read['amount'], preview.amounts.values.first.toString());
    expect(preview.quotedOutput, BigInt.from(1000));
    final out = await state.start(g, prepared: preview);
    expect(out.confirmed, 6);
    final execution = backend.routeBodies.where((r) => r['forecastOnly'] != true);
    expect(execution.map((r) => r['wallet'].toLowerCase()), preview.amounts.keys);
    expect(execution.map((r) => r['amount']), preview.amounts.values.map((v) => v.toString()));
    expect(execution.every((r) => r['forecastOnly'] != true), isTrue);
  });

  test('resumed random interval previews the next unsent wallet and preserves remaining order', () async {
    final g = group(11)
      ..randomOrder = true
      ..intervalMin = '0'
      ..intervalMax = '0';
    final next = wallet(12);
    g.wallets.add(next);
    g.selected.add(next.address);
    final remaining = {next.address.toLowerCase(): BigInt.from(102), g.wallets.first.address.toLowerCase(): BigInt.from(77)};
    g.remaining = Map.of(remaining);
    final preview = await state.prepare(g, resume: true);
    expect(preview.amounts.keys, remaining.keys);
    expect(backend.routeBodies.map((r) => r['amount']), ['102','77']);
    final out = await state.start(g, resume: true, prepared: preview);
    expect(out.confirmed, 2);
    expect(backend.routeBodies.where((r)=>r['forecastOnly']!=true).map((r) => r['amount']), ['102', '77']);
  });

  test('confirmed direction and token survive form mutation; duplicate starts are refused', () async {
    final g = group(7);
    final prepared = await state.prepare(g);
    api.marketGate = Completer<void>();
    g.buy = false;
    final started = state.start(g, prepared: prepared);
    await expectLater(state.start(g, prepared: prepared), throwsStateError);
    await expectLater(state.loadToken(newCa), throwsStateError);
    api.marketGate!.complete();
    await started;
    expect(
      backend.routeBodies.every(
        (r) => r['token'] == oldCa && r['side'] == 'buy',
      ),
      isTrue,
    );
    expect(
      backend.submitted,
      isNotEmpty,
    ); // Only the in-memory FakeBackend receives synthetic signatures.
    expect(state.groupOperationBusy(g), isFalse);
  });

  testWidgets(
    'one ten-second read produces feedback and a confirmable unsigned preview',
    (tester) async {
      final g = group(34);
      api.marketGate = Completer<void>();
      final pending = state.prepare(g);
      await tester.pump(const Duration(seconds: 2));
      expect(state.slowPreview(g), isTrue);
      final handle = state.operationHandle(g);
      final duplicate = expectLater(state.prepare(g), throwsStateError);
      await tester.pump(const Duration(seconds: 8));
      await duplicate;
      expect(state.operationHandle(g), same(handle));
      expect(backend.routeBodies, isEmpty);
      api.marketGate!.complete();
      await tester.pump();
      final preview = await pending;
      expect(state.preparedReady(g), isTrue);
      expect(preview.amounts.length, 1);
      expect(backend.routeBodies, hasLength(1));
      expect(backend.submitted, isEmpty);
      expect(backend.bundles, isEmpty);
      state.cancelPreparation(g, handle: handle);
    },
  );

  testWidgets(
    'cancelled slow preparation cannot display or execute a late quote',
    (tester) async {
      final g = group(36);
      api.marketGate = Completer<void>();
      final pending = expectLater(state.prepare(g), throwsStateError);
      await tester.pump(const Duration(seconds: 3));
      state.cancelPreparation(g);
      await tester.pump();
      await pending;
      expect(state.groupOperationBusy(g), isFalse);
      api.marketGate!.complete();
      await tester.pump();
      expect(backend.routeBodies, isEmpty);
      expect(backend.submitted, isEmpty);
    },
  );

  test('switch returns while background wallet reads are pending and newer token wins', () async {
    final g = group(35);
    api.oldBalances = Completer<List<WalletState>>();
    await state.loadToken(oldCa).timeout(const Duration(seconds: 1));
    expect(state.tokenSwitching, isFalse);
    await state.loadToken(newCa);
    await Future<void>.delayed(Duration.zero);
    final currentStates = g.states;
    expect(currentStates, isNotEmpty);
    api.oldBalances!.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(g.states, same(currentStates));
    expect(state.token!.address, newCa);
  });

  test('editing global limits invalidates the old confirmation and refreshes only a new order', () async {
    final g = group(38);
    backend.adverseImpact = 15;
    final old = await state.prepare(g);
    expect(state.preparedImpact(g)!.needsConfirmation, isTrue);
    state.setImpactSettings(ImpactSettings.parse('25', '18', '25'));
    await expectLater(
      state.start(g, prepared: old, impactConfirmed: true),
      throwsStateError,
    );
    expect(backend.submitted, isEmpty);
    await state.prepare(g);
    expect(state.preparedImpact(g)!.needsConfirmation, isFalse);
    state.cancelPreparation(g);
  });

  test('independent groups prepare concurrently; releasing one cannot release the other', () async {
    final a = group(8), b = group(9);
    await Future.wait([state.prepare(a), state.prepare(b)]);
    state.cancelPreparation(a);
    await expectLater(state.loadToken(newCa), throwsStateError);
    state.cancelPreparation(b);
    await state.loadToken(newCa);
  });

  test(
    'token loading blocks group preparation and duplicate token loads',
    () async {
      final g = group(10);
      api.tokenGate = Completer<void>();
      final loading = state.loadToken(newCa);
      await expectLater(state.prepare(g), throwsStateError);
      await expectLater(state.loadToken(otherCa), throwsStateError);
      api.tokenGate!.complete();
      await loading;
      expect(state.token!.address, newCa);
    },
  );

  test(
    'token and market commit atomically and response address is verified',
    () async {
      final prior = state.market;
      api.failMarket = true;
      await expectLater(state.loadToken(newCa), throwsStateError);
      expect(state.token!.address, oldCa);
      expect(state.market, same(prior));
      expect(state.tokenSwitching, isFalse);
      api.failMarket = false;
      api.wrongAddress = otherCa;
      await expectLater(state.loadToken(newCa), throwsStateError);
      expect(state.token!.address, oldCa);
    },
  );

  test(
    'a new execution during a slow token read prevents late commit',
    () async {
      final g = group(11);
      api.tokenGate = Completer<void>();
      final loading = state.loadToken(newCa);
      final check = expectLater(loading, throwsStateError);
      g.trader.running = true; // Models a separately initiated engine activity.
      api.tokenGate!.complete();
      await check;
      expect(state.token!.address, oldCa);
      g.trader.running = false;
    },
  );

  test(
    'late old-token balance response never overwrites new-token balances',
    () async {
      final g = group(12);
      api.oldBalances = Completer<List<WalletState>>();
      final oldRead = state.refresh(g);
      await state.loadToken(newCa);
      await Future<void>.delayed(Duration.zero);
      final newStates = g.states;
      api.oldBalances!.complete([]);
      await oldRead;
      expect(g.states, same(newStates));
      expect(g.states, isNotEmpty);
    },
  );

  for (final index in [0, 1, 2]) {
    test(
      'confirmed launch $index auto-adopts once and never re-adopts on unrelated notification',
      () async {
        final launcher = [state.four, state.flap, state.genius][index];
        launched(launcher, newCa);
        await tick();
        await tick();
        expect(state.token!.address, newCa);
        expect(state.pendingLaunchTokens, isEmpty);
        await state.loadToken(otherCa);
        launcher.changed();
        await tick();
        expect(state.token!.address, otherCa);
      },
    );
  }

  test('pending creation never becomes current; blocked launch requires explicit adoption', () async {
    final g = group(13);
    state.four.session = LaunchSession(
      platform: 'four',
      token: newCa,
      symbol: 'NEW',
      dev: wallet(91),
      wallets: [],
    );
    state.four.state = LaunchState.pending;
    state.four.changed();
    await tick();
    expect(state.pendingLaunchTokens, isEmpty);
    expect(state.token!.address, oldCa);
    g.trader.running = true;
    state.four.state = LaunchState.launched;
    state.four.changed();
    await tick();
    expect(state.token!.address, oldCa);
    expect(state.pendingLaunchTokens.single.address, newCa);
    await expectLater(state.adoptLaunchToken(newCa), throwsStateError);
    g.trader.running = false;
    g.update((_) {});
    await tick();
    expect(state.token!.address, oldCa);
    await state.adoptLaunchToken(newCa);
    expect(state.token!.address, newCa);
    expect(state.pendingLaunchTokens, isEmpty);
  });

  test(
    'failed launch metadata keeps old token and pending new CA for retry',
    () async {
      api.failMarket = true;
      launched(state.flap, newCa);
      await tick();
      await tick();
      expect(state.token!.address, oldCa);
      expect(state.pendingLaunchTokens.single.address, newCa);
      expect(state.tokenNotice, contains('请勿误交易旧币'));
      api.failMarket = false;
      await state.adoptLaunchToken(newCa);
      expect(state.pendingLaunchTokens, isEmpty);
    },
  );

  test('multiple simultaneous launches are retained without picking an arbitrary token', () async {
    launched(state.four, newCa);
    launched(state.flap, otherCa);
    await tick();
    expect(state.pendingLaunchTokens.length, 2);
    expect(state.token!.address, oldCa);
    await state.adoptLaunchToken(otherCa);
    expect(state.token!.address, otherCa);
    expect(state.pendingLaunchTokens.single.address, newCa);
  });

  test(
    'cancelled linked inflight request cannot overwrite a later prepared draw',
    () async {
      final g = linked(14);
      // This cancellation test exercises an already authorized seller.
      backend.wallets[g.sellers.single.address.toLowerCase()]!['routerAllowance'] = '1000000000000000000';
      api.marketGate = Completer<void>();
      final first = state.prepareLinked(g);
      final check = expectLater(first, throwsStateError);
      state.cancelPreparation(g);
      await expectLater(state.prepareLinked(g), throwsStateError);
      api.marketGate!.complete();
      await check;
      await state.loadToken(newCa);
      final next = await state.prepareLinked(g);
      expect(next.tranche, greaterThan(BigInt.zero));
      expect(state.preparedToken(g)!.address, newCa);
      state.cancelPreparation(g);
      expect(backend.submitted, isEmpty);
    },
  );
}
