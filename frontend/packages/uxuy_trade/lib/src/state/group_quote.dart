part of 'app_state.dart';

/// A displayed, read-only group quote. It can only be consumed by the group and inputs that created it.
class WarmGroupQuote {
  WarmGroupQuote._(
    this.owner,
    this.identity,
    this.started,
    this.clock,
    this.market, {
    required this.needsApproval,
    this.normal,
    this.linked,
  });
  final bool needsApproval;
  final GroupBase owner;
  final String identity;
  final DateTime started;
  final DateTime Function() clock;
  final Market market;
  final PreparedRound? normal;
  final LinkedPreview? linked;
  bool get fresh => clock().difference(started) < const Duration(seconds: 15);
  bool _consumed = false;
  bool get buy => linked?.buy ?? (owner as TradeGroup).buy;
  BigInt get amount => normal?.inputTotal ?? linked!.tranche;
  double? get impact => normal?.impact ?? linked?.impact;
}

extension GroupQuotePreparation on AppState {
  String? quoteIdentity(GroupBase g) {
    final t = token;
    if (_disposed ||
        _tokenSwitching ||
        t == null ||
        !groups.contains(g) ||
        g is RapidGroup)
      return null;
    final ids = <Object?>[
      _tokenRevision,
      t.address,
      t.decimals,
      _impactSettings.bundle,
      _impactSettings.intervalStart,
      _impactSettings.intervalLive,
    ];
    if (g is TradeGroup) {
      if (g.selected.isEmpty || g.trader.unresolved.isNotEmpty) return null;
      ids.addAll([
        g.buy,
        g.ratio,
        g.min,
        g.max,
        g.mode,
        g.randomOrder,
        g.intervalMin,
        g.intervalMax,
        g.loop,
        ...g.selectedWallets.map((w) => w.address),
        g.remaining,
        g.remainingBasis,
      ]);
    } else if (g is LinkedGroup) {
      if (g.sellers.isEmpty ||
          g.buyers.isEmpty ||
          !g.transitsBackedUp ||
          g.trader.needsQuery)
        return null;
      final p = g.trader.progress;
      ids.addAll([
        g.ratio,
        g.min,
        g.max,
        g.randomOrder,
        g.intervalMin,
        g.intervalMax,
        p?.round,
        p?.phase,
        p?.sellRemaining,
        p?.buyRemaining,
        p?.finished,
        ...g.sellers.map((w) => w.address),
        'buyers',
        ...g.buyers.map((w) => w.address),
        'relays',
        ...g.transits.map((w) => w.address),
      ]);
    } else {
      return null;
    }
    return ids.join('|');
  }

  Future<WarmGroupQuote> warmGroupQuote(GroupBase group) async {
    final key = quoteIdentity(group), t = token;
    if (key == null || t == null || groupOperationBusy(group) || group.running)
      throw StateError('本组暂不可预备');
    final ordinaryPlan = group is TradeGroup
        ? group.plan(
            t.address,
            t.decimals,
            market: market,
            resume: group.remaining,
            maxImpactPercent: impactSettings.intervalLive,
          )
        : null;
    final linkedPlan = group is LinkedGroup
        ? group.plan(
            t.address,
            t.decimals,
            market: market,
            maxImpactPercent: impactSettings.bundle,
          )
        : null;
    final started = groupQuoteClock();
    final venue = Market(await api.platform(t.address));
    _validateTokenMarket(t.address, t, venue);
    final config = await api.config();
    if (venue.innerPlatform == null) config.requireUxuySwap();
    final spender = venue.innerTarget ?? config.approvalSpender!;
    final WarmGroupQuote quote;
    bool requiresApproval(
      List<WalletState> rows,
      Map<String, BigInt> amounts,
    ) => rows.any(
      (row) =>
          (row.routerAllowance ?? BigInt.zero) <
          (amounts[row.wallet.toLowerCase()] ?? BigInt.zero),
    );
    if (group is TradeGroup) {
      final plan = _tradePlan(ordinaryPlan!, venue);
      final reader = BatchTrader(api, ExecutionLog());
      try {
        final rows = await api.rapidWalletStates(
          [for (final w in plan.wallets) w.address],
          t.address,
          spender,
        );
        final preview = await reader.prepare(plan, walletSnapshot: rows);
        final needed = plan.loop
            ? {
                for (final k in preview.amounts.keys)
                  k: preview.startingBalances[k]!,
              }
            : preview.amounts;
        final grants = await reader.forecastRouteGrants(venue,plan.buy,preview.amounts,
            cycleBudget:plan.loop?preview.startingBalances:null,settlement:plan.settlement);
        final missing = await reader.checkRouteGrants(venue,plan.wallets,grants,inspectOnly:true);
        quote = WarmGroupQuote._(
          group,
          key,
          started,
          groupQuoteClock,
          venue,
          normal: preview,
          needsApproval: missing || !plan.buy && requiresApproval(rows, needed),
        );
      } finally {
        reader.dispose();
      }
    } else {
      final g = group as LinkedGroup;
      final plan = _linkedPlan(linkedPlan!, venue);
      final reader = LinkedTrader(api, ExecutionLog())
        ..progress = g.trader.progress;
      try {
        late List<WalletState> rows;
        final preview = await reader.prepare(
          plan,
          readWallets: (owners) async => rows = await api.rapidWalletStates(
            owners,
            t.address,
            spender,
          ),
        );
        final sellerRows = !preview.buy ? rows : plan.loop
            ? await api.rapidWalletStates([for (final w in plan.sellers) w.address], t.address, spender)
            : <WalletState>[];
        final needed = await reader.sellApprovalAmounts(plan, preview, sellerSnapshot: sellerRows);
        quote = WarmGroupQuote._(
          g,
          key,
          started,
          groupQuoteClock,
          venue,
          linked: preview,
          needsApproval:
              requiresApproval(sellerRows, needed) || await reader.checkLinkedGrants(plan,preview,inspectOnly:true),
        );
      } finally {
        reader.dispose();
      }
    }
    if (quoteIdentity(group) != key ||
        !quote.fresh ||
        group.running ||
        groupOperationBusy(group))
      throw StateError('本组预估已失效');
    return quote;
  }

  void _takeWarm(GroupBase g, WarmGroupQuote quote, Market market) {
    if (quote._consumed ||
        !identical(quote.owner, g) ||
        quote.identity != quoteIdentity(g) ||
        !quote.fresh ||
        !sameTradeMarket(quote.market, market)) {
      throw StateError('参数、市场或报价已变更，请重新检查');
    }
    quote._consumed = true;
  }
}
