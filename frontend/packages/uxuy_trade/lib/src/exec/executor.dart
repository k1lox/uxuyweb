import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../crypto/keccak.dart';
import '../evm/evm.dart';
import '../wallet/wallet.dart';
import 'market.dart';
import 'inner_route.dart';

part 'trade_approvals.dart';

part 'rapid.dart';
part 'bundle_receipts.dart';
part 'inner_remainders.dart';

/// Real-time execution log. Entries contain hashes and amounts, never keys or raw transactions.
class ExecutionLog extends ChangeNotifier {
  final List<LogEntry> entries = [];
  void Function(LogEntry entry)? onRecord;
  Future<String> Function()? readHistory;

  void add(String text, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(DateTime.now(), text, level);
    entries.add(entry);
    onRecord?.call(entry);
    if (entries.length > 2000) entries.removeRange(0, entries.length - 2000);
    notifyListeners();
  }

  void clear() {
    entries.clear();
    notifyListeners();
  }
}

enum LogLevel { info, success, error }

class LogEntry {
  const LogEntry(this.time, this.text, this.level);
  final DateTime time;
  final String text;
  final LogLevel level;
}

enum SendMode { bundle, interval }

num? parseGroupSeconds(String text) {
  final value = text.trim();
  if (!RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(value)) return null;
  final parsed = num.tryParse(value);
  return parsed != null && parsed <= 86400 ? parsed : null;
}

Duration randomGroupInterval(Random random, num lower, num upper) {
  final lo = (lower * 1000).round(), hi = (upper * 1000).round();
  return Duration(milliseconds: hi <= lo ? lo : lo + random.nextInt(hi - lo + 1));
}

BigInt sampleTradeAmount(Random random, BigInt lower, BigInt upper) {
  if (upper <= BigInt.zero) return BigInt.zero;
  final lo = lower > BigInt.zero ? lower : BigInt.one;
  if (upper <= lo) return upper;
  final span = upper - lo + BigInt.one;
  final bits = (span - BigInt.one).bitLength;
  while (true) {
    var draw = BigInt.zero;
    for (var left = bits; left > 0; left -= 24) {
      final width = min(left, 24);
      draw = (draw << width) | BigInt.from(random.nextInt(1 << width));
    }
    if (draw < span) return lo + draw;
  }
}

/// How much each wallet trades.
/// [ratio]: basis points (1..10000) of the wallet's starting balance, capped by the funds available in each round.
/// Otherwise raw units: wei of BNB for buys, token base units for sells.
class AmountRule {
  const AmountRule({required this.ratio, required this.min, required this.max});
  final bool ratio;
  final BigInt min;
  final BigInt max;
}

/// Builder tip (web bscBundleTip): a plain BNB transfer appended to a private bundle, paid by [payer].
const bscBundleTipRecipient = '0x6374Ca2da5646C73Eb444aB99780495d61035f9b';

class BundleTip {
  const BundleTip(this.payer, this.value);
  final TradeWallet payer;
  final BigInt value;
}

class TradePlan {
  const TradePlan({
    required this.token,
    required this.buy,
    required this.wallets,
    required this.mode,
    required this.amount,
    this.intervalMin = 0,
    this.intervalMax = 0,
    this.loop = false,
    this.randomOrder = false,
    this.market,
    this.maxImpactPercent = 20,
    this.allowUnknownImpact = false,
    this.savedRouter,
    this.exact,
    this.resume,
    this.startingBalances,
    this.tip,
    this.settlement,
  });

  /// Optional builder tip appended to every bundle of this plan (launch liquidations).
  final BundleTip? tip;
  final TokenMeta? settlement;

  /// Confirmed first round or remaining queue after interruption. In interval mode the map's
  /// insertion order is the execution order. Later loop rounds draw amounts and order again.
  final Map<String, BigInt>? resume;

  final Map<String, BigInt>? startingBalances;

  TradePlan withoutResume() => _roundPlan(market, null);

  TradePlan _roundPlan(Market? venue, Map<String, BigInt>? amounts) => TradePlan(
    token: token,
    buy: buy,
    wallets: wallets,
    mode: mode,
    amount: amount,
    intervalMin: intervalMin,
    intervalMax: intervalMax,
    loop: loop,
    randomOrder: randomOrder,
    market: venue,
    maxImpactPercent: maxImpactPercent,
    allowUnknownImpact: allowUnknownImpact,
    savedRouter: savedRouter,
    exact: exact,
    resume: amounts,
    startingBalances: startingBalances,
    tip: tip,
    settlement: settlement,
  );

  /// Last known execution router for display by existing group state.
  final String? savedRouter;

  /// Exact per-wallet amounts (lower-case address -> wei / token units); overrides [amount] (linked groups).
  final Map<String, BigInt>? exact;

  /// Market metadata used for display and the token context lock.
  final Market? market;
  final double maxImpactPercent;
  final bool allowUnknownImpact;
  final String token;
  final bool buy;
  final List<TradeWallet> wallets;
  final SendMode mode;
  final AmountRule amount;

  /// Seconds between trades (interval mode) and between loop rounds; a random value in [min, max].
  final num intervalMin;
  final num intervalMax;
  final bool loop;
  final bool randomOrder;
}

class TradeOutcome {
  /// Legacy adapter metadata retained for embedded callers. Current trades use
  /// the verified market and the issued route.
  String? router;

  /// Every transaction hash this run handed to the relay (deployments, approvals, trades).
  final List<String> sent = [];

  /// Only signed swaps handed to the relay, excluding approvals and tips.
  final List<String> tradeHashes = [];
  final confirmedWallets = <String>{};
  final swapOrders = <String,({String wallet,BigInt quote})>{};
  final swapStatuses = <String,String>{};
  BigInt get confirmedQuote => swapOrders.entries.where((e)=>swapStatuses[e.key]=='confirmed').fold(BigInt.zero,(sum,e)=>sum+e.value.quote);
  final unverifiedSettlement = <String>{};
  final _intermediates = <String,_IntermediateOrder>{};
  final remainingAssets = <String,List<String>>{};
  void trackIntermediates(RoutePlan route, List<SignedTx> txs) {
    if (route.source == 'official' && txs.length > 1) {
      _intermediates[txs.last.hash] = _IntermediateOrder(route.wallet, [for (final t in txs) t.hash], route.legs);
    }
  }
  bool selling = false;
  TokenMeta? settlement;
  BigInt settlementReceived = BigInt.zero;
  final saleLegs = <String, Map<String,String>>{};
  final saleLimits = <String, ({BigInt amount, BigInt minimum})>{};
  BigInt nativeReceived = BigInt.zero, networkFees = BigInt.zero;
  int confirmed = 0;
  int failed = 0;
  int skipped = 0;
  int rounds = 0;
  bool stopped = false;

  /// Wallets of the interrupted round that were not sent yet (lower-case address -> amount).
  Map<String, BigInt> remaining = {};
}

/// A prepared first round (web InstantAction): the amounts are drawn once, shown, then executed as shown.
class PreparedRound {
  const PreparedRound({
    required this.amounts,
    required this.inputTotal,
    required this.skipped,
    this.startingBalances = const {},
    this.quotedOutput,
    this.impact,
    this.v4ImpactUnavailable = false,
    this.unclassifiedPoolImpact = false,
  });

