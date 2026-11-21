import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../wallet/wallet.dart';
import 'executor.dart';
import 'market.dart';

/// A native transfer inside a relay funding plan.
class FundingTransfer {
  const FundingTransfer(this.from, this.to, this.value);
  final TradeWallet from;
  final String to;
  final BigInt value;
}

class BalanceRow {
  const BalanceRow(this.address, this.bnb, this.token);
  final String address;
  final BigInt bnb;
  final BigInt? token;
}

/// Port of the web `planTransitFunding`: one buyer/relay pair receives the aggregate shortage.
/// Existing buyer cash remains usable; seller trading gas and both transfer legs are reserved.
List<FundingTransfer> planTransitFunding({
  required BigInt amount,
  required List<TradeWallet> buyers,
  required List<TradeWallet> sellers,
  required List<TradeWallet> transits,
  required List<BalanceRow> rows,
  required BigInt gasPrice,
  required BigInt buyGas,
  required BigInt sellerGas,
}) {
  if (transits.length != buyers.length) throw StateError('买方与中转地址不匹配');
  final byAddress = {for (final r in rows) r.address.toLowerCase(): r};
  BalanceRow row(TradeWallet w) =>
      byAddress[w.address.toLowerCase()] ?? (throw StateError('中转补款余额读取不完整'));
  final buyFee = buyGas * gasPrice;
  final transferFee = BigInt.from(21000) * gasPrice;
  final buyerAvailable = [
    for (final b in buyers)
      row(b).bnb > buyFee ? row(b).bnb - buyFee : BigInt.zero,
  ];
  final available = buyerAvailable.fold(BigInt.zero, (a, b) => a + b);
  if (available >= amount) return const [];
  // Prefer a buyer already able to pay its gas, avoiding unnecessary top-ups.
  final found = buyers.indexWhere((b) => row(b).bnb >= buyFee);
  final index = max(0, found);
  final buyer = buyers[index];
  final relay = transits[index];
  final topUp =
      amount -
      available +
      (row(buyer).bnb < buyFee ? buyFee - row(buyer).bnb : BigInt.zero);
  final targetRelay = topUp + transferFee;
  var needed = targetRelay > row(relay).bnb
      ? targetRelay - row(relay).bnb
      : BigInt.zero;
  final out = <FundingTransfer>[];
  for (final seller in sellers) {
    if (needed <= BigInt.zero) break;
    final balance = row(seller);
    final keep =
        ((balance.token ?? BigInt.zero) > BigInt.zero
            ? sellerGas * gasPrice
            : BigInt.zero) +
        transferFee;
    final spendable = balance.bnb > keep ? balance.bnb - keep : BigInt.zero;
    final value = spendable < needed ? spendable : needed;
    if (value > BigInt.zero) {
      out.add(FundingTransfer(seller, relay.address, value));
      needed -= value;
    }
  }
  if (needed > BigInt.zero) throw StateError('卖方可用 BNB 不足以补足买方和中转网络费');
  // Sweep this pair's previous dust as well; the buy budget itself is unchanged.
  final forward =
      row(relay).bnb +
      out.fold(BigInt.zero, (a, t) => a + t.value) -
      transferFee;
  out.add(FundingTransfer(relay, buyer.address, forward));
  return out;
}

/// How much the sellers sell per round. [ratio]: basis points of the sellers' total holdings read when
/// the group starts (web: "按卖方启动时总持仓计算"); otherwise token base units. Each round draws once in [min, max].
class LinkedSizing {
  const LinkedSizing({
    required this.ratio,
    required this.min,
    required this.max,
  });
  LinkedSizing.percent(int bps)
    : this(ratio: true, min: BigInt.from(bps), max: BigInt.from(bps));
  final bool ratio;
  final BigInt min;
  final BigInt max;
}

typedef LinkedPreview = ({
  LinkedWalletOrder order,
  Map<String, BigInt> amounts,
  BigInt tranche,
  BigInt total,
  BigInt? expected,
  double? impact,
  bool v4,
  bool canConfirmUnknown,
  bool buy,
});

// Buyer indexes also identify their paired relay in LinkedPlan.transits.
typedef LinkedWalletOrder = ({List<int> sellers, List<int> buyers});

class LinkedPlan {
  const LinkedPlan({
    required this.token,
    required this.market,
    required this.sellers,
    required this.buyers,
    this.transits,
    required this.sizing,
    this.mode = SendMode.bundle,
    this.intervalMin = 0,
    this.intervalMax = 0,
    this.loop = true,
    this.randomOrder = false,
    this.maxImpactPercent = 20,
    this.firstLegCeiling,
    this.firstLegBuy = false,
    this.firstLegAllowUnknown = false,
    this.savedRouter,
  });

  final String token;
  final Market? market;
  final List<TradeWallet> sellers;
  final List<TradeWallet> buyers;

  /// One relay per buyer (optional): pays a buyer's shortage from the sellers' BNB.
  final List<TradeWallet>? transits;
  final LinkedSizing sizing;
  final SendMode mode;
  final num intervalMin;
  final num intervalMax;

