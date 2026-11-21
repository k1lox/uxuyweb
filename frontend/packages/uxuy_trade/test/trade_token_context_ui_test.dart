import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/evm/evm.dart' show LegacyTx;
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

class _DelayedMarketClient extends BackendClient {
  _DelayedMarketClient(FakeBackend backend)
    : super(Uri.parse('http://isolated.test/'), backend.client());

  Completer<void>? marketGate;
  int marketReadsStarted = 0;

  @override
  Future<Map<String, dynamic>> platform(
    String token, {
    int? blockNumber,
  }) async {
    marketReadsStarted++;
    await marketGate?.future;
    return super.platform(token, blockNumber: blockNumber);
  }
}

String _key(int n) => '0x${n.toRadixString(16).padLeft(64, '0')}';

void main() {
  late FakeBackend backend;
  late _DelayedMarketClient api;
  late AppState state;

  setUp(() {
    backend = FakeBackend();
    api = _DelayedMarketClient(backend);
    state = AppState(api, MemoryKeyStore())
      ..token = const TokenMeta(token, 'PancakeSwap Token', 'CAKE', 18);
  });
  tearDown(() {
    state.dispose();
    api.http_.close();
  });

  TradeWallet wallet(int n) {
    final w = TradeWallet.import('Synthetic $n', _key(n));
    backend.wallets[w.address.toLowerCase()] = {
      'native': '1000000000000000000',
      'nonce': 1,
      'tokenBalance': '1000000000000000000',
      // This fixture isolates the confirmation and wallet-overlap UI.
      'routerAllowance': '1000000000000000000',
    };
    return w;
  }

  GroupBase group(bool linked) {
    if (!linked) {
      final g = state.addGroup();
      final w = wallet(81);
      g.wallets = [w];
      g.selected.add(w.address);
      return g;
    }
    final g = state.addLinkedGroup();
    g.sellers = [wallet(82)];
    g.buyers = [wallet(83)];
    g.transitByBuyer[g.buyers.single.address.toLowerCase()] = wallet(84);
    return g;
  }

  Future<void> mount(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.init();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: uxuyTheme(ThemeData(useMaterial3: true)),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (_, _) => BatchPage(state: state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapStart(WidgetTester tester, bool linked) async {
    final button = find.text(linked ? '检查授权' : '开始执行');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
  }

  for (final linked in [false, true]) {
    for (final width in [1440.0, 390.0]) {
      testWidgets(
        '${linked ? 'linked' : 'ordinary'} confirmation pins full CA and releases lock on cancel at $width',
        (tester) async {
          final g = group(linked);
          await mount(tester, width);
          await tapStart(tester, linked);
          await tester.pumpAndSettle();
          expect(find.byType(UiDialog), findsOneWidget);
          expect(find.text('BSC · CAKE'), findsOneWidget);
          expect(find.text(token), findsOneWidget);
          expect(find.text('请核对网络与代币地址，确认后将按此代币执行。'), findsOneWidget);
          expect(state.groupOperationBusy(g), isTrue);
          expect(state.preparedToken(g)?.address, token);
          expect(state.tokenLockReason, isNotNull);
          expect(backend.submitted, isEmpty);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(UiDialog), findsNothing);
          expect(state.groupOperationBusy(g), isFalse);
          expect(state.tokenLockReason, isNull);
          expect(backend.submitted, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final linked in [false, true]) {
    testWidgets(
      'shared wallet blocks before ${linked ? 'linked' : 'normal'} preview; cancel costs no request',
      (tester) async {
        final g = group(linked);
        final shared = state.groupWallets(g).first.toLowerCase();
        final other = state.four;
        final done = Completer<void>();
        final active = state.withWalletUse(
          owner: other,
          label: 'Four.meme 发币',
          addresses: [shared],
          action: () => done.future,
        );
        await mount(tester, linked ? 390 : 1440);
        final before = backend.calls.length;
        await tapStart(tester, linked);
        await tester.pumpAndSettle();
        expect(find.text('钱包正在其他操作中使用'), findsOneWidget);
        expect(find.text(shared), findsOneWidget);
        expect(find.text('Four.meme 发币'), findsOneWidget);
        expect(find.text('仍然继续'), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(api.marketReadsStarted, 0);
        expect(backend.calls, hasLength(before));
        expect(state.walletOverlaps(other, [shared]), isEmpty);

        done.complete();
        await active;
        await tapStart(tester, linked);
        await tester.pumpAndSettle();
        expect(api.marketReadsStarted, 1);
        expect(
          find.byKey(const ValueKey('trade-token-warning')),
          findsOneWidget,
        );
        expect(state.walletOverlaps(other, [shared])[shared], {g.name});
        expect(backend.bundles, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(state.walletOverlaps(Object(), [shared]), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('ordinary selection, unfinished orders and currently assigned linked relays determine overlap', () async {
    final ordinary = group(false) as TradeGroup;
    final used = ordinary.wallets.first;
    final idle = wallet(87);
    ordinary.wallets.add(idle);
    final linked = group(true) as LinkedGroup;
    final stale = wallet(86);
    linked.transitByBuyer[stale.address.toLowerCase()] = stale;
    final owner = Object();
    await state.withWalletUse(
      owner: ordinary,
      label: ordinary.name,
      addresses: state.groupWallets(ordinary),
      action: () async {
        expect(state.walletOverlaps(owner, [idle.address]), isEmpty);
        expect(
          state.walletOverlaps(owner, [used.address])[used.address
              .toLowerCase()],
          {ordinary.name},
        );
        var executed = false;
        await expectLater(
          state.withWalletUse(owner: owner, label: '归集', addresses: [used.address],
            action: () async => executed = true),
          throwsA(isA<WorkspaceConflict>().having(
            (e) => e.wallets[used.address.toLowerCase()], 'owners', {ordinary.name})),
        );
        expect(executed, isFalse);
      },
    );
    final relay = linked.transits.single;
    expect(state.groupWallets(linked), contains(relay.address));
    expect(state.groupWallets(linked), isNot(contains(stale.address)));
    ordinary.selected.add(idle.address);
    ordinary.remaining = {used.address.toLowerCase(): BigInt.one};
    expect(state.groupWallets(ordinary, resume: true), [
      used.address.toLowerCase(),
    ]);
    expect(state.walletOverlaps(owner, [used.address]), isEmpty);
    expect(backend.calls, isEmpty);
  });

  test('an original unconfirmed nonce blocks the second action before submission; only unsettled addresses are named', () async {
    final g = group(false) as TradeGroup;
    final signer = g.wallets.single;
    final idle = wallet(89);
    g.wallets.add(idle);
    g.selected.add(idle.address);
    final signed = api.sign(
      signer,
      LegacyTx(
        nonce: 1,
        gasPrice: BigInt.one,
        gasLimit: 21000,
        to: wallet(88).address,
        value: BigInt.one,
        data: Uint8List(0),
      ),
    );
    backend.receipt = 'pending';
    await api.bundle([signed.raw], 1020);
    g.trader.unresolved.add(signed.hash);
    final owner = Object();
    final observed = state.walletOverlaps(owner, [
      signer.address,
      idle.address,
    ]);
    expect(observed, {
      signer.address.toLowerCase(): {g.name},
    });
    await expectLater(
      state.withWalletUse(
        owner: owner,
        label: '归集',
        addresses: [signer.address],
        action: () async {
          await api.bundle([signed.raw], 1020);
        },
      ),
      throwsA(
        isA<WorkspaceConflict>().having((e) => e.wallets.keys, 'wallets', [signer.address.toLowerCase()]),
      ),
    );
    expect(backend.bundles, hasLength(1));
    backend.receipt = 'not_included';
    await api.status(signed.hash);
    expect(state.walletOverlaps(owner, [signer.address]), isEmpty);
  });

  test('workspace exclusivity follows pending, retained and released phases', () async {
    final first = state.addGroup();
    final second = state.addRapidGroup();
    final a = wallet(91).address;
    final b = wallet(92).address;
    final hold = Completer<void>();
    final active = state.withWalletUse(owner: first, label: first.name, addresses: [a], action: () => hold.future);
    expect(state.workspaceBlockReason(WorkspacePage.batch), isNull);
    expect(state.workspaceBlockReason(WorkspacePage.tools), contains(first.name));
    expect(state.workspaceBlockReason(WorkspacePage.holding), contains(first.name));
    await state.withWalletUse(owner: second, label: second.name, addresses: [b], action: () async {});
    for (final owner in [state.flap, state.genius, state.four]) {
      await expectLater(state.withWalletUse(owner: owner, label: owner.label, addresses: [b],
        action: () async => fail('cross-page execution')), throwsA(isA<WorkspaceConflict>()));
    }
    hold.complete();
    await active;
    expect(state.workspaceBlockReason(WorkspacePage.tools), isNull);
    state.flap.state = LaunchState.pending;
    expect(state.workspaceBlockReason(WorkspacePage.batch), isNotNull);
    expect(state.workspaceBlockReason(WorkspacePage.flap), isNull);
    state.flap.state = LaunchState.launched;
    for (final page in [WorkspacePage.batch, WorkspacePage.tools, WorkspacePage.holding]) {
      expect(state.workspaceBlockReason(page), isNull);
    }
    expect(state.workspaceBlockReason(WorkspacePage.four), isNotNull);
    expect(state.workspaceBlockReason(WorkspacePage.genius), isNotNull);
    state.flap.reset();
    expect(state.workspaceBlockReason(WorkspacePage.genius), isNull);
  });

  testWidgets(
    'slow market read prevents duplicate start and key edits; dispose cancels preparation',
    (tester) async {
      final g = group(false);
      await mount(tester, 1440);
      api.marketGate = Completer<void>();
      await tapStart(tester, false);
      await tester.pump();
      expect(state.groupOperationBusy(g), isTrue);
      final inputKeys = tester.widget<SmallButton>(
        find.widgetWithText(SmallButton, '输入私钥'),
      );
      expect(inputKeys.onPressed, isNull);
      final start = tester.widget<PrimaryButton>(
        find.byType(PrimaryButton).first,
      );
      expect(start.onPressed, isNull);
      expect(state.tokenLockReason, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      api.marketGate!.complete();
      await tester.pumpAndSettle();
      expect(state.groupOperationBusy(g), isFalse);
      expect(state.tokenLockReason, isNull);
      expect(backend.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled slow read releases its slot; its late response and old handle cannot disturb the replacement',
    (tester) async {
      final g = group(false) as TradeGroup;
      await mount(tester, 1440);
      final firstGate = Completer<void>();
      api.marketGate = firstGate;
      await tapStart(tester, false);
      await tester.pump();
      final firstHandle = state.operationHandle(g);
      expect(firstHandle, isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(api.marketReadsStarted, 1);
      expect(firstGate.isCompleted, isFalse);
      expect(state.groupOperationBusy(g), isFalse);

      await mount(tester, 1440);
      final nextGate = Completer<void>();
      api.marketGate = nextGate;
      await tapStart(tester, false);
      await tester.pump();
      final nextHandle = state.operationHandle(g);
      expect(nextHandle, isNotNull);
      expect(identical(firstHandle, nextHandle), isFalse);
      state.cancelPreparation(g, handle: firstHandle);
      expect(state.operationHandle(g), same(nextHandle));
      expect(state.groupOperationBusy(g), isTrue);

      expect(api.marketReadsStarted, 2);
      firstGate.complete();
      await tester.pump();
      expect(state.operationHandle(g), same(nextHandle));
      expect(state.preparedReady(g), isFalse);
      expect(find.byType(UiDialog), findsNothing);
      expect(backend.routeBodies, isEmpty);
      expect(backend.submitted, isEmpty);
      nextGate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trade-token-warning')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(state.groupOperationBusy(g), isFalse);
      expect(state.tokenLockReason, isNull);
      expect(backend.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