  /// Wallets and exact input amounts in first-round order. Interval preparation checks the impact of every entry.
  final Map<String, BigInt> amounts;
  final BigInt inputTotal;
  final int skipped;
  final Map<String, BigInt> startingBalances;

  /// In interval mode, output covers the first trade and impact is the highest among all wallets.
  final BigInt? quotedOutput;
  final double? impact;
  final bool v4ImpactUnavailable;
  final bool unclassifiedPoolImpact;
  bool get canConfirmUnknown =>
      impact == null && (v4ImpactUnavailable || unclassifiedPoolImpact);
}

/// Adverse impact relative to the UXUY reference quote.
double adverseRouteImpact(RoutePlan route) {
  final value = route.priceImpact;
  if (!value.isFinite || value < 0 || value > 100) {
    throw const BackendException('PRICE_IMPACT_UNKNOWN', '价格冲击数据无效，已暂停', false);
  }
  return value;
}

void _checkImpact(double impact, double ceiling) {
  if (impact > ceiling) {
    throw BackendException(
      'LIQUIDITY_INSUFFICIENT',
      '流动性不足：价格影响 ${impact.toStringAsFixed(2)}%，超过 ${ceiling.toStringAsFixed(2)}% 上限',
      false,
    );
  }
}

typedef Sleep = Future<void> Function(Duration);

/// Batch buy/sell for one group. One run at a time; pause waits before the next send; stop never
/// withdraws transactions that were already submitted. Success is decided by receipts only.
class BatchTrader extends ChangeNotifier {
  BatchTrader(
    this.api,
    this.log, {
    this.label = '',
    Sleep? sleep,
    Random? random,
    this.pollEvery = const Duration(seconds: 2),
    this.recordSaleProceeds = true,
    this.strictSaleReceipts = false,
  }) : _customSleep = sleep,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random.secure();

  final BackendClient api;
  final ExecutionLog log;
  final String label;
  final Sleep _sleep;
  final Sleep? _customSleep;
  final Random _random;
  final Duration pollEvery;
  final bool recordSaleProceeds;
  final bool strictSaleReceipts;
  void Function(String token, TradeWallet wallet)? onTradeSubmitted;
  void Function(Market market)? onFourExternalVerified;

  bool running = false;
  bool paused = false;
  Stopwatch? _lastSubmission;
  Completer<void>? _intervalWake;

  void markSubmission() => _lastSubmission = Stopwatch()..start();

  Duration _remainingDelay(Duration interval) {
    final elapsed = _lastSubmission?.elapsed ?? Duration.zero;
    return elapsed < interval ? interval - elapsed : Duration.zero;
  }

  Future<void> waitSubmissionInterval(Duration interval) =>
      _waitDelay(_remainingDelay(interval));

  Future<void> _waitDelay(Duration delay) async {
    if (delay <= Duration.zero || _cancel || _disposed) return;
    final wake = _intervalWake = Completer<void>();
    Timer? timer;
    try {
      final sleep = _customSleep;
      if (sleep == null) {
        timer = Timer(delay, () {
          if (!wake.isCompleted) wake.complete();
        });
        await wake.future;
      } else {
        await Future.any([sleep(delay), wake.future]);
      }
    } finally {
      timer?.cancel();
      if (identical(_intervalWake, wake)) _intervalWake = null;
    }
  }