  /// Web linked groups always loop until the sellers' holdings are used up.
  final bool loop;
  final bool randomOrder;
  final double maxImpactPercent;
  final double? firstLegCeiling;
  final bool firstLegBuy, firstLegAllowUnknown;
  final String? savedRouter;
}

/// A submitted phase whose transactions are not all settled yet; accounted once after a query.
class _Active {
  _Active(this.buy, this.token, List<String> hashes)
    : hashes = List.unmodifiable(hashes);
  final bool buy;
  final String token;
  final List<String> hashes;
}

class _AccountingRetry {
  _AccountingRetry(this.progress, this.leg);
  final LinkedProgress progress;
  final _Active leg;
  final foreground = Completer<BigInt?>();
  Timer? timer;
  Future<void>? inFlight;
  bool scheduledAttempt = false;
  int failedRetries = 0;
  int nextSeconds = 1;
  bool get warned => failedRetries >= 3;
  void detach() {
    if (!foreground.isCompleted) foreground.complete(null);
  }
}

/// Round state kept across pauses and stops (web LinkedRuntime): continue the round or end it.
class LinkedProgress {
  int round = 1;
  String phase = 'sell';
  BigInt rangeMin = BigInt.zero;
  BigInt rangeMax = BigInt.zero;
  BigInt tranche = BigInt.zero;
  BigInt sellRemaining = BigInt.zero;
  BigInt buyRemaining = BigInt.zero;

  /// BNB received in the current round: reference for the tiny buy-back tail.
  BigInt roundReceived = BigInt.zero;
  BigInt sold = BigInt.zero;
  BigInt received = BigInt.zero;
  BigInt spent = BigInt.zero;
  bool started = false;
  bool finished = false;
  bool stopped = false;
  String? router;
  LinkedWalletOrder? _order;
  _Active? _active;
  final List<String> _funding = [];
}

/// Web `isSmallTradeRemainder`: below one millionth of its reference (buys also at most 1e10 wei).
bool isSmallRemainder(BigInt amount, BigInt reference, {bool buy = false}) =>
    amount > BigInt.zero &&
    amount * BigInt.from(1000000) <= reference &&
    (!buy || amount <= BigInt.from(10000000000));

/// Linked group ("先卖后买"): sellers sell a tranche, buyers buy back with the BNB actually received.
class LinkedTrader extends ChangeNotifier {
  LinkedTrader(
    this.api,
    this.log, {
    this.label = '',
    Sleep? sleep,
    Timer Function(Duration, void Function()) retryTimer = Timer.new,
    Random? random,
    Duration pollEvery = const Duration(seconds: 2),
  }) : _retryTimer = retryTimer,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random.secure(),
       trader = BatchTrader(
         api,
         log,
         label: label,
         sleep: sleep,
         random: random,
         pollEvery: pollEvery,
         // The linked group reconciles the sale before allocating buyback funds.
         recordSaleProceeds: false,
       );

  final BackendClient api;
  final ExecutionLog log;
  final String label;
  final BatchTrader trader;
  final Sleep _sleep;
  final Random _random;

  bool running = false;
  bool _paused = false;
  bool _cancel = false;
  bool _disposed = false;

  /// Current round; null when no round is open. Survives stop so the round can be continued.
  LinkedProgress? progress;
  String? error;

  final Timer Function(Duration, void Function()) _retryTimer;
  _AccountingRetry? _recovery;

  bool get reconciling => _recovery != null;
  bool get reconciliationWarning => _recovery?.warned ?? false;
  bool get paused => _paused;

  Iterable<String> get unsettledHashes => {
    ...trader.unresolved,
    ...?progress?._funding,
    ...?progress?._active?.hashes,
  };

  /// Submitted transactions without a final status: only a read-only query may continue.
  bool get needsQuery =>
      trader.pendingRemainderHashes.isNotEmpty ||
      reconciling ||
      trader.unresolved.isNotEmpty ||
      (progress?._funding.isNotEmpty ?? false) ||
      progress?._active != null;

  /// A stopped round that can be continued or ended.
  bool get resumable => !running && progress != null && !progress!.finished;