  void _wakeInterval() {
    final wake = _intervalWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  bool _cancel = false;
  bool _disposed = false;
  int _controlRevision = 0;
  String? routerAddress;
  String? _approvalSpender;
  ModuleConfig? _routingConfig;
  // Exists only while an ordinary interval group that started on Four's curve is running.
  Market? _intervalFour;

  void _configureRoute(ModuleConfig config, Market? market, String token) {
    _routingConfig = config;
    if (market?.innerPlatform == null) {
      config.requireUxuySwap();
      routerAddress = config.router;
      _approvalSpender = config.approvalSpender;
    } else {
      final target = market!.innerTarget;
      if (market.address.toLowerCase() != token.toLowerCase() || target == null || !isAddress(target) || BigInt.parse(target) == BigInt.zero) {
        throw StateError('无法核实当前内盘交易合约，请重新检查');
      }
      routerAddress = target;
      _approvalSpender = target;
    }
  }

  TradeOutcome? last;

  /// Submitted transactions whose final status is still unknown. Nothing new is sent until they are queried.
  final Set<String> unresolved = {};
  final _waitingBundles = <_BundleCheck>[];
  final _rapidCompound = <String,_BundleCheck>{};
  final _waitingSales = <String,({TradeOutcome outcome,List<String> swaps,String token,List<String> hashes})>{};
  final _intervalOrders = <String,({String wallet,String token,bool buy})>{};
  final _waitingRemainders = <String,TradeOutcome>{};
  Iterable<String> get pendingRemainderHashes => _waitingRemainders.keys;
  final _remainderMeta = <String,TokenMeta>{};
  bool get hasPendingSaleTotals => _waitingSales.isNotEmpty || _waitingRemainders.isNotEmpty;
  final Set<String> _approvalHashes = {};
  bool _approving = false;
  String? _rapidFingerprint;
  final Set<int> _rapidSubmitted = {};

  /// Gas kept back on buys: covers one router trade at the current gas price with margin.
  final _buyGas = <String, int>{};
  static int initialGas(Market? market, {bool buy = true}) {
    if (market == null || market.platform == 'external' || market.external)
      return 350000;
    if (market.platform == 'genius') return 3000000;
    if (buy) return 8000000;
    return market.platform == 'flap' ? 5000000 : 2000000;
  }

  /// A range budgets at its midpoint. Integer truncation can create a final
  /// smaller trade, which also needs gas before freezing the percentage base.
  static BigInt buyBasis(
    BigInt balance,
    BigInt oneGas,
    BigInt midpoint,
    bool loop,
  ) {
    if (!loop || midpoint <= BigInt.zero)
      return balance > oneGas ? balance - oneGas : BigInt.zero;
    final scale = BigInt.from(10000);
    var count = (scale + midpoint - BigInt.one) ~/ midpoint;
    for (var pass = 0; pass < 8; pass++) {
      final available = balance - oneGas * count;
      if (available <= BigInt.zero) return BigInt.zero;
      final tranche = available * midpoint ~/ scale;
      if (tranche == BigInt.zero) return available;
      final needed = (available + tranche - BigInt.one) ~/ tranche;
      if (needed <= count) return available;
      count = needed;
    }
    final available = balance - oneGas * count;
    return available > BigInt.zero ? available : BigInt.zero;
  }

  String _gasKey(TradePlan plan, String owner) =>
      '${plan.token.toLowerCase()}|${plan.market?.innerPlatform}|${owner.toLowerCase()}';

  Future<void> _measureBuyBudgets(
    TradePlan plan,
    List<WalletState> states,
    GasInfo gas, {bool measureAll=false}
  ) async {
    if (!plan.buy) return;
    final rule = plan.amount, requests = <RouteRequestData>[];
    for (final row in states) {
      final key = _gasKey(plan, row.wallet), owner = row.wallet.toLowerCase();
      final fixed = (plan.resume ?? plan.exact)?[owner];
      final estimate = initialGas(plan.market);
      if (!measureAll && (fixed != null &&
              row.native >= fixed + gas.gasPrice * BigInt.from(estimate) ||
          fixed == null &&
              !rule.ratio &&
              row.native >= rule.max + gas.gasPrice * BigInt.from(estimate))) {
        _buyGas[key] = estimate;
        continue;
      }
      final budget = row.native - gas.gasPrice * BigInt.from(21000);
      if (budget <= BigInt.zero) continue;
      final midpoint = (rule.min + rule.max) ~/ BigInt.two;
      final requested =
          fixed ??
          (rule.ratio ? budget * midpoint ~/ BigInt.from(10000) : rule.max);
      final probe = requested < budget ? requested : budget;
      if (probe <= BigInt.zero) continue;
      requests.add(
        RouteRequestData(
          token: plan.token,
          market: plan.market,
          wallet: row.wallet,
          buy: true,
          amount: probe,
          maxImpactPercent: 100,
        ),
      );
    }
    if (requests.isEmpty) return;
    final output = await api.routes(requests);
    if (output.length != requests.length) throw StateError('买入网络费模拟不完整');
    for (var i = 0; i < requests.length; i++) {
      final r = requests[i], result = output[i];
      if (result.error != null) throw result.error!;
      final quote = result.plan!;
      _matchRoute(r, quote);
      _buyGas[_gasKey(plan, r.wallet)] = quote.gasLimit;
    }
  }

  Future<List<BigInt>> linkedBuyerCash(TradePlan buying,List<WalletState> rows,GasInfo gas) async {
    _configureRoute(await api.config(),buying.market,buying.token);
    await _measureBuyBudgets(buying,rows,gas,measureAll:true);
    return [for(final row in rows) _available(buying,row,gas)];
  }

  BigInt _startingBudget(TradePlan plan, WalletState row, GasInfo gas) {
    if (!plan.buy) return row.tokenBalance ?? BigInt.zero;
    final units = _buyGas[_gasKey(plan, row.wallet)] ?? initialGas(plan.market);
    final midpoint = (plan.amount.min + plan.amount.max) ~/ BigInt.two;
    return buyBasis(
      row.native,
      gas.gasPrice * BigInt.from(units),
      midpoint,
      plan.loop && plan.amount.ratio,
    );
  }

  void _log(String text, {LogLevel level = LogLevel.info}) =>
      log.add(label.isEmpty ? text : '$label $text', level: level);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void pause() {
    _controlRevision++;
    paused = true;
    _changed();
  }

  void resume() {
    paused = false;
    _changed();
  }

  void cancel() {
    if (running) _cancel = true;
    _wakeInterval();
    paused = false;
    _changed();
  }

  @override
  void dispose() {
    _cancel = true;
    _wakeInterval();
    _controlRevision++;
    _disposed = true;
    super.dispose();
  }

  Future<TradeOutcome> run(TradePlan plan) async {
    if (!plan.maxImpactPercent.isFinite ||
        plan.maxImpactPercent < 0 ||
        plan.maxImpactPercent > 100) {
      throw StateError('价格冲击阈值须在 0–100% 之间');
    }
    if (running || _approving) throw StateError('本组正在执行或检查授权');
    if (plan.wallets.isEmpty) throw StateError('请先选择钱包');
    if (unresolved.isNotEmpty) throw StateError('本组有待确认交易，请先查询原交易');
    running = true;
    _cancel = false;
    paused = false;
    _changed();
    _intervalFour = plan.mode == SendMode.interval && plan.market?.innerPlatform == 'four' &&
            plan.exact == null && plan.tip == null && plan.settlement == null && !strictSaleReceipts
        ? plan.market : null;
    final outcome = TradeOutcome()..selling = !plan.buy..settlement = plan.settlement;
    if (_intervalFour != null && plan.resume != null) {
      outcome.remaining = Map.of(plan.resume!);
    }
    final startingBalances = Map<String, BigInt>.of(plan.startingBalances ?? {});
    try {
      while (true) {
        outcome.rounds++;
        if (plan.loop) _log('第 ${outcome.rounds} 轮');
        final sent = await _round(plan, outcome, startingBalances);
        if (plan.resume != null) plan = plan.withoutResume();
        if (unresolved.isNotEmpty) {
          outcome.stopped = true;
          _log('有交易尚未确认，已暂停：请查询原交易，不会重复发送', level: LogLevel.error);
          break;
        }
        if (!sent || !plan.loop || _cancel || outcome.stopped) break;
        await waitSubmissionInterval(
          randomGroupInterval(_random, plan.intervalMin, plan.intervalMax),
        );
        await _waitWhilePaused();
        if (_cancel) break;
      }
      if (_cancel && !outcome.stopped) {
        outcome.stopped = true;
        _log('已停止：未提交的交易不再发送，已提交的交易继续确认', level: LogLevel.error);
      }
    } on BackendException catch (e) {
      _log(e.message, level: LogLevel.error);
      outcome.stopped = true;
    } on Exception {
      _log('执行数据读取失败，已暂停，请重新准备', level: LogLevel.error);
      outcome.stopped = true;
    } on StateError catch (e) {
      _log(e.message, level: LogLevel.error);
      outcome.stopped = true;
    } finally {
      _intervalFour = null;
      running = false;
      paused = false;
      last = outcome;
      _log(
        '结束：成功 ${outcome.confirmed}，失败 ${outcome.failed}，跳过 ${outcome.skipped}',
        level: outcome.failed == 0 && !outcome.stopped
            ? LogLevel.success
            : LogLevel.error,
      );
      _changed();
    }
    return outcome;
  }

  List<TradeWallet> _roundWallets(TradePlan plan, {bool preparing = false}) {
    final resume = plan.resume;
    if (resume != null && plan.mode == SendMode.interval) {
      // Preparation and interrupted rounds both retain the actual queue order.
      final byAddress = {
        for (final w in plan.wallets) w.address.toLowerCase(): w,
      };
      return [
        for (final key in resume.keys)
          if (byAddress[key] case final w?) w,
      ];
    }
    final wallets = [
      for (final w in plan.wallets)
        if (resume == null || resume.containsKey(w.address.toLowerCase())) w,
    ];
    if (plan.randomOrder && (!preparing || plan.mode == SendMode.interval)) {
      wallets.shuffle(_random);
    }
    return wallets;
  }

  /// One pass over the wallets. Returns false when nothing could be traded (ends a loop).
  Future<bool> _round(TradePlan plan, TradeOutcome outcome, Map<String, BigInt> startingBalances) async {
    _signedNonces.clear();
    if (_intervalFour?.external == true) {
      plan = plan._roundPlan(_intervalFour, plan.resume);
    }
    final wallets = _roundWallets(plan);
    final config = await api.config();
    _configureRoute(config, plan.market, plan.token);
    _log('核对钱包快照：${wallets.length} 个钱包');
    final (balances, gas) = await _snapshot(
      wallets,
      plan.token,
      spender: plan.buy ? null : _approvalSpender,
      balanceOnly: plan.buy,
    );
    try {
      await _measureBuyBudgets(plan,balances,gas);
    } on BackendException catch (e) {
      if (!_fourMarketChanged(e)) rethrow;
      plan = plan._roundPlan(await _verifyFourExternal(plan), plan.resume);
      await _measureBuyBudgets(plan, balances, gas);
    }
    final states = {for (final s in balances) s.wallet.toLowerCase(): s};
    final requests = <(TradeWallet, RouteRequestData, WalletState)>[];
    for (final w in wallets) {
      final st = states[w.address.toLowerCase()]!;
      final basis = startingBalances.putIfAbsent(st.wallet.toLowerCase(), () => _startingBudget(plan, st, gas));
      final amount = _orderAmount(plan, st, gas, basis);
      if (plan.mode == SendMode.interval &&
          plan.resume != null &&
          w == wallets.first &&
          amount != plan.resume![w.address.toLowerCase()]) {
        outcome.remaining = Map.of(plan.resume!);
        throw StateError('首笔可执行金额已变化，请重新准备并确认');
      }
      if (amount == null || amount == BigInt.zero) {
        outcome.skipped++;
        _log(!plan.buy && plan.market?.innerPlatform=='four' && (st.tokenBalance??BigInt.zero)>BigInt.zero
            ? '${w.address} 当前卖量不足 Four.meme 最小卖出单位，已跳过' : '${w.address} 余额不足，跳过');
        continue;
      }
      requests.add((
        w,
        RouteRequestData(
          buy: plan.buy,
          token: plan.token,
          market: plan.market,
          settlementToken: plan.settlement?.address,
          settlementDecimals: plan.settlement?.decimals,
          amount: amount,
          wallet: w.address,
          maxImpactPercent: plan.maxImpactPercent,
        ),
        st,
      ));
    }
    if (requests.isEmpty) return false;
    if (!plan.buy && requests.any((r) =>
        (r.$3.routerAllowance ?? BigInt.zero) < r.$2.amount)) {
      outcome.remaining = _rest(requests, 0);
      throw StateError('卖出授权额度已变化，请重新检查后继续剩余订单');
    }
    if (plan.mode == SendMode.bundle) {
      await _runBundle(plan, requests, gas, outcome);
    } else {
      await _runInterval(plan, requests, outcome);
    }
    return true;
  }


  Future<(List<WalletState>, GasInfo)> _snapshot(
    List<TradeWallet> wallets,
    String token, {
    String? spender,
    List<WalletState>? known,
    bool balanceOnly = false,
  }) async {
    final result = await Future.wait<Object>([
      if (known == null && balanceOnly)
        api.transferWalletStates([
          for (final w in wallets) w.address,
        ], token: token)
      else if (known == null)
        api.walletStates(
          [for (final w in wallets) w.address],
          token: token,
          spender: spender,
        )
      else
        Future.value(known),
      api.gas(),
    ]);
    return (result.first as List<WalletState>, result.last as GasInfo);
  }

  static String _formatImpact(double? value) =>
      value == null ? '无法评估' : '${value.toStringAsFixed(2)}%';

  bool _ready(int revision, TradeOutcome out) {
    if (!_cancel && !paused && revision == _controlRevision) return true;
    out.stopped = true;
    _log('已暂停或停止，待提交交易已保留', level: LogLevel.error);
    return false;
  }

  bool _recent(Stopwatch elapsed, TradeOutcome out) {
    if (elapsed.elapsed <= const Duration(seconds: 8)) return true;
    out.stopped = true;
    _log('价格冲击报价已过期，请重新准备', level: LogLevel.error);
    return false;
  }

  /// Pin every first-round order and check every wallet or the entire bundle.
  Future<PreparedRound> prepare(
    TradePlan plan, {
    List<WalletState>? walletSnapshot,
  }) async {
    if (running || _approving) throw StateError('本组正在执行或检查授权');
    if (unresolved.isNotEmpty) throw StateError('本组有待确认交易，请先查询原交易');
    final wallets = _roundWallets(plan, preparing: true);
    if (wallets.isEmpty) throw StateError('请先选择钱包');
    final config = await api.config();
    _configureRoute(config, plan.market, plan.token);
    final (states, gas) = await _snapshot(
      wallets,
      plan.token,
      known: walletSnapshot,
      balanceOnly: plan.buy,
      spender: plan.buy ? null : _approvalSpender,
    );
    await _measureBuyBudgets(plan,states,gas);
    final byWallet = {for (final st in states) st.wallet.toLowerCase(): st};
    final startingBalances = Map<String, BigInt>.of(plan.startingBalances ?? {});
    final amounts = <String, BigInt>{};
    var skipped = 0;
    for (final wallet in wallets) {
      final st = byWallet[wallet.address.toLowerCase()];
      if (st == null)
        throw const BackendException(
          'WALLET_STATE_UNKNOWN',
          '钱包快照不完整，请刷新',
          true,
        );
      final basis = startingBalances.putIfAbsent(st.wallet.toLowerCase(), () => _startingBudget(plan, st, gas));
      final a = _orderAmount(plan, st, gas, basis);
      if (a == null || a == BigInt.zero) {
        skipped++;
      } else {
        amounts[st.wallet.toLowerCase()] = a;
      }
    }
    if (amounts.isEmpty) throw StateError('没有可执行的钱包：余额不足');
    final total = amounts.values.fold(BigInt.zero, (a, b) => a + b);
    final bundle = plan.mode == SendMode.bundle;
    final first = amounts.entries.first;
    final previewAmounts = !bundle && plan.exact != null ? {first.key:first.value} : amounts;
    final requests = [
      for (final e in previewAmounts.entries)
        RouteRequestData(
          buy: plan.buy,
          token: plan.token,
          market: plan.market,
          settlementToken: plan.settlement?.address,
          settlementDecimals: plan.settlement?.decimals,
          amount: e.value,
          wallet: checksumAddress(e.key),
          maxImpactPercent: 100,
          forecastOnly: true,
        ),
    ];
    final RoutePlan route;
    double? worst;
    if (bundle) {
      // The backend previews aggregate impact with the sum of the orders.
      // One aggregate input preserves that scope even for a multi-block group.
      final quoteRequests = requests.length <= 103 ? requests : [
        RouteRequestData(token: plan.token,market:plan.market,settlementToken:plan.settlement?.address,settlementDecimals:plan.settlement?.decimals,buy:plan.buy,wallet:requests.first.wallet,amount:total,maxImpactPercent:100,forecastOnly:true),
      ];
      route = (await api.bundleRoute(quoteRequests)).group;
      _matchGroupRoute(requests, route);
    } else if(requests.length == 1) {
      route = await api.route(requests.single);
      _matchRoute(requests.single, route, forecast: true);
    } else {
      final results = await api.routes(requests);
      if(results.length != requests.length) throw StateError('间隔预估钱包数量不一致');
      RoutePlan? firstRoute;
      for(var i=0;i<results.length;i++){
        final row=results[i];
        if(row.error!=null) throw row.error!;
        final quote=row.plan!;
        _matchRoute(requests[i],quote,forecast:true);
        firstRoute ??= quote;
        worst=max(worst??0,adverseRouteImpact(quote));
      }
      route=firstRoute!;
    }
    return PreparedRound(
      amounts: Map.unmodifiable(amounts),
      startingBalances: Map.unmodifiable(startingBalances),
      inputTotal: total,
      skipped: skipped,
      quotedOutput: route.quoteOut,
      impact: worst ?? adverseRouteImpact(route),
    );
  }

  /// Tip transfer signed after the bundle's other transactions of the same payer.
  final Map<String, int> _signedNonces = {};

  SignedTx _tipTx(BundleTip tip, GasInfo gas, WalletState state) {
    if (tip.value <= BigInt.zero) throw StateError('贿赂费必须大于 0');
    final key = tip.payer.address.toLowerCase();
    final nonce = max(_signedNonces[key] ?? state.nonce, state.nonce);
    final tx = api.sign(
      tip.payer,
      LegacyTx(
        nonce: nonce,
        gasPrice: gas.gasPrice,
        gasLimit: 100000,
        to: bscBundleTipRecipient,
        value: tip.value,
        data: Uint8List(0),
      ),
    );
    _signedNonces[key] = nonce + 1;
    _log('贿赂费 ${formatUnits(tip.value, 18)} BNB（${tip.payer.address}）');
    return tx;
  }

  static Map<String, BigInt> _rest(
    List<(TradeWallet, RouteRequestData, WalletState)> reqs,
    int from,
  ) => {
    for (final r in reqs.skip(from)) r.$1.address.toLowerCase(): r.$2.amount,
  };

  /// Read-only recovery (web "查询原交易"): re-reads final statuses of unknown transactions, never resends.
  Future<int> query() async {
    if (running || _approving) throw StateError('本组正在执行或检查授权');
    running = true;
    _changed();
    var settled = 0;
    try {
      await _retryRemainders();
      for (final sale in _waitingSales.values.toList()) {
        await _saleResult(sale.outcome,sale.swaps,sale.token,sale.hashes);
      }
      final deferred = <String>{for(final batch in _waitingBundles) ...batch.hashes};
      for(final batch in List.of(_waitingBundles)){
        final before=unresolved.length;
        await _verifyBundle(batch, last!, manual:true);
        settled += before-unresolved.length;
      }
      for (final h in List.of(unresolved).where((h)=>!deferred.contains(h))) {
        String status;
        try {
          final receipt = await api.reconcileStatus(h);
          if (!receipt.finished) continue;
          status = receipt.status;
        } catch (_) {continue;}
        unresolved.remove(h);
        settled++;
        if (_approvalHashes.remove(h)) {
          _log('原授权 ${_shortTxHash(h)} ${status == 'confirmed' ? '已确认，将回查额度' : _failure(status)}');
          continue;
        }
        final out = last;
        final original = _intervalOrders.remove(h);
        if(original!=null) out?.swapStatuses[h]=status;
        if (status == 'confirmed') {
          out?.confirmed++;
          if(out!=null && original!=null){
            out.confirmedWallets.add(original.wallet);
            if(!original.buy) await _saleResult(out,[h],original.token,[h]);
          }
          _log('原交易 ${_shortTxHash(h)} 已确认', level: LogLevel.success);
        } else {
          out?.failed++;
          if(out!=null && original!=null && !original.buy && status=='reverted') await _saleResult(out,[],original.token,[h]);
          _log(
            '原交易 ${_shortTxHash(h)} ${_failure(status)}',
            level: LogLevel.error,
          );
        }
      }
      if (unresolved.isEmpty) {
        _log('原交易已核清', level: LogLevel.success);
      } else {
        _log('仍有 ${unresolved.length} 笔未确认，请稍后继续查询', level: LogLevel.error);
      }
    } finally {
      running = false;
      _changed();
    }
    return settled;
  }

  BigInt _available(TradePlan plan, WalletState state, GasInfo gas) {
    if (!plan.buy) return state.tokenBalance ?? BigInt.zero;
    final available = state.native - gas.gasPrice * BigInt.from(_buyGas[_gasKey(plan,state.wallet)] ?? initialGas(plan.market));
    return available > BigInt.zero ? available : BigInt.zero;
  }

  BigInt? _orderAmount(TradePlan plan, WalletState state, GasInfo gas, BigInt startingBalance) {
    final available = _available(plan, state, gas);
    final frozen = plan.resume ?? plan.exact;
    if (frozen != null) {
      final amount = frozen[state.wallet.toLowerCase()];
      if (strictSaleReceipts && !plan.buy && amount != (plan.market?.sellUnits(available) ?? available)) {
        throw StateError('清仓钱包余额已变化，请重新准备');
      }
      if (amount == null || amount == BigInt.zero || available == BigInt.zero) return null;
      if (plan.buy && amount > available) return null;
      final capped = amount < available ? amount : available;
      return plan.buy ? capped : plan.market?.sellUnits(capped) ?? capped;
    }
    if (available == BigInt.zero) return null;
    final rule = plan.amount;
    BigInt size(BigInt n) => rule.ratio ? startingBalance * n ~/ BigInt.from(10000) : n;
    final requested = sampleTradeAmount(_random, size(rule.min), size(rule.max));
    final capped = requested < available ? requested : available;
    return plan.buy ? capped : plan.market?.sellUnits(capped) ?? capped;
  }

  void _checkGasBudget(
    WalletState state,
    BigInt value,
    GasInfo gas,
    int units,
  ) {
    if (state.native < value + gas.gasPrice * BigInt.from(units)) {
      throw const BackendException(
        'GAS_BALANCE',
        '当前余额不足以支付本笔金额与网络费，已暂停',
        false,
      );
    }
  }

  List<SignedTx> _sign(
    TradeWallet w,
    String token,
    RoutePlan route,
    WalletState st,
    GasInfo gas,
    BigInt amount,
    bool buy,
  ) {
    if ((!buy && (st.routerAllowance ?? BigInt.zero) < amount) || route.simulation != route.source) {
      throw const BackendException('ALLOWANCE_CHANGED', '授权已变化，请重新检查后卖出', true);
    }
    _checkGasBudget(st, route.value, gas, route.gasLimit);
    final calls = route.source == 'official'
        ? [for (final leg in route.legs) (leg.to, leg.value, leg.data, leg.gasLimit)]
        : [(route.to, route.value, route.data, route.gasLimit)];
    final txs = [
      for (final (i, call) in calls.indexed)
        api.sign(w, LegacyTx(nonce: st.nonce + i, gasPrice: gas.gasPrice,
            gasLimit: call.$4, to: checksumAddress(call.$1), value: call.$2,
            data: hexToBytes(call.$3))),
    ];
    if (route.source == 'official') api.trackInnerRoute(txs);
    return txs;
  }

  Future<void> _waitWhilePaused() async {
    while (paused && !_cancel) {
      await _sleep(const Duration(milliseconds: 300));
    }
  }

  Future<void> _runBundle(
    TradePlan plan,
    List<(TradeWallet, RouteRequestData, WalletState)> all,
    GasInfo gas,
    TradeOutcome outcome,
  ) async {
    outcome.remaining = _rest(all,0);
    final block = (await api.rpc([('eth_getBlockByNumber',['latest',false])])).single;
    final blockLimit = block is Map ? _chainNumber(block['gasLimit']) : null;
    if (blockLimit == null || blockLimit <= BigInt.zero) throw StateError('无法读取区块 Gas 容量');
    final walletLimit = plan.tip == null ? 103 : 102;
    var offset=0;
    while(offset<all.length && !_cancel && !outcome.stopped) {
      outcome.remaining=_rest(all,offset);
      var count=min(walletLimit,all.length-offset);
      _signedNonces.clear();
      final candidates=all.skip(offset).take(count).toList();
      if (offset>0) {
        gas=await api.gas();
        final owners=[for(final e in candidates) e.$1.address];
        final fresh=plan.buy
          ? await api.transferWalletStates(owners,token:plan.token,refresh:true)
          : await api.refreshWalletStates(owners,token:plan.token,spender:_approvalSpender);
        final byWallet={for(final state in fresh) state.wallet.toLowerCase():state};
        for(var i=0;i<candidates.length;i++){
          final (w,req,_)=candidates[i];final state=byWallet[w.address.toLowerCase()]!;
          if(_available(plan,state,gas)<req.amount || (strictSaleReceipts && (plan.market?.sellUnits(state.tokenBalance??BigInt.zero) ?? state.tokenBalance) != req.amount) || (!plan.buy && (state.routerAllowance??BigInt.zero)<req.amount)){
            throw StateError('下一包钱包余额或授权已变化，请检查剩余交易');
          }
          all[offset+i]=(w,req,state);
        }
      }
      final tip=plan.tip;
      final tipState=tip==null?null:(await api.transferWalletStates([tip.payer.address],refresh:true)).single;
      while(count>0 && !_cancel) {
        final part=all.sublist(offset,offset+count);
        final remaining=_rest(all,offset+count);
        final fitted=await _bundleWindow(plan,part,gas,outcome,blockLimit,remaining,tipState);
        if(fitted==count || outcome.stopped || _cancel) break;
        count=fitted;
      }
      offset+=count;
    }
  }

  Future<int> _bundleWindow(
    TradePlan plan,
    List<(TradeWallet, RouteRequestData, WalletState)> reqs,
    GasInfo gas,
    TradeOutcome outcome,
    BigInt blockLimit,
    Map<String,BigInt> remaining,
    WalletState? tipState,
  ) async {
    final revision = _controlRevision;
    final checkedAt = Stopwatch()..start();
    final requests = [for (final r in reqs) r.$2];
    _log('获取整组路径：${requests.length} 个钱包');
    final ({RoutePlan group,List<RoutePlan> wallets}) bundle;
    try {
      bundle = await api.bundleRoute(requests);
    } on BackendException catch(error) {
      // A node can reject an overfull simulated block before returning the ordered routes.
      if(error.code!='UXUY_SIMULATION_UNAVAILABLE' || requests.length<2) rethrow;
      final rows = await api.routes(requests);
      if(rows.length!=requests.length) rethrow;
      final estimates=<RoutePlan>[];
      for(var i=0;i<rows.length;i++) {
        final route=rows[i].plan;
        if(route==null) rethrow;
        _matchRoute(requests[i],route);
        estimates.add(route);
      }
      final count=_fittingWallets(estimates,blockLimit,plan.tip);
      if(count==requests.length) rethrow;
      return count;
    }
    _matchGroupRoute(requests, bundle.group);
    final cumulative = adverseRouteImpact(bundle.group);
    _checkImpact(cumulative, plan.maxImpactPercent);
    final plans = bundle.wallets;
    if (plans.length != requests.length) {
      throw const BackendException('BAD_RESPONSE', '路径数量不符', true);
    }
    for (var i = 0; i < requests.length; i++) {
      final route = plans[i];
      _matchRoute(requests[i], route);
      _checkImpact(adverseRouteImpact(route), plan.maxImpactPercent);
    }
    if (!_ready(revision, outcome)) return reqs.length;
    final count=_fittingWallets(plans,blockLimit,plan.tip);
    if(count<plans.length) return count;
    if(plan.tip case final tip?) {
      var cost=tip.value;
      var gasUnits=100000;
      for(var i=0;i<plans.length;i++){
        if(requests[i].wallet.toLowerCase()==tip.payer.address.toLowerCase()){
          cost+=plans[i].value;gasUnits+=plans[i].gasLimit;
        }
      }
      _checkGasBudget(tipState!,cost,gas,gasUnits);
    }
    final raws = <String>[];
    final hashes = <String>[];
    final finals = <String>[];
    for (var i = 0; i < reqs.length; i++) {
      final (w, req, st) = reqs[i];
      final route = plans[i];
      final txs = _sign(w, plan.token, route, st, gas, req.amount, plan.buy);
      outcome.trackIntermediates(route, txs);
      _signedNonces[w.address.toLowerCase()] = txs.last.nonce + 1;
      raws.addAll(txs.map((t) => t.raw));
      hashes.addAll(txs.map((t) => t.hash));
      finals.add(txs.last.hash);
      if (!plan.buy && route.legs.isNotEmpty) {
        outcome.saleLegs[txs.last.hash] = {for (final (j, tx) in txs.indexed) tx.hash: route.legs[j].to};
      }
    }
    if (plan.tip != null) {
      final tip = _tipTx(plan.tip!, gas,tipState!);
      raws.add(tip.raw);
      hashes.add(tip.hash);
    }
    final head = await api.gas();
    if (!_ready(revision, outcome) || !_recent(checkedAt, outcome)) return reqs.length;
    if (_expired(bundle.group) || plans.any(_expired))
      throw const BackendException('QUOTE_EXPIRED', '路径已过期，请重新准备', false);
    _log('整组价格影响 ${_formatImpact(cumulative)} · 提交捆绑 ${raws.length} 笔');
    final orders={for(var i=0;i<finals.length;i++) finals[i]:(wallet:reqs[i].$1.address,quote:plans[i].quoteOut)};
    final check=_BundleCheck(hashes, {for(var i=0;i<finals.length;i++) finals[i]:reqs[i].$1.address},plan.token,plan.buy);
    try {
      await _broadcast(raws,hashes,finals,head.blockNumber + BackendClient.groupWindowBlocks,outcome,orders:orders,remainingAfterSend:remaining);
    } catch (_) {
      if(finals.any(unresolved.contains)) {
        _waitingBundles.add(check); unresolved.addAll(hashes);
      }
      rethrow;
    } finally {
      for (var i = 0; i < finals.length; i++) {
        if (outcome.swapOrders.containsKey(finals[i])) {
          if (strictSaleReceipts || plan.settlement != null) {
            outcome.saleLimits[finals[i]] = (amount: reqs[i].$2.amount, minimum: plans[i].minOut);
          }
          onTradeSubmitted?.call(plan.token, reqs[i].$1);
        }
      }
    }
    _waitingBundles.add(check);
    await _verifyBundle(check,outcome);
    return reqs.length;
  }

  int _fittingWallets(List<RoutePlan> plans,BigInt blockLimit,BundleTip? tip) {
    var units=BigInt.from(tip==null?0:100000);
    var transactions = tip == null ? 0 : 1;
    for(var i=0;i<plans.length;i++){
      units+=BigInt.from(plans[i].gasLimit);
      transactions += max(1, plans[i].legs.length);
      if(units>blockLimit || transactions > 103){
        if(i==0) throw StateError('单钱包交易超过当前区块 Gas 容量');
        return i;
      }
    }
    return plans.length;
  }

  static bool _expired(RoutePlan p) =>
      p.deadline <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _matchGroupRoute(List<RouteRequestData> requests, RoutePlan group) {
    if (group.quoteScope != 'bundle' ||
        group.data != '0x' ||
        group.gasLimit != 0) {
      throw const BackendException('BAD_ROUTE', '整组报价格式有误，请重新准备', false);
    }
    final first = requests.first;
    final total = requests.fold(BigInt.zero, (sum, r) => sum + r.amount);
    _matchRoute(
      RouteRequestData(
        buy: first.buy,
        token: first.token,
        market: first.market,
        settlementToken: first.settlementToken,
        settlementDecimals: first.settlementDecimals,
        amount: total,
        wallet: first.wallet,
      ),
      group,
      forecast: true,
      group: true,
    );
  }

  void _matchRoute(
    RouteRequestData r,
    RoutePlan p, {
    bool forecast = false,
    bool group = false,
  }) {
    final official = r.market?.innerPlatform != null;
    final calldata = p.data;
    if (official) {
      validateInnerRoute(r, p, _routingConfig!, forecast: forecast);
    } else if (p.source != 'uxuy' || p.legs.isNotEmpty || p.steps.isNotEmpty || p.approvals.isNotEmpty) {
      throw const BackendException('BAD_ROUTE', '返回的交易来源与市场不符，请重新准备', false);
    }
    final validExecution =
        p.executed &&
        (p.simulation == p.source ||
            ((official || !r.buy) && p.simulation == 'approve_then_swap')) &&
        p.gasLimit >= 21000 &&
        p.gasLimit <= 30000000 &&
        (official || RegExp(r'^0x5103aafa(?:[0-9a-fA-F]{2})+$').hasMatch(calldata));
    final validForecast =
        !p.executed &&
        p.simulation == 'forecast' &&
        calldata == '0x' &&
        p.gasLimit == 0;
    final floor =
        p.quoteOut *
        BigInt.from(1000000 - p.slippagePpm) ~/
        BigInt.from(1000000);
    if (p.chainId != bscChainId ||
        p.quoteScope != (group ? 'bundle' : 'wallet') ||
        p.amount != r.amount ||
        p.token?.toLowerCase() != r.token.toLowerCase() ||
        p.buy != r.buy ||
        p.settlementToken?.toLowerCase() != r.settlementToken?.toLowerCase() ||
        p.settlementDecimals != r.settlementDecimals ||
        p.wallet.toLowerCase() != r.wallet.toLowerCase() ||
        p.to.toLowerCase() != routerAddress?.toLowerCase() ||
        p.spender.toLowerCase() != _approvalSpender?.toLowerCase() ||
        p.value != (r.buy ? r.amount : BigInt.zero) ||
        p.slippagePpm < 0 ||
        p.slippagePpm > r.slippageBps * 100 ||
        p.quoteOut <= BigInt.zero ||
        p.minOut <= BigInt.zero ||
        p.minOut > p.quoteOut ||
        p.minOut < floor ||
        !(forecast ? validForecast : validExecution) ||
        _expired(p)) {
      throw const BackendException('BAD_ROUTE', '路径已过期或与订单不符，请重新准备', false);
    }
  }

  Future<void> _broadcast(
    List<String> raws,
    List<String> hashes,
    List<String> finals,
    int maxBlock,
    TradeOutcome out, {
    required Map<String,({String wallet,BigInt quote})> orders,
    Map<String, BigInt> remainingAfterSend = const {},
  }) async {
    // Only explicit rejection before relay submission proves it is safe to retry.
    try {
      markSubmission();
      await api.groupBundle(raws, maxBlock, active: () => !_cancel && !_disposed && !paused);
    } catch (e) {
      if (e is BackendException && e.notSubmitted) rethrow;
      out.swapOrders.addAll(orders);
      out.sent.addAll(hashes);
      out.tradeHashes.addAll(finals);
      unresolved.addAll(finals);
      out.remaining = Map.of(remainingAfterSend);
      throw const BackendException(
        'SUBMISSION_UNKNOWN',
        '提交结果未知，请先查询原交易',
        true,
      );
    }
    out.swapOrders.addAll(orders);
    out.sent.addAll(hashes);
    out.tradeHashes.addAll(finals);
    out.remaining = Map.of(remainingAfterSend);
  }

  bool _fourMarketChanged(BackendException error) =>
      _intervalFour?.innerPlatform == 'four' && error.code == 'INNER_MARKET_CHANGED';

  Future<Market> _verifyFourExternal(TradePlan plan) async {
    final previous = _intervalFour!;
    // The backend checks Four's registry, the official pair, its assets and reserves at this block.
    final fresh = Market(await api.platform(plan.token));
    final identity = previous.raw['identity'];
    if (identity is! String || identity.isEmpty || fresh.raw['identity'] != identity ||
        fresh.platform != 'four' || fresh.address.toLowerCase() != plan.token.toLowerCase() ||
        fresh.quote.toLowerCase() != previous.quote.toLowerCase() ||
        fresh.raw['decimals'] != previous.raw['decimals'] ||
        fresh.buyTaxBps != previous.buyTaxBps || fresh.sellTaxBps != previous.sellTaxBps) {
      throw StateError('Four 代币配置已变化，请重新检查');
    }
    final pool = fresh.raw['pool'];
    final block = fresh.raw['block'];
    if (!fresh.external || block is! int || block < previous.block ||
        (!previous.external && block == previous.block) ||
        pool is! String || !isAddress(pool) || pool.toLowerCase() == zeroAddress ||
        (previous.external && pool.toLowerCase() != previous.pool?.toLowerCase())) {
      throw StateError('Four 外盘迁移或底池尚未核实，请重新检查');
    }
    if (!previous.external || block > previous.block) {
      onFourExternalVerified?.call(fresh);
    }
    if (!plan.buy) throw StateError('Four 已迁移，请重新检查外盘授权和剩余卖单');
    if (!previous.external) {
      _configureRoute(await api.config(), fresh, plan.token);
      _log('Four 已迁移，剩余钱包逐笔重新获取 UXUY 外盘买入报价');
    }
    _intervalFour = fresh;
    return fresh;
  }

  Future<(WalletState, GasInfo, RouteRequestData, RoutePlan?)> _intervalQuote(
    TradePlan plan, RouteRequestData order, {required bool first, bool justVerified = false}
  ) async {
    if (_intervalFour?.external == true) {
      final venue = justVerified ? _intervalFour! : await _verifyFourExternal(plan);
      plan = plan._roundPlan(venue, plan.resume);
    }
    final owner = order.wallet;
    final snapshot = await Future.wait<Object>([
      plan.buy
          ? api.transferWalletStates([owner], token: plan.token, refresh: true)
          : api.refreshWalletStates([owner], token: plan.token, spender: _approvalSpender),
      api.gas(),
      api.rpc([('eth_getTransactionCount', [owner, 'latest'])]),
    ]);
    final row = (snapshot[0] as List<WalletState>).single;
    final gas = snapshot[1] as GasInfo;
    final mined = (snapshot[2] as List).single;
    // The wallet endpoint returns the pending nonce. A mined order may legitimately
    // advance it while the previous wallet trades; an outstanding order must settle first.
    if (_chainNumber(mined) != BigInt.from(row.nonce)) {
      throw StateError('$owner 交易序号尚未核实或有待确认交易，请检查后继续');
    }
    final budget = _available(plan, row, gas);
    if (strictSaleReceipts && !plan.buy && (plan.market?.sellUnits(budget) ?? budget) != order.amount) {
      throw StateError('清仓钱包余额已变化，请重新准备');
    }
    var amount = order.amount < budget ? order.amount : budget;
    if (!plan.buy) amount = plan.market?.sellUnits(amount) ?? amount;
    if ((first || strictSaleReceipts) && amount != order.amount) {
      throw StateError('本笔可执行金额已变化，请重新准备并确认');
    }
    if (amount == BigInt.zero) {
      if (plan.loop) return (row, gas, order, null);
      throw StateError('$owner 已无可执行余额，请检查剩余订单');
    }
    if (!plan.buy && (row.routerAllowance ?? BigInt.zero) < amount) {
      throw StateError('卖出授权额度已变化，请重新检查后继续剩余订单');
    }
    final req = amount == order.amount && identical(plan.market, order.market) ? order : RouteRequestData(
      wallet: owner, token: order.token, market: plan.market, buy: order.buy,
      amount: amount, maxImpactPercent: order.maxImpactPercent, slippageBps: order.slippageBps,
      settlementToken: order.settlementToken, settlementDecimals: order.settlementDecimals,
    );
    try {
      return (row, gas, req, await api.route(req));
    } on BackendException catch (e) {
      if (!_fourMarketChanged(e)) rethrow;
      await _verifyFourExternal(plan);
      // Only an unsigned inner quote was rejected. Recheck nonce and spending power for the same order.
      return _intervalQuote(plan, req, first: first, justVerified: true);
    }
  }

  Future<void> _runInterval(
    TradePlan plan,
    List<(TradeWallet, RouteRequestData, WalletState)> reqs,
    TradeOutcome outcome,
  ) async {
    for (var i = 0; i < reqs.length; i++) {
      final (w, plannedOrder, _) = reqs[i];
      outcome.remaining = _rest(reqs, i);
      final delay = i == 0
          ? Duration.zero
          : randomGroupInterval(_random, plan.intervalMin, plan.intervalMax);
      const lead = Duration(seconds: 1);
      if (delay > lead) await waitSubmissionInterval(delay - lead);
      await _waitWhilePaused();
      if (_cancel) return;
      final revision = _controlRevision;
      final clock = Stopwatch()..start();
      final checked = _intervalQuote(plan, plannedOrder, first: i == 0);
      if (delay > Duration.zero) {
        final wait = _remainingDelay(delay);
        await Future.wait<void>([checked.then<void>((_) {}), _waitDelay(wait > lead ? lead : wait)]);
      }
      final (st, head, req, route) = await checked;
      if (!_ready(revision, outcome)) return;
      if (route == null) {
        outcome.skipped++;
        outcome.remaining = _rest(reqs, i + 1);
        continue;
      }
      _matchRoute(req, route);
      final impact = adverseRouteImpact(route);
      _checkImpact(impact, plan.maxImpactPercent);
      final txs = _sign(w, plan.token, route, st, head, req.amount, plan.buy);
      if (!_ready(revision, outcome) || !_recent(clock, outcome)) return;
      if (_expired(route))
        throw const BackendException('QUOTE_EXPIRED', '路径已过期，请重新准备', false);
      _log('${w.address} 价格影响 ${_formatImpact(impact)}，提交私有捆绑');
      outcome.trackIntermediates(route, txs);
      final hash = txs.last.hash;
      final order = (wallet:w.address,token:plan.token,buy:plan.buy);
      final legHashes = [for (final t in txs) t.hash];
      final batch = txs.length > 1 ? _BundleCheck(legHashes, {hash:w.address},plan.token,plan.buy) : null;
      if (!plan.buy && route.legs.isNotEmpty) {
        outcome.saleLegs[hash] = {for (final (j, tx) in txs.indexed) tx.hash: route.legs[j].to};
      }
      try {
        await _broadcast(
          [for (final t in txs) t.raw],
          [for (final t in txs) t.hash],
          [hash],
          head.blockNumber + BackendClient.groupWindowBlocks,
          outcome,
          orders:{hash:(wallet:w.address,quote:route.quoteOut)},
          remainingAfterSend: _rest(reqs, i + 1),
        );
      } catch(_) {
        if (unresolved.contains(hash)) {
          if (batch == null) {
            _intervalOrders[hash]=order;
          } else {
            _waitingBundles.add(batch);
            unresolved.addAll(legHashes);
          }
        }
        rethrow;
      } finally {
        if (outcome.swapOrders.containsKey(hash)) {
          if (strictSaleReceipts || plan.settlement != null) {
            outcome.saleLimits[hash] = (amount: req.amount, minimum: route.minOut);
          }
          onTradeSubmitted?.call(plan.token, w);
        }
      }
      if (batch != null) {
        _waitingBundles.add(batch);
        await _verifyBundle(batch, outcome);
        if (outcome.stopped) return;
        continue;
      }
      final status = await _awaitReceipt(hash);
      outcome.swapStatuses[hash]=status;
      if(status=='unknown') _intervalOrders[hash]=order;
      if (status == 'confirmed') {
        outcome.confirmed++;
        outcome.confirmedWallets.add(w.address);
        if (!plan.buy) await _saleResult(outcome,[txs.last.hash],plan.token,[txs.last.hash]);
        _log('${w.address} 已确认', level: LogLevel.success);
      } else {
        if (status != 'unknown') outcome.failed++;
        if (!plan.buy && status=='reverted') await _saleResult(outcome,[],plan.token,[hash]);
        _log(
          '${w.address} ${_failure(status)} ${_shortTxHash(txs.last.hash)}',
          level: LogLevel.error,
        );
        outcome.stopped = true;
        return;
      }
    }
  }

  static String _failure(String status) => switch (status) {
    'reverted' => '链上执行失败',
    'not_included' => '捆绑未上链，可重新执行',
    'rejected' || 'not_submitted' => '未发送',
    _ => '未确认，请稍后查询原交易',
  };

  Future<String> _awaitReceipt(String hash, {int attempts = 60}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final r = await api.status(hash);
        if (r.finished) return r.status;
      } on BackendException {
        // keep polling; never resend
      }
      await _sleep(pollEvery);
    }
    unresolved.add(hash);
    return 'unknown';
  }
}

String _shortTxHash(String s) =>
    s.length > 12 ? '${s.substring(0, 6)}…${s.substring(s.length - 4)}' : s;