  void _log(String text, {LogLevel level = LogLevel.info}) {
    if (!_disposed)
      log.add(label.isEmpty ? text : '$label $text', level: level);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void pause() {
    _paused = true;
    trader.pause();
    _changed();
  }

  void resume() {
    _paused = false;
    trader.resume();
    _changed();
  }

  void cancel() {
    if (running) _cancel = true;
    _recovery?.detach();
    _paused = false;
    trader.cancel();
    _changed();
  }

  /// End the open round (web "结束本轮"): confirmed trades stay, the remaining buy-back is dropped.
  void finish() {
    if (running) throw StateError('请先停止');
    if (needsQuery) throw StateError('请先查询原交易');
    final p = progress;
    if (p != null && !p.finished) {
      _log(
        '已结束关联组：未买回 ${formatUnits(p.buyRemaining, 18)} BNB；已成交交易不撤销',
        level: LogLevel.error,
      );
    }
    progress = null;
    error = null;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel = true;
    _recovery?.timer?.cancel();
    _recovery?.detach();
    _recovery = null;
    trader.dispose();
    super.dispose();
  }

  BigInt _cap(BigInt amount, BigInt limit) => amount < limit ? amount : limit;

  BigInt _draw(BigInt lo, BigInt hi) => sampleTradeAmount(_random, lo, hi);

  ({BigInt min, BigInt max, BigInt tranche, BigInt total})? _prepared;

  int _prepareVersion = 0;
  BigInt? _nextTranche;
  LinkedWalletOrder? _preparedOrder;
  Map<String, BigInt>? _preparedAmounts;

  LinkedWalletOrder _drawOrder(LinkedPlan plan) {
    List<int> order(int length) {
      final indexes = List<int>.generate(length, (i) => i);
      if (plan.randomOrder) indexes.shuffle(_random);
      return List.unmodifiable(indexes);
    }
    return (sellers: order(plan.sellers.length), buyers: order(plan.buyers.length));
  }

  /// Cancelled confirmations must not supply an old draw to a later operation.
  void discardPrepared() {
    _prepareVersion++;
    if (!running) {
      _prepared = null;
      _nextTranche = null;
      _preparedOrder = null;
      _preparedAmounts = null;
    }
  }

  Map<String, BigInt> _allocate(
    List<WalletState> rows,
    List<BigInt> available,
    BigInt target, {Market? selling}
  ) {
    final amounts = <String, BigInt>{};
    var remaining = target;
    for (var i = 0; i < rows.length && remaining > BigInt.zero; i++) {
      final limit = remaining < available[i] ? remaining : available[i];
      final amount = selling?.sellUnits(limit) ?? limit;
      if (amount > BigInt.zero) amounts[rows[i].wallet.toLowerCase()] = amount;
      remaining -= amount;
    }
    return amounts;
  }

  /// Draw the first tranche and quote it (web "首轮卖出" / "首批预计到账"); [run] then sells exactly this tranche.
  Future<List<BigInt>> _buyerCash(LinkedPlan plan,List<WalletState> rows,GasInfo gas,BigInt target) {
    final exact = {for (final row in rows) row.wallet.toLowerCase(): _cap(row.native, target)};
    return trader.linkedBuyerCash(_plan(plan,plan.buyers,true,exact),rows,gas);
  }

  Future<LinkedPreview> prepare(LinkedPlan plan,{Future<List<WalletState>> Function(List<String>)? readWallets}) async {
    if (running) throw StateError('本组正在执行');
    if (needsQuery) throw StateError('请先查询原交易，核清实际到账');
    final s = plan.sizing;
    if (s.min < BigInt.zero || s.max <= BigInt.zero ||
        s.max < s.min ||
        (s.ratio && s.max > BigInt.from(10000))) {
      throw const FormatException('每轮总卖出需大于 0，最小不大于最大，比例不超过 100%');
    }
    final version = ++_prepareVersion;
    final open = progress != null && !progress!.finished ? progress : null;
    final nextRound =
        open != null &&
        open.sellRemaining == BigInt.zero &&
        open.buyRemaining == BigInt.zero;
    final buy =
        open != null &&
        !nextRound &&
        (open.phase == 'buy' || open.sellRemaining == BigInt.zero);
    final order = (nextRound ? null : open?._order) ?? _drawOrder(plan);
    final wallets = buy ? [for (final i in order.buyers) plan.buyers[i]] : [for (final i in order.sellers) plan.sellers[i]];
    final (rows, gas) = await (
      readWallets==null ? api.walletStates([for (final w in wallets) w.address], token: plan.token) : readWallets([for(final w in wallets) w.address]),
      api.gas(),
    ).wait;
    if (_prepareVersion != version) throw StateError('准备结果已失效');
    final available = buy ? await _buyerCash(plan,rows,gas,open.buyRemaining)
        : [for(final row in rows) row.tokenBalance??BigInt.zero];
    if (_prepareVersion != version) throw StateError('准备结果已失效');
    final total = available.fold(BigInt.zero, (a, b) => a + b);
    BigInt cap(BigInt v) => v < total ? v : total;
    final BigInt tranche;
    if (nextRound) {
      tranche = cap(_draw(open.rangeMin, open.rangeMax));
      _nextTranche = tranche;
    } else if (open != null) {
      tranche = cap(buy ? open.buyRemaining : open.sellRemaining);
      if (buy && tranche == BigInt.zero && plan.transits != null) {
        // Funding can still proceed after an interrupted relay. Its buy quote must pass
        // the ordinary live guard; an unavailable preview cannot raise its ceiling.
        _preparedOrder = order;
        return (
          order: order,
          amounts: const <String, BigInt>{},
          tranche: open.buyRemaining,
          total: total,
          expected: null,
          impact: null,
          v4: false,
          canConfirmUnknown: false,
          buy: true,
        );
      }
    } else {
      final lo = cap(s.ratio ? total * s.min ~/ BigInt.from(10000) : s.min);
      final hi = cap(s.ratio ? total * s.max ~/ BigInt.from(10000) : s.max);
      tranche = _draw(lo, hi);
      _prepared = (min: lo, max: hi, tranche: tranche, total: total);
    }
    if (tranche <= BigInt.zero) throw StateError(buy ? '买方没有可用余额' : '卖方没有可卖持仓');
    final exact = _allocate(rows, available, tranche, selling: buy ? null : plan.market);
    final quoted = await trader.prepare(
      _plan(plan, wallets, buy, exact),
      walletSnapshot: rows,
    );
    if (_prepareVersion != version) throw StateError('准备结果已失效');
    _preparedOrder = order;
    _preparedAmounts = quoted.amounts;
    return (
      order: order,
      tranche: tranche,
      total: total,
      amounts: quoted.amounts,
      expected: quoted.quotedOutput,
      impact: quoted.impact,
      v4: quoted.v4ImpactUnavailable,
      canConfirmUnknown: quoted.canConfirmUnknown,
      buy: buy,
    );
  }

  Future<Map<String, BigInt>> sellApprovalAmounts(
    LinkedPlan plan,
    LinkedPreview preview, {
    List<WalletState>? sellerSnapshot,
  }) async {
    if (!plan.loop) return preview.buy ? {} : preview.amounts;
    final rows =
        sellerSnapshot ??
        await api.walletStates([
          for (final w in plan.sellers) w.address,
        ], token: plan.token);
    final holdings = {
      for (final r in rows) r.wallet.toLowerCase(): r.tokenBalance,
    };
    final amounts = <String, BigInt>{};
    for (final w in plan.sellers) {
      final key = w.address.toLowerCase(), amount = holdings[key];
      if (amount == null) throw StateError('卖方持仓读取不完整，请重新检查');
      if (amount > BigInt.zero) amounts[key] = amount;
    }
    return amounts;
  }

  Future<bool> checkLinkedGrants(
    LinkedPlan plan,
    LinkedPreview preview, {
    bool inspectOnly = false,
    bool allowSubmit = true,
    bool Function()? active,
  }) async {
    final market = plan.market;
    if (market?.innerPlatform == null) return false;
    var need = false;
    if (!preview.buy || plan.loop) {
      final bounds = await sellApprovalAmounts(plan, preview);
      final first = <String, BigInt>{if (!preview.buy) ...preview.amounts};
      for (final e in bounds.entries) {
        final candidate = market!.sellUnits(preview.buy ? e.value : _cap(preview.tranche, e.value));
        if (candidate > BigInt.zero) first.putIfAbsent(e.key, () => candidate);
      }
      final grants = await trader.forecastRouteGrants(
        market,
        false,
        first,
        cycleBudget: bounds,
      );
      need = await trader.checkRouteGrants(
        market,
        plan.sellers,
        grants,
        inspectOnly: inspectOnly,
        allowSubmit: allowSubmit,
        active: active,
      );
    }
    if (preview.buy || preview.expected != null) {
      final Map<String, BigInt> orders, budget;
      if (preview.buy) {
        orders = preview.amounts;
        budget = orders;
      } else {
        final rows = await api.walletStates([
          for (final i in preview.order.buyers) plan.buyers[i].address,
        ], token: plan.token);
        final gas = await api.gas();
        final target = preview.expected!;
        final limit = plan.loop && preview.tranche > BigInt.zero
            ? (target * preview.total + preview.tranche - BigInt.one) ~/ preview.tranche
            : target;
        final capacities = await _buyerCash(plan, rows, gas, target);
        final cash = capacities.fold(BigInt.zero, (sum, n) => sum + n);
        if (plan.transits != null && cash < limit) {
          final fee = BigInt.from(BatchTrader.initialGas(plan.market)) * gas.gasPrice;
          final recipient = max(0, rows.indexWhere((row) => row.native >= fee));
          capacities[recipient] += limit - cash;
        }
        budget = plan.loop && plan.randomOrder
            ? {for (var i = 0; i < rows.length; i++)
                if (capacities[i] > BigInt.zero) rows[i].wallet.toLowerCase(): _cap(limit, capacities[i])}
            : _allocate(rows, capacities, limit);
        orders = {for (final e in budget.entries) e.key: _cap(target, e.value)};
      }
      if (orders.isNotEmpty) {
        final grants = await trader.forecastRouteGrants(
          market,
          true,
          orders,
          cycleBudget: budget,
        );
        need =
            await trader.checkRouteGrants(
              market,
              plan.buyers,
              grants,
              inspectOnly: inspectOnly,
              allowSubmit: allowSubmit,
              active: active,
            ) ||
            need;
      }
    }
    return need;
  }

  /// Use the exact read-only tranche displayed to the user on the active group.
  void adoptPreview(LinkedPlan plan,LinkedPreview preview) {
    discardPrepared();
    _preparedOrder = preview.order;
    if (preview.amounts.isNotEmpty) _preparedAmounts = preview.amounts;
    final open=progress;
    if(open==null||open.finished){
      final s=plan.sizing,total=preview.total;
      BigInt bound(BigInt value){
        final n=s.ratio?total*value~/BigInt.from(10000):value;
        return n<total?n:total;
      }
      _prepared=(min:bound(s.min),max:bound(s.max),tranche:preview.tranche,total:total);
    } else if(open.sellRemaining==BigInt.zero && open.buyRemaining==BigInt.zero) {
      _nextTranche=preview.tranche;
    }
  }

  bool _firstLeg = false;

  Future<TradeOutcome> _runLeg(
    LinkedProgress progress,
    LinkedPlan plan,
    List<TradeWallet> wallets,
    bool buy,
    Map<String, BigInt> exact,
  ) async {
    await _waitWhilePaused();
    if (_cancel) return TradeOutcome()..stopped = true;
    final accepted = _firstLeg && buy == plan.firstLegBuy;
    if (_firstLeg && _preparedAmounts != null && !mapEquals(_preparedAmounts, exact)) {
      throw StateError('首批钱包或可执行金额已变化，请重新检查');
    }
    _preparedAmounts = null;
    _firstLeg = false;
    final previous = trader.last;
    var returned = false;
    try {
      final out = await trader.run(
        _plan(plan, wallets, buy, exact, accepted: accepted),
      );
      returned = true;
      return out;
    } finally {
      // BatchTrader preserves the partial outcome even if a later wallet fails.
      final out = trader.last;
      if (out != null &&
          !identical(out, previous) &&
          out.tradeHashes.isNotEmpty) {
        progress._active = _Active(buy, plan.token, out.tradeHashes);
        if (!returned && trader.unresolved.isEmpty) await _settle(progress);
      }
    }
  }

  /// Start a new round, or continue the open one with the same wallets.
  Future<LinkedProgress> run(LinkedPlan plan) async {
    if (running) throw StateError('本组正在执行');
    if (needsQuery) throw StateError('请先查询原交易，核清实际到账');
    if (plan.sellers.isEmpty || plan.buyers.isEmpty) {
      throw StateError('买卖两侧都需要钱包');
    }
    final all = [...plan.sellers, ...plan.buyers, ...?plan.transits];
    if ({for (final w in all) w.address.toLowerCase()}.length != all.length) {
      throw StateError('买卖两侧的钱包不能重复');
    }
    final s = plan.sizing;
    if (s.min < BigInt.zero || s.max <= BigInt.zero ||
        s.max < s.min ||
        (s.ratio && s.max > BigInt.from(10000))) {
      throw const FormatException('每轮总卖出需大于 0，最小不大于最大，比例不超过 100%');
    }
    final transits = plan.transits;
    if (transits != null) {
      if (transits.length != plan.buyers.length) {
        throw StateError('中转地址数量需与买方相同');
      }
      if (transits.any((t) => !t.canReceiveFunds)) {
        throw StateError('中转私钥尚未复制保存，不能接收资金');
      }
    }
    running = true;
    _firstLeg = true;
    _cancel = false;
    _paused = false;
    error = null;
    _changed();
    var p = progress;
    try {
      if (p == null || p.finished) {
        final prepared = _prepared;
        _prepared = null;
        final BigInt total;
        p = progress = LinkedProgress()..router = plan.savedRouter;
        if (prepared != null) {
          total = prepared.total;
          p.rangeMin = prepared.min;
          p.rangeMax = prepared.max;
          p.tranche = prepared.tranche;
        } else {
          final start = await api.walletStates([
            for (final w in plan.sellers) w.address,
          ], token: plan.token);
          total = start.fold(
            BigInt.zero,
            (a, x) => a + (x.tokenBalance ?? BigInt.zero),
          );
          if (total == BigInt.zero) throw StateError('卖方没有可卖持仓');
          BigInt cap(BigInt v) => v < total ? v : total;
          p.rangeMin = cap(
            s.ratio ? total * s.min ~/ BigInt.from(10000) : s.min,
          );
          p.rangeMax = cap(
            s.ratio ? total * s.max ~/ BigInt.from(10000) : s.max,
          );
          p.tranche = _draw(p.rangeMin, p.rangeMax);
        }
        if (p.tranche == BigInt.zero) {
          throw StateError('卖方没有足够的可卖代币，请检查余额或提高比例');
        }
        p.sellRemaining = p.tranche;
        _log(
          '关联组开始：第 1 轮卖出 ${formatUnits(p.tranche, plan.market?.decimals ?? 18)}（卖方启动时总持仓 ${formatUnits(total, plan.market?.decimals ?? 18)}）',
        );
      } else {
        p.stopped = false;
        _log(
          '继续第 ${p.round} 轮：待卖 ${formatUnits(p.sellRemaining, plan.market?.decimals ?? 18)} · 待买回 ${formatUnits(p.buyRemaining, 18)} BNB',
        );
      }
      p._order ??= _preparedOrder ?? _drawOrder(plan);
      if (_nextTranche == null) _preparedOrder = null;
      p.started = true;
      _changed();
      await _loop(plan, p);
    } on BackendException catch (e) {
      error = e.message;
    } on StateError catch (e) {
      error = e.message;
    } on FormatException catch (e) {
      error = e.message;
    } finally {
      if (error != null) {
        if (!reconciliationWarning) _log(error!, level: LogLevel.error);
        p?.stopped = true;
      }
      if (_cancel && p != null && !p.finished) {
        p.stopped = true;
        _log('关联组已停止：未提交的交易不再发送，本轮进度保留', level: LogLevel.error);
      }
      running = false;
      _paused = false;
      _changed();
    }
    return p!;
  }

  Future<void> _loop(LinkedPlan plan, LinkedProgress p) async {
    final decimals = plan.market?.decimals ?? 18;
    while (!_cancel) {
      await _waitWhilePaused();
      if (_cancel) return;
      if (p.phase == 'sell' && p.sellRemaining == BigInt.zero) {
        p.phase = 'buy';
        _changed();
      }
      if (p.phase == 'buy' && p.buyRemaining == BigInt.zero) {
        _log(
          '第 ${p.round} 轮完成：卖出共 ${formatUnits(p.sold, decimals)}，到账 ${formatUnits(p.received, 18)} BNB，买回 ${formatUnits(p.spent, 18)} BNB',
          level: LogLevel.success,
        );
        if (!plan.loop) {
          p.finished = true;
          return;
        }
        if (_cancel) return;
        p.round++;
        p._order = _preparedOrder ?? _drawOrder(plan);
        _preparedOrder = null;
        p.phase = 'sell';
        p.tranche = _nextTranche ?? _draw(p.rangeMin, p.rangeMax);
        _nextTranche = null;
        p.sellRemaining = p.tranche;
        p.roundReceived = BigInt.zero;
        _changed();
      }
      if (p.phase == 'sell') {
        if (!await _sell(plan, p)) return;
      } else {
        await _buy(plan, p);
      }
      if (_cancel || p.finished || p.stopped) return;
      await _interval(plan);
    }
  }

  /// Returns false when the group finished (sellers empty).
  Future<bool> _sell(LinkedPlan plan, LinkedProgress p) async {
    final decimals = plan.market?.decimals ?? 18;
    if (isSmallRemainder(p.sellRemaining, p.tranche)) {
      _log('第 ${p.round} 轮 · 极小卖出尾数无法成交，已保留在原钱包');
      p.sellRemaining = BigInt.zero;
      return true;
    }
    final sellers = [for (final i in p._order!.sellers) plan.sellers[i]];
    final before = await api.walletStates([
      for (final w in sellers) w.address,
    ], token: plan.token);
    await _waitWhilePaused();
    if (_cancel) return false;
    final held = before.fold(
      BigInt.zero,
      (a, x) => a + (x.tokenBalance ?? BigInt.zero),
    );
    if (held == BigInt.zero) {
      p.sellRemaining = BigInt.zero;
      if (p.buyRemaining > BigInt.zero) return true;
      p.finished = true;
      _log('关联组已完成，卖方可卖余额已清空', level: LogLevel.success);
      return false;
    }
    final target = p.sellRemaining < held ? p.sellRemaining : held;
    if (target == held && isSmallRemainder(held, p.tranche)) {
      // Only dust is left in the sellers' wallets: it cannot trade, keep it (web: 极小尾数保留在原钱包).
      p.sellRemaining = BigInt.zero;
      if (p.buyRemaining > BigInt.zero) return true;
      p.finished = true;
      _log('关联组已完成，极小尾数保留在原钱包', level: LogLevel.success);
      return false;
    }
    final exact = _allocate(before, [
      for (final row in before) row.tokenBalance ?? BigInt.zero,
    ], target, selling: plan.market);
    if (exact.isEmpty) {
      if (before.any((r) => (plan.market?.sellUnits(r.tokenBalance ?? BigInt.zero) ?? r.tokenBalance ?? BigInt.zero) > BigInt.zero)) {
        throw StateError('本轮卖量低于最小交易单位，请调整每轮卖出数量');
      }
      p.sellRemaining = BigInt.zero;
      p.finished = p.buyRemaining == BigInt.zero;
      _log('卖方剩余持仓均低于最小卖出单位，已保留在原钱包');
      return !p.finished;
    }
    _log(
      '第 ${p.round} 轮 · 卖出 ${formatUnits(target, decimals)}，${exact.length} 个钱包',
    );
    final out = await _runLeg(p, plan, sellers, false, exact);
    if (trader.unresolved.isNotEmpty) {
      throw StateError('有卖出交易尚未确认，请查询原交易，不会重复发送');
    }
    final sold = await _settle(p);
    if (sold == null) return false;
    if (sold == BigInt.zero && out.confirmed == 0 && !out.stopped) {
      throw StateError('第 ${p.round} 轮卖出未成交，已停止');
    }
    if (out.stopped && !_cancel) throw StateError('第 ${p.round} 轮卖出未完成，已暂停');
    return true;
  }

  Future<void> _buy(LinkedPlan plan, LinkedProgress p) async {
    if (isSmallRemainder(p.buyRemaining, p.roundReceived, buy: true)) {
      _log('第 ${p.round} 轮 · 极小待买回金额无法成交，已保留在原钱包');
      p.buyRemaining = BigInt.zero;
      return;
    }
    final gas = await api.gas();
    if (_cancel) return;
    final buyers = [for (final i in p._order!.buyers) plan.buyers[i]];
    final transits = plan.transits;
    if (transits != null) {
      final rowsRaw = await api.walletStates([
        for (final w in [...plan.sellers, ...plan.buyers, ...transits])
          w.address,
      ], token: plan.token);
      await _waitWhilePaused();
      if (_cancel) return;
      final funding = planTransitFunding(
        amount: p.buyRemaining,
        buyers: buyers,
        sellers: [for (final i in p._order!.sellers) plan.sellers[i]],
        transits: [for (final i in p._order!.buyers) transits[i]],
        rows: [
          for (final r in rowsRaw)
            BalanceRow(r.wallet, r.native, r.tokenBalance),
        ],
        gasPrice: gas.gasPrice,
        buyGas: BigInt.from(BatchTrader.initialGas(plan.market)),
        sellerGas: BigInt.from(BatchTrader.initialGas(plan.market,buy:false)),
      );
      if (funding.isNotEmpty) {
        _log('第 ${p.round} 轮 · 买方 BNB 不足，正在中转补款');
        await _fund(p, funding, rowsRaw, gas);
      }
    }
    await _waitWhilePaused();
    if (_cancel) return;
    final before = await api.walletStates([
      for (final b in buyers) b.address,
    ], token: plan.token);
    await _waitWhilePaused();
    if (_cancel) return;
    final spendable = await _buyerCash(plan,before,gas,p.buyRemaining);
    if (_cancel) return;
    final totalCash = spendable.fold(BigInt.zero, (a, b) => a + b);
    if (totalCash == BigInt.zero) {
      throw StateError(
        '买方可用 BNB 不足，待买回 ${formatUnits(p.buyRemaining, 18)} BNB；补充后继续本轮',
      );
    }
    final need = p.buyRemaining;
    final target = totalCash < need ? totalCash : need;
    final exact = _allocate(before, spendable, target);
    _log(
      '第 ${p.round} 轮 · 买回 ${formatUnits(target, 18)} BNB，${exact.length} 个钱包',
    );
    final out = await _runLeg(p, plan, buyers, true, exact);
    if (trader.unresolved.isNotEmpty) {
      throw StateError('有买入交易尚未确认，请查询原交易，不会重复发送');
    }
    final spent = await _settle(p);
    if (spent == null) return;
    if (spent == BigInt.zero && out.confirmed == 0 && !out.stopped) {
      throw StateError('第 ${p.round} 轮买入未成交，已停止');
    }
    if (out.stopped && !_cancel) throw StateError('第 ${p.round} 轮买入未完成，已暂停');
    if (target < need &&
        p.buyRemaining > BigInt.zero &&
        !isSmallRemainder(p.buyRemaining, p.roundReceived, buy: true)) {
      throw StateError(
        '买方可用 BNB 不足，待买回 ${formatUnits(p.buyRemaining, 18)} BNB；补充后继续本轮',
      );
    }
  }

  /// Hold the submitted leg until the receipts for these exact hashes can be accounted once.
  Future<BigInt?> _settle(LinkedProgress p) async {
    final leg = p._active;
    if (leg == null) return BigInt.zero;
    try {
      return await _account(p, leg);
    } catch (_) {
      if (_disposed) return null;
      final recovery = _recovery = _AccountingRetry(p, leg);
      if (_cancel) recovery.detach();
      _scheduleRetry(recovery);
      _changed();
      return recovery.foreground.future;
    }
  }

  void _scheduleRetry(_AccountingRetry recovery) {
    recovery.timer = _retryTimer(Duration(seconds: recovery.nextSeconds), () {
      unawaited(_retry(recovery, scheduled: true));
    });
  }

  Future<void> _retry(_AccountingRetry recovery, {bool scheduled = false}) {
    if (!identical(_recovery, recovery)) return Future.value();
    // A manual read neither postpones nor duplicates an automatic attempt.
    if (scheduled) recovery.scheduledAttempt = true;
    final inFlight = recovery.inFlight;
    if (inFlight != null) return inFlight;
    final attempt = Completer<void>();
    recovery.inFlight = attempt.future;
    () async {
      try {
        final amount = await _account(recovery.progress, recovery.leg);
        if (!identical(_recovery, recovery)) return;
        recovery.timer?.cancel();
        _recovery = null;
        error = null;
        if (recovery.foreground.isCompleted) {
          _log('原交易对账完成，可继续本轮', level: LogLevel.success);
        } else {
          recovery.foreground.complete(amount);
        }
      } catch (e) {
        if (!identical(_recovery, recovery)) return;
        if (recovery.scheduledAttempt) {
          recovery.failedRetries++;
          recovery.nextSeconds = min(1800, recovery.nextSeconds * 2);
          if (recovery.failedRetries == 3) {
            final reason = e is BackendException ? e.message : e.toString();
            error = '原交易对账连续 3 次重试失败，已暂停交易，将继续自动核对：$reason';
            recovery.progress.stopped = true;
            _log(error!, level: LogLevel.error);
            recovery.detach();
          }
          _scheduleRetry(recovery);
        }
      } finally {
        recovery.scheduledAttempt = false;
        recovery.inFlight = null;
        attempt.complete();
        _changed();
      }
    }();
    return attempt.future;
  }

  Future<BigInt> _account(LinkedProgress p, _Active a) async {
    final delta = await api.linkedTradeDelta(
      a.hashes,
      token: a.token,
      buy: a.buy,
    );
    if (_disposed || !identical(p._active, a)) throw StateError('原交易对账已结束');
    p._active = null;
    if (!a.buy) {
      final sold = (delta.tokens < p.sellRemaining
          ? delta.tokens
          : p.sellRemaining);
      p.sellRemaining -= sold;
      p.buyRemaining += delta.native;
      p.received += delta.native;
      p.roundReceived += delta.native;
      p.sold += delta.tokens;
      _log(
        '第 ${p.round} 轮 · 卖出到账 ${formatUnits(delta.native, 18)} BNB · 待买回 ${formatUnits(p.buyRemaining, 18)} BNB',
        level: LogLevel.success,
      );
      _changed();
      return delta.tokens;
    }
    p.buyRemaining -= (delta.native < p.buyRemaining
        ? delta.native
        : p.buyRemaining);
    p.spent += delta.native;
    _log(
      '第 ${p.round} 轮 · 买入 ${delta.tokens} 单位代币，使用 ${formatUnits(delta.native, 18)} BNB · 待买回 ${formatUnits(p.buyRemaining, 18)} BNB',
      level: LogLevel.success,
    );
    _changed();
    return delta.native;
  }

  /// Read-only recovery (web "查询原交易"): settles unknown statuses, never resends.
  Future<void> query([LinkedPlan? plan]) async {
    final recovery = _recovery;
    if (recovery != null) return _retry(recovery);
    if (running) throw StateError('本组正在执行');
    final p = progress;
    running = true;
    _changed();
    try {
      _log('正在查询原交易与实际到账，不会重复发送');
      await trader.query();
      if (p != null && p._funding.isNotEmpty) {
        for (final h in List.of(p._funding)) {
          final r = await api.reconcileStatus(h);
          if (r.finished) {
            p._funding.remove(h);
            if (r.status != 'confirmed') {
              _log(
                '中转补款 ${h.substring(0, 10)}… ${r.status}',
                level: LogLevel.error,
              );
            }
          }
        }
      }
      if (trader.unresolved.isEmpty && p?._active != null) {
        if (await _settle(p!) == null) return;
      }
      if (needsQuery) {
        _log('仍有交易未确认，请稍后继续查询', level: LogLevel.error);
      } else {
        error = null;
        _log('原交易已核清，可继续本轮', level: LogLevel.success);
      }
    } finally {
      running = false;
      _changed();
    }
  }

  TradePlan _plan(
    LinkedPlan p,
    List<TradeWallet> wallets,
    bool buy,
    Map<String, BigInt> exact, {
    bool accepted = false,
  }) => TradePlan(
    token: p.token,
    buy: buy,
    wallets: wallets,
    mode: p.mode,
    amount: AmountRule(ratio: false, min: BigInt.one, max: BigInt.one),
    exact: exact,
    intervalMin: p.intervalMin,
    intervalMax: p.intervalMax,
    market: p.market,
    maxImpactPercent: accepted
        ? (p.firstLegCeiling ?? p.maxImpactPercent)
        : p.maxImpactPercent,
    allowUnknownImpact: accepted && p.firstLegAllowUnknown,
  );

  Future<void> _waitWhilePaused() async {
    while (_paused && !_cancel) {
      await _sleep(const Duration(milliseconds: 300));
    }
  }

  Future<void> _interval(LinkedPlan p) async {
    final delay = randomGroupInterval(_random,p.intervalMin,p.intervalMax);
    await trader.waitSubmissionInterval(delay);
  }

  /// Seller -> relay -> buyer, in one private bundle (order preserved inside the block).
  Future<void> _fund(
    LinkedProgress p,
    List<FundingTransfer> transfers,
    List<WalletState> rows,
    GasInfo gas,
  ) async {
    if (_cancel) return;
    final nonces = {for (final r in rows) r.wallet.toLowerCase(): r.nonce};
    final raws = <String>[];
    final hashes = <String>[];
    for (final t in transfers) {
      final key = t.from.address.toLowerCase();
      final nonce = nonces[key]!;
      nonces[key] = nonce + 1;
      final tx = api.sign(
        t.from,
        LegacyTx(
          nonce: nonce,
          gasPrice: gas.gasPrice,
          gasLimit: 21000,
          to: checksumAddress(t.to),
          value: t.value,
          data: Uint8List(0),
        ),
      );
      raws.add(tx.raw);
      hashes.add(tx.hash);
    }
    p._funding.addAll(hashes);
    trader.markSubmission();
    await api.groupBundle(raws, gas.blockNumber + BackendClient.groupWindowBlocks, active: () => !_cancel && !_paused && !_disposed);
    for (final h in hashes) {
      var done = false;
      for (var i = 0; i < 90 && !done; i++) {
        final r = await api.status(h);
        if (r.finished) {
          p._funding.remove(h);
          if (r.status != 'confirmed') {
            throw StateError('中转补款未成功（${r.status}），已停止');
          }
          done = true;
        } else {
          await _sleep(const Duration(seconds: 1));
        }
      }
      if (!done) throw StateError('中转补款尚未确认，已停止，请查询原交易');
    }
    _log('中转补款完成：${transfers.length} 笔');
  }
}
