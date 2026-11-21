import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../exec/executor.dart';
import '../exec/genius_launch.dart';
import '../exec/launch.dart';
import '../exec/linked.dart';
import '../exec/market.dart';
import '../exec/preview_deadline.dart';
import '../exec/transfers.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_backup.dart';

export '../wallet/wallet_backup.dart' show GeneratedWalletBatch;

part 'group_quote.dart';

/// Clipboard and editor interchange format: one canonical private key per line.
String formatPrivateKeyLines(Iterable<TradeWallet> wallets) =>
    wallets.map((wallet) => wallet.exportPrivateKey()).join('\n');

enum WorkspacePage { four, flap, genius, batch, tools, holding }

/// Raised before any signing operation acquires the workspace or its wallets.
class WorkspaceConflict implements Exception {
  WorkspaceConflict(this.reason, [this.wallets = const {}]);
  final String reason;
  final Map<String, Set<String>> wallets;
  @override
  String toString() => reason;
}

enum GroupStatus {
  needKeys,
  ready,
  running,
  paused,
  pending,
  partial,
  done,
  stopped,
}

/// Common surface of normal and linked groups.
abstract class GroupBase extends ChangeNotifier {
  GroupBase(this.number);
  final int number;
  String get name;
  bool get linked;
  bool get running;
  GroupStatus get status;

  /// Every key this group holds (linked groups include their relay wallets).
  List<TradeWallet> get allWallets;
  void cancel();
}

/// One address group of the batch page: its own private keys, selection and trade settings.
class TradeGroup extends GroupBase {
  TradeGroup(super.number, BackendClient api, ExecutionLog log)
    : trader = BatchTrader(api, log, label: '组${_two(number)}') {
    trader.addListener(notifyListeners);
  }

  final BatchTrader trader;
  @override
  String get name => '组${_two(number)}';
  @override
  bool get linked => false;
  @override
  bool get running => trader.running;
  @override
  List<TradeWallet> get allWallets => wallets;
  @override
  void cancel() => trader.cancel();

  /// Unsent wallets of an interrupted round (web "准备剩余" / "执行剩余").
  Map<String, BigInt>? remaining;
  Map<String, BigInt>? remainingBasis;

  List<TradeWallet> wallets = [];
  final Set<String> selected = {};
  Map<String, WalletState> states = {};

  bool buy = true;
  SendMode mode = SendMode.interval;
  bool ratio = false;
  String min = '0.01';
  String max = '0.01';
  bool randomOrder = false;
  String intervalMin = '1';
  String intervalMax = '3';
  bool loop = false;

  /// Retains adapter labels for embedded callers that used the previous router API.
  final Map<String, String> savedRouters = {};

  void update(void Function(TradeGroup g) change) {
    change(this);
    notifyListeners();
  }

  final _amountRanges = <(bool, bool), (String, String)>{};
  final _amountMode = <bool, bool>{true: false, false: true};

  void _restoreAmount() {
    final saved = _amountRanges[(buy, ratio)];
    final initial = ratio ? '100' : (buy ? '0.01' : '');
    min = saved?.$1 ?? initial;
    max = saved?.$2 ?? initial;
    notifyListeners();
  }

  void setBuy(bool value) {
    if (buy == value) return;
    _amountRanges[(buy, ratio)] = (min, max);
    _amountMode[buy] = ratio;
    buy = value;
    ratio = _amountMode[buy]!;
    _restoreAmount();
  }

  void setRatio(bool value) {
    if (ratio == value) return;
    _amountRanges[(buy, ratio)] = (min, max);
    ratio = value;
    _amountMode[buy] = value;
    _restoreAmount();
  }

  @override
  GroupStatus get status {
    if (wallets.isEmpty) return GroupStatus.needKeys;
    if (trader.running) {
      return trader.paused ? GroupStatus.paused : GroupStatus.running;
    }
    if (trader.unresolved.isNotEmpty) return GroupStatus.pending;
    if (remaining != null) return GroupStatus.partial;
    final last = trader.last;
    if (last == null) return GroupStatus.ready;
    return last.stopped ? GroupStatus.stopped : GroupStatus.done;
  }

  List<TradeWallet> get selectedWallets => [
    for (final w in wallets)
      if (selected.contains(w.address)) w,
  ];

  WalletState? stateOf(TradeWallet w) => states[w.address.toLowerCase()];

  BigInt get nativeTotal =>
      states.values.fold(BigInt.zero, (a, s) => a + s.native);

  BigInt? get tokenTotal {
    final values = states.values.map((s) => s.tokenBalance).whereType<BigInt>();
    return values.isEmpty
        ? null
        : values.fold<BigInt>(BigInt.zero, (a, b) => a + b);
  }

  void toggle(TradeWallet w) {
    selected.contains(w.address)
        ? selected.remove(w.address)
        : selected.add(w.address);
    notifyListeners();
  }

  void selectAll() {
    if (selected.length == wallets.length) {
      selected.clear();
    } else {
      selected
        ..clear()
        ..addAll(wallets.map((w) => w.address));
    }
    notifyListeners();
  }

  /// Build the plan from the form; validates without floating point.
  TradePlan plan(
    String token,
    int? decimals, {
    Market? market,
    double maxImpactPercent = 20,
    Map<String, BigInt>? resume,
  }) {
    if (selected.isEmpty) throw StateError('请先选择钱包');
    final AmountRule rule;
    if (ratio) {
      final lo = _bps(min);
      final hi = _bps(max);
      if (hi == BigInt.zero || hi < lo) {
        throw const FormatException('比例需在 0–100 之间，最小不大于最大');
      }
      rule = AmountRule(ratio: true, min: lo, max: hi);
    } else {
      final d = buy
          ? 18
          : (decimals ?? (throw const FormatException('代币精度未知，请按比例卖出')));
      final lo = parseUnits(min, d);
      final hi = parseUnits(max.trim().isEmpty ? min : max, d);
      if (hi == BigInt.zero || hi < lo) {
        throw const FormatException('金额上限需大于 0，最小不大于最大');
      }
      rule = AmountRule(ratio: false, min: lo, max: hi);
    }
    final iMin = parseGroupSeconds(intervalMin) ?? -1;
    final iMax = parseGroupSeconds(intervalMax) ?? -1;
    if (mode == SendMode.interval && (iMin < 0 || iMax < iMin)) {
      throw const FormatException('间隔秒数无效');
    }
    return TradePlan(
      token: token,
      buy: buy,
      wallets: selectedWallets,
      mode: mode,
      amount: rule,
      intervalMin: iMin < 0 ? 0 : iMin,
      intervalMax: iMax < 0 ? 0 : iMax,
      loop: loop,
      randomOrder: randomOrder,
      market: market,
      maxImpactPercent: maxImpactPercent,
      savedRouter: market == null ? null : savedRouters[market.platform],
      resume: resume,
      startingBalances: resume == null ? null : remainingBasis,
    );
  }

  static BigInt _bps(String percent) {
    final v = parseUnits(percent, 2);
    if (v > BigInt.from(10000)) throw const FormatException('比例不能超过 100%');
    return v;
  }

  @override
  void dispose() {
    trader.cancel();
    trader.dispose();
    super.dispose();
  }
}

class RapidGroup extends TradeGroup {
  RapidGroup(super.number, super.api, super.log);
  @override
  String get name => '快速交易组${_two(number)}';
  RapidDirection direction = RapidDirection.buy;
  bool percentSell = true;
  String buyAmount = '0.001', sellPercent = '100', sellAmount = '';
  String interval = '1', total = '10', minNative = '0', minToken = '0';
  RapidPlan rapidPlan(TokenMeta token, double impact, Market market) => RapidPlan.parse(
    token:token.address, market:market, decimals:token.decimals!, wallets:selectedWallets, direction:direction,
    buyAmount:buyAmount, percentSell:percentSell, sellAmount:sellAmount, sellPercent:sellPercent,
    interval:interval, total:total, minNative:minNative, minToken:minToken, impactLimit:impact,
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Linked group (web 关联组 · 先卖后买): seller keys, buyer keys and one generated relay per buyer.
class LinkedGroup extends GroupBase {
  LinkedGroup(super.number, BackendClient api, ExecutionLog log)
    : trader = LinkedTrader(api, log, label: '关联组${_two(number)}') {
    trader.addListener(notifyListeners);
  }

  final LinkedTrader trader;
  @override
  String get name => '关联组${_two(number)}';
  @override
  bool get linked => true;
  @override
  bool get running => trader.running;
  @override
  void cancel() => trader.cancel();

  List<TradeWallet> sellers = [];
  List<TradeWallet> buyers = [];

  /// Relay per buyer (lower-case buyer address). Kept for removed buyers too, so their keys stay exportable.
  final Map<String, TradeWallet> transitByBuyer = {};
  final _draftRelays = <String, TradeWallet>{};
  Map<String, WalletState> states = {};

  bool ratio = true;
  String min = '5';
  String max = '5';
  bool randomOrder = false;
  String intervalMin = '1';
  String intervalMax = '3';

  List<TradeWallet> get transits => [
    for (final b in buyers) transitByBuyer[b.address.toLowerCase()]!,
  ];
  Map<String, TradeWallet> get activeTransitPairs => {
    for (final buyer in buyers)
      buyer.address.toLowerCase(): transitByBuyer[buyer.address.toLowerCase()]!,
  };
  List<TradeWallet> get allTransits => transitByBuyer.values.toList();
  bool get transitsBackedUp => transits.every((t) => t.canReceiveFunds);

  @override
  List<TradeWallet> get allWallets => [...sellers, ...buyers, ...allTransits];

  /// Keys can change only when no round is open.
  bool get locked => trader.running || trader.progress != null;

  void update(void Function(LinkedGroup g) change) {
    change(this);
    notifyListeners();
  }

  void setRatio(bool value) {
    if (ratio == value) return;
    ratio = value;
    min = value ? '5' : '';
    max = min;
    notifyListeners();
  }

  WalletState? stateOf(TradeWallet w) => states[w.address.toLowerCase()];
  BigInt? nativeTotal(List<TradeWallet> side) {
    final v = [for (final w in side) stateOf(w)?.native].whereType<BigInt>();
    return v.isEmpty ? null : v.fold<BigInt>(BigInt.zero, (a, b) => a + b);
  }

  BigInt? tokenTotal(List<TradeWallet> side) {
    final v = [for (final w in side) stateOf(w)?.tokenBalance]
        .whereType<BigInt>();
    return v.isEmpty ? null : v.fold<BigInt>(BigInt.zero, (a, b) => a + b);
  }

  @override
  GroupStatus get status {
    if (sellers.isEmpty || buyers.isEmpty) return GroupStatus.needKeys;
    if (trader.running) {
      return trader.paused ? GroupStatus.paused : GroupStatus.running;
    }
    if (trader.needsQuery) return GroupStatus.pending;
    if (trader.resumable) return GroupStatus.partial;
    final p = trader.progress;
    if (p != null && p.finished) return GroupStatus.done;
    return GroupStatus.ready;
  }

  LinkedPlan plan(
    String token,
    int? decimals, {
    Market? market,
    double maxImpactPercent = 20,
  }) {
    if (sellers.isEmpty || buyers.isEmpty) throw StateError('请先输入卖方和买方私钥');
    final LinkedSizing sizing;
    if (ratio) {
      final lo = parseUnits(min, 2);
      final hi = parseUnits(max.trim().isEmpty ? min : max, 2);
      if (hi == BigInt.zero || hi < lo || hi > BigInt.from(10000)) {
        throw const FormatException('比例需在 0–100 之间，最小不大于最大');
      }
      sizing = LinkedSizing(ratio: true, min: lo, max: hi);
    } else {
      final d = decimals ?? (throw const FormatException('代币精度未知，请按比例卖出'));
      final lo = parseUnits(min, d);
      final hi = parseUnits(max.trim().isEmpty ? min : max, d);
      if (hi == BigInt.zero || hi < lo) {
        throw const FormatException('数量需大于 0，最小不大于最大');
      }
      sizing = LinkedSizing(ratio: false, min: lo, max: hi);
    }
    final iMin = parseGroupSeconds(intervalMin) ?? -1;
    final iMax = parseGroupSeconds(intervalMax) ?? -1;
    if (iMin < 0 || iMax < iMin) throw const FormatException('间隔秒数无效');
    return LinkedPlan(
      token: token,
      market: market,
      sellers: sellers,
      buyers: buyers,
      transits: transits,
      sizing: sizing,
      intervalMin: iMin,
      intervalMax: iMax,
      randomOrder: randomOrder,
      maxImpactPercent: maxImpactPercent,
      savedRouter: market == null ? null : savedRouters[market.platform],
    );
  }

  final Map<String, String> savedRouters = {};

  @override
  void dispose() {
    trader.cancel();
    trader.dispose();
    super.dispose();
  }
}

/// A receipt-confirmed launch waiting to become the workspace's current token.
class PendingLaunchToken {
  const PendingLaunchToken(this.address, this.symbol, this.platform);
  final String address;
  final String symbol;
  final String platform;
}

/// Percent thresholds shared by all groups and launchpad liquidation.
class ImpactSettings {
  const ImpactSettings({
    this.bundle = 20,
    this.intervalStart = 10,
    this.intervalLive = 20,
  });
  final double bundle, intervalStart, intervalLive;

  factory ImpactSettings.parse(String bundle, String start, String live) {
    double pct(String raw) {
      final v = double.tryParse(raw.trim());
      if (v == null || !v.isFinite || v < 0 || v > 100) {
        throw const FormatException('价格影响上限需在 0–100% 之间');
      }
      return v;
    }

    return ImpactSettings(
      bundle: pct(bundle),
      intervalStart: pct(start),
      intervalLive: pct(live),
    );
  }
  double warning(SendMode mode) =>
      mode == SendMode.bundle ? bundle : intervalStart;
}

/// Approval belongs to one prepared operation and its frozen settings and amounts.
class ImpactReview {
  const ImpactReview(
    this.mode,
    this.value,
    this.settings, {
    this.v4 = false,
    this.canConfirmUnknown = false,
  });
  final SendMode mode;
  final double? value;
  final ImpactSettings settings;
  final bool v4, canConfirmUnknown;
  double get threshold => settings.warning(mode);
  bool get needsConfirmation =>
      value == null || !value!.isFinite || value! > threshold;
  double ceiling(bool confirmed) {
    if (needsConfirmation && !confirmed) throw StateError('请先确认本次价格影响提醒');
    if (mode == SendMode.interval) return settings.intervalLive;
    final impact = value;
    return impact != null && impact.isFinite && impact > threshold
        ? impact
        : threshold;
  }
}

/// Pins one group's token and prepared plan from the first await through confirmation.
class _GroupOperation {
  _GroupOperation(this.token, this.revision, this.settings);
  final ImpactSettings settings;
  ImpactReview? review;
  WarmGroupQuote? warmed;
  bool linkedBuy = false;
  DateTime? marketRead;
  QuoteProgress? quoteProgress;
  final TokenMeta token;
  final int revision;
  String phase = '准备中';
  bool executing = false;
  bool cancelled = false;
  TradePlan? tradePlan;
  LinkedPlan? linkedPlan;
  RapidPrepared? rapid;
  PreparedRound? prepared;
}

/// Module state for one host session. Disposed with the session; nothing survives scope revocation.
class AppState extends ChangeNotifier {
  final DateTime Function() groupQuoteClock;
  AppState(
    this.api,
    this.store, {
    this.imagePicker,
    DateTime Function()? groupQuoteClock,
    this.downloadText,
    ImpactSettings impactSettings = const ImpactSettings(),
    this.persistImpactSettings,
    WalletBackupDirectory? backupDirectory,
  }) : groupQuoteClock=groupQuoteClock??DateTime.now,
       walletBackup = backupDirectory == null
           ? null
           : WalletBackupCoordinator(backupDirectory),
       _impactSettings = impactSettings,
       log = ExecutionLog() {
    walletBackup?.onGeneratedGroupsLoaded = _restoreGeneratedBatches;
    walletBackup?.onGeneratedGroupSaved = (id, name) {
      for (final batch in _generatedBatches) {
        if (batch.id == id) {
          batch.storedName = name;
          break;
        }
      }
    };
    walletBackup?.addListener(_notify);
    transfers = TransferEngine(
      api,
      log,
      requireReceivable: walletBackup == null ? null : requireReceivable,
      checkWorkspace: () => _requireWorkspace(WorkspacePage.tools),
    )..addListener(_notify);
    four = FourLauncher(api, log);
    flap = FlapLauncher(api, log);
    genius = GeniusLauncher(api, log);
    for (final launcher in [four, flap, genius]) {
      launcher.checkWorkspace = () => _requireWorkspace(_ownerPage(launcher)!);
      launcher.addListener(_launchChanged);
    }
  }

  ImpactSettings _impactSettings;
  ImpactSettings get impactSettings => _impactSettings;
  final void Function(ImpactSettings)? persistImpactSettings;
  void setImpactSettings(ImpactSettings value) {
    persistImpactSettings?.call(value);
    if (value.bundle == _impactSettings.bundle &&
        value.intervalStart == _impactSettings.intervalStart &&
        value.intervalLive == _impactSettings.intervalLive)
      return;
    _impactSettings = value;
    for (final entry in _operations.entries.toList()) {
      if (!entry.value.executing)
        cancelPreparation(entry.key, handle: entry.value);
    }
    for (final launcher in [four, flap, genius]) {
      launcher.invalidateLiquidationPreview();
    }
    _notify();
  }

  ImpactReview? preparedImpact(GroupBase group) => _operations[group]?.review;

  /// Host-provided image chooser for token images (null: launch pages explain it is unavailable).
  final Future<LaunchImage?> Function()? imagePicker;
  final void Function(String filename, String content)? downloadText;
  late final FourLauncher four;
  late final FlapLauncher flap;
  late final GeniusLauncher genius;

  final BackendClient api;
  final KeyStore store;
  final WalletBackupCoordinator? walletBackup;
  final ExecutionLog log;
  late final TransferEngine transfers;

  /// Distribution relays, one per recipient (web pairDistributionWallets): reused for the same recipient,
  /// kept for export after the run ("中转备份（含历史）").
  final Map<String, TradeWallet> distributionTransits = {};
  final _draftDistribution = <String, TradeWallet>{};
  final _editingLinkedKeys = <LinkedGroup>{};

  TokenMeta? token;

  /// Platform / internal-external / settlement of the current token (web: sidebar "平台 · 内外盘 · 结算").
  Market? market;
  ModuleConfig? config;
  final List<GroupBase> groups = [];
  int current = 0;
  int _next = 1;

  int _generationTarget = 0;
  int _generatedWalletCount = 0;
  bool _stopGenerationRequested = false;

  bool get generatingWallets => _generationTarget > 0;
  int get generationTarget => _generationTarget;
  int get generatedWalletCount => _generatedWalletCount;
  bool get stoppingWalletGeneration => _stopGenerationRequested;

  int _nextGeneratedNumber = 1;
  final _generatedBatches = <GeneratedWalletBatch>[];
  List<GeneratedWalletBatch> get generatedBatches => List.unmodifiable(_generatedBatches);
  List<TradeWallet> get generated => _generatedBatches.lastOrNull?.wallets ?? const [];

  void _restoreGeneratedBatches(List<GeneratedWalletBatch> restored) {
    // Keep the live objects for writes awaiting verification. The coordinator
    // will mark precisely these wallets as backed up when a retry succeeds.
    final pending = {
      for (final batch in _generatedBatches)
        if (batch.wallets.any((w) => !w.canReceiveFunds)) batch.id: batch,
    };
    _generatedBatches
      ..clear()
      ..addAll(restored.map((batch) {
        final waiting = pending.remove(batch.id);
        return waiting == null ? batch : GeneratedWalletBatch(
          id: batch.id, number: batch.number, storedName: batch.storedName,
          wallets: waiting.wallets,
        );
      }));
    for (final batch in pending.values) {
      _generatedBatches.add(GeneratedWalletBatch(
        id: batch.id, number: _generatedBatches.length + 1, wallets: batch.wallets,
        storedName: batch.storedName,
      ));
    }
    final lastNumber = _generatedBatches.lastOrNull?.number ?? 0;
    if (_nextGeneratedNumber <= lastNumber) _nextGeneratedNumber = lastNumber + 1;
    _notify();
  }

  bool busy = false;
  bool _disposed = false;
  bool _tokenSwitching = false;
  int _tokenRevision = 0;
  final Map<GroupBase, _GroupOperation> _operations = {};
  final Map<GroupBase, int> _balanceReads = {};
  final Set<String> _seenLaunches = {};
  final List<PendingLaunchToken> _pendingLaunchTokens = [];
  String? tokenNotice;

  bool get tokenSwitching => _tokenSwitching;
  List<PendingLaunchToken> get pendingLaunchTokens =>
      List.unmodifiable(_pendingLaunchTokens);
  bool groupOperationBusy(GroupBase g) => _operations.containsKey(g);
  Object? operationHandle(GroupBase g) => _operations[g];
  bool slowPreview(GroupBase g) => _operations[g]?.quoteProgress?.slow == true;
  bool preparedReady(GroupBase g) => _operations[g]?.phase == '等待确认';
  TokenMeta? preparedToken(GroupBase g) => _operations[g]?.token;

  // Public addresses only. Register synchronously so two simultaneous starts see each other.
  final _walletUses = <Object, ({String label, Set<String> addresses})>{};

  Iterable<String> groupWallets(GroupBase group, {bool resume = false}) {
    if (group is TradeGroup) {
      if (!group.loop) {
        final prepared = _operations[group]?.prepared;
        if (prepared != null) return prepared.amounts.keys;
        final remaining = group.remaining;
        if (resume && remaining != null) {
          return group.selectedWallets
              .map((w) => w.address.toLowerCase())
              .where(remaining.containsKey);
        }
      }
      return group.selectedWallets.map((w) => w.address);
    }
    final linked = group as LinkedGroup;
    return [
      ...linked.sellers,
      ...linked.buyers,
      ...linked.transits,
    ].map((w) => w.address);
  }

  /// Starts with idle imports excluded. Finished runs contribute only their original pending transactions.
  Map<String, Set<String>> walletOverlaps(
    Object owner,
    Iterable<String> addresses,
  ) {
    final wanted = addresses.map((a) => a.toLowerCase()).toSet();
    final overlaps = <String, Set<String>>{};
    if (wanted.isEmpty) return overlaps;

    void add(Object other, String label, Iterable<String> involved) {
      if (identical(owner, other)) return;
      for (final address in involved) {
        final key = address.toLowerCase();
        if (wanted.contains(key)) (overlaps[key] ??= {}).add(label);
      }
    }

    for (final entry in _walletUses.entries) {
      add(entry.key, entry.value.label, entry.value.addresses);
    }
    for (final group in groups) {
      if (_walletUses.containsKey(group) || identical(owner, group)) continue;
      if (groupOperationBusy(group) || group.running) {
        add(group, group.name, groupWallets(group));
      } else {
        final hashes = group is TradeGroup
            ? group.trader.unresolved
            : (group as LinkedGroup).trader.unsettledHashes;
        add(group, group.name, api.pendingWalletsFor(hashes));
      }
    }
    for (final transfer in transfers.unresolvedRuns) {
      if (identical(owner, transfer) || _walletUses.containsKey(transfer)) continue;
      for (final leg in transfer.legs) {
        if (leg.status == TransferStatus.submitted ||
            leg.status == TransferStatus.unknown) {
          add(transfer, transfer.label, [leg.from.address, leg.recipient]);
        }
      }
    }
    for (final launcher in [four, flap, genius]) {
      if (_walletUses.containsKey(launcher) || identical(owner, launcher))
        continue;
      if (launcher.state == LaunchState.pending) {
        add(
          launcher,
          launcher.label,
          launcher.transactions
              .where((tx) => tx.status == 'submitted' || tx.status == 'unknown')
              .map((tx) => tx.from.address),
        );
      }
      if (launcher.pendingLiquidation) {
        add(
          launcher,
          '${launcher.label} · 清仓',
          api.pendingWalletsFor(launcher.unresolvedLiquidationHashes),
        );
      }
    }
    return overlaps;
  }

  WorkspacePage? _ownerPage(Object owner) {
    if (owner is GroupBase) return WorkspacePage.batch;
    if (owner is TransferRun) return WorkspacePage.tools;
    if (identical(owner, four)) return WorkspacePage.four;
    if (identical(owner, flap)) return WorkspacePage.flap;
    if (identical(owner, genius)) return WorkspacePage.genius;
    return null;
  }

  bool _transferRetainsPage(TransferRun run) => !run.complete &&
      run.legs.any((leg) => leg.status != TransferStatus.waiting &&
          leg.status != TransferStatus.skipped);

  String? workspaceBlockReason(WorkspacePage target) {
    for (final entry in _walletUses.entries) {
      final page = _ownerPage(entry.key);
      if (page != null && page != target) {
        return '${entry.value.label}正在处理，请先完成或取消这项操作。';
      }
    }
    for (final launcher in [four, flap, genius]) {
      if (_ownerPage(launcher) == target) continue;
      if (launcher.busy || launcher.state == LaunchState.pending ||
          launcher.pendingLiquidation) {
        return '${launcher.label}正在处理或等待回执，请先完成本次操作。';
      }
      if (launcher.state == LaunchState.launched &&
          (target == WorkspacePage.four || target == WorkspacePage.flap ||
              target == WorkspacePage.genius)) {
        return '${launcher.label}保留着本轮清仓名单，请先清仓或结束该轮发币。';
      }
    }
    if (target != WorkspacePage.batch) {
      for (final group in groups) {
        if (groupOperationBusy(group) || group.running ||
            (group is TradeGroup && (group.trader.unresolved.isNotEmpty || group.remaining != null)) ||
            (group is LinkedGroup && (group.trader.needsQuery || group.trader.resumable))) {
          return '${group.name}尚未结束，请先在批量交易页完成或结束本组。';
        }
      }
    }
    final currentTransfer = transfers.current;
    if (target != WorkspacePage.tools &&
        (transfers.running || transfers.unresolvedRuns.isNotEmpty ||
            (currentTransfer != null && _transferRetainsPage(currentTransfer)))) {
      return '分发或归集尚未结束，请先在钱包工具核实原转账或结束任务。';
    }
    return null;
  }

  void _requireWorkspace(WorkspacePage page) {
    final serviceError = api.financialConfigError;
    if (serviceError != null) throw WorkspaceConflict(serviceError.userMessage);
    if (_tokenSwitching) throw WorkspaceConflict(tokenLockReason!);
    final reason = workspaceBlockReason(page);
    if (reason != null) throw WorkspaceConflict(reason);
  }

  void checkWalletUse(Object owner, Iterable<String> addresses) {
    final overlaps = walletOverlaps(owner, addresses);
    if (overlaps.isNotEmpty) {
      throw WorkspaceConflict('钱包正在其他操作中使用', overlaps);
    }
    final page = _ownerPage(owner);
    if (page != null) _requireWorkspace(page);
    if (owner is TransferRun) {
      final current = transfers.current;
      if (_walletUses.keys.whereType<TransferRun>().any((other) => !identical(other, owner)) ||
          (current != null && !identical(current, owner) &&
              (transfers.running || _transferRetainsPage(current))) ||
          transfers.unresolvedRuns.any((other) => !identical(other, owner))) {
        throw WorkspaceConflict('另一项转账尚未结束，请先在钱包工具核实或结束该任务。');
      }
    }
  }

  /// Recheck once when a user starts or resumes an operation in the standalone site.
  Future<void> verifyFinancialService() async {
    if (!api.requireFeeFreeService) return;
    try {
      config = await api.config();
    } on Object {
      config = null;
      final reason = api.financialConfigError?.userMessage ?? '无法核实本站收费配置，请重试。';
      throw WorkspaceConflict(reason);
    }
  }

  Future<void> withWalletUse({
    required Object owner,
    required String label,
    required Iterable<String> addresses,
    required Future<void> Function() action,
  }) async {
    if (api.requireFeeFreeService) await verifyFinancialService();
    if (_disposed || _walletUses.containsKey(owner)) return;
    final involved = addresses.map((a) => a.toLowerCase()).toSet();
    checkWalletUse(owner, involved);
    _walletUses[owner] = (label: label, addresses: involved);
    try {
      await action();
    } finally {
      _walletUses.remove(owner);
    }
  }

  /// A single explanation used by every token-change entry point.
  String? get tokenLockReason =>
      _tokenSwitching ? '正在读取代币信息，请等待完成；期间不能切换代币或开始交易。' : _activeContextReason;

  String? get _activeContextReason {
    if (_operations.isNotEmpty) {
      final entry = _operations.entries.first;
      return '${entry.key.name}${entry.value.phase}，当前代币已锁定。请完成或取消本次操作后再切换。';
    }
    for (final g in groups) {
      if (g.running) return '${g.name}正在执行或暂停，当前代币已锁定。请先停止并核实交易结果。';
      if (g is TradeGroup) {
        if (g.trader.unresolved.isNotEmpty) {
          return '${g.name}有交易尚未确认，不能更换代币。请先查询原交易。';
        }
        if (g.remaining != null) {
          return '${g.name}有待续跑交易，不能更换代币。请执行剩余或结束本组。';
        }
      }
      if (g is LinkedGroup && (g.trader.needsQuery || g.trader.resumable)) {
        return '${g.name}本轮尚未结束，不能更换代币。请核实交易并结束本轮。';
      }
    }
    if (transfers.running || transfers.unresolvedRuns.isNotEmpty) {
      return '分发或归集尚未结束确认，不能更换代币。请先核实原转账。';
    }
    for (final launcher in [four, flap, genius]) {
      if (launcher.busy ||
          launcher.pendingLiquidation ||
          launcher.state == LaunchState.pending) {
        return '${launcher.label}正在准备或等待交易确认，不能更换代币。';
      }
    }
    for (final entry in _walletUses.entries) {
      final owner = entry.key;
      // Once creation confirms, the same launcher can adopt the new token.
      if (owner is Launcher && owner.state == LaunchState.launched) continue;
      return '${entry.value.label}正在处理，请先完成或取消后再切换代币。';
    }
    return null;
  }

  _GroupOperation _beginOperation(GroupBase g, {bool queryOriginal = false}) {
    if (_disposed || !groups.contains(g)) throw StateError('当前组已关闭');
    if (_tokenSwitching) throw StateError(tokenLockReason!);
    if (_operations.containsKey(g) || g.running) {
      throw StateError('${g.name}正在处理，请勿重复操作');
    }
    if (!queryOriginal) checkWalletUse(g, groupWallets(g, resume: true));
    final t = token ?? (throw StateError('请先选择代币'));
    final op = _GroupOperation(t, _tokenRevision, impactSettings);
    _operations[g] = op;
    _notify();
    return op;
  }

  void _checkOperation(GroupBase g, _GroupOperation op) {
    if (_disposed ||
        op.cancelled ||
        !identical(_operations[g], op) ||
        op.revision != _tokenRevision ||
        token?.address.toLowerCase() != op.token.address.toLowerCase()) {
      throw StateError('交易代币或准备状态已变化，请重新准备并核对地址');
    }
  }

  void _releaseOperation(GroupBase g, _GroupOperation op) {
    if (!identical(_operations[g], op)) return;
    op.quoteProgress?.finish();
    _operations.remove(g);
    // A page may release a pending confirmation while Flutter is disposing it.
    scheduleMicrotask(_notify);
  }

  void cancelPreparation(GroupBase g, {Object? handle}) {
    final op = _operations[g];
    if (op == null ||
        (op.executing && (g is! RapidGroup || g.running)) ||
        (handle != null && !identical(handle, op)))
      return;
    if (op.phase == '准备中' || op.cancelled) {
      // Wake the waiting preparation to release its own lease. Any late HTTP
      // response is checked against the captured operation or linked draw version.
      op.cancelled = true;
      op.quoteProgress?.cancel();
      op.phase = '正在取消准备';
      scheduleMicrotask(_notify);
      return;
    }
    if (g is LinkedGroup) g.trader.discardPrepared();
    _releaseOperation(g, op);
  }

  void _requireEditable(GroupBase g) {
    if (groupOperationBusy(g) || _walletUses.containsKey(g) || g.running) {
      throw StateError('${g.name}正在准备、确认或执行，请先取消或停止');
    }
    if (g is TradeGroup &&
        (g.trader.unresolved.isNotEmpty || g.remaining != null)) {
      throw StateError('本组有待确认或待续跑交易，请先核实并结束本组');
    }
    if (g is LinkedGroup && (g.trader.needsQuery || g.trader.resumable)) {
      throw StateError('关联组本轮未结束，请先核实并结束本轮');
    }
  }

  void _launchChanged() {
    for (final launcher in [four, flap, genius]) {
      final session = launcher.session;
      if (launcher.state != LaunchState.launched || session == null) continue;
      final id = '${session.platform}:${session.token.toLowerCase()}';
      if (!_seenLaunches.add(id)) continue;
      final pending = PendingLaunchToken(
        session.token,
        session.symbol,
        session.platform,
      );
      _pendingLaunchTokens.add(pending);
      tokenNotice =
          '${session.symbol} 已发行；当前仍为 ${token?.symbol ?? '尚未选择'}，请核对代币后交易。';
      // Try once at confirmation time. If blocked, require an explicit later switch:
      // never surprise the user when an unrelated group's lock eventually releases.
      scheduleMicrotask(() async {
        if (_disposed) return;
        if (tokenLockReason == null && _pendingLaunchTokens.length == 1) {
          try {
            await adoptLaunchToken(pending.address);
          } on Object catch (e) {
            if (!_disposed) {
              tokenNotice =
                  '新币 ${pending.symbol} 已发行，但尚未切换：$e。当前仍为 ${token?.symbol ?? '尚未选择'}，请勿误交易旧币。';
              log.add(tokenNotice!, level: LogLevel.error);
              _notify();
            }
          }
        } else {
          log.add(tokenNotice!, level: LogLevel.error);
          _notify();
        }
      });
    }
    _notify();
  }

  Future<void> adoptLaunchToken(String address) async {
    if (_disposed) throw StateError('页面已关闭');
    if (!_tokenSwitching &&
        token?.address.toLowerCase() == address.toLowerCase() &&
        market != null) {
      _pendingLaunchTokens.removeWhere(
        (p) => p.address.toLowerCase() == address.toLowerCase(),
      );
      _notify();
      return;
    }
    await loadToken(address);
  }

  GroupBase? get group =>
      groups.isEmpty ? null : groups[current.clamp(0, groups.length - 1)];

  Future<void> init() async {
    try {
      config = await api.config();
    } on Object catch (e) {
      log.add('服务暂不可用：$e', level: LogLevel.error);
    }
    _notify();
  }

  Future<void> loadToken(String address) async {
    final a = address.trim();
    if (!isAddress(a)) throw const FormatException('请输入有效的代币地址');
    if (_disposed) throw StateError('页面已关闭');
    final reason = tokenLockReason;
    if (reason != null) throw StateError(reason);
    _tokenSwitching = true;
    _notify();
    try {
      // Fetch together, then commit together. Failure leaves the prior token and venue intact.
      final values = await Future.wait<Object>([api.token(a), api.platform(a)]);
      if (_disposed) throw StateError('页面已关闭');
      final next = values[0] as TokenMeta;
      final nextMarket = Market(values[1] as Map<String, dynamic>);
      _validateTokenMarket(a, next, nextMarket);
      _requireCurrentFourSnapshot(nextMarket);
      final active = _activeContextReason;
      if (active != null) throw StateError(active);
      token = next;
      market = nextMarket;
      _tokenRevision++;
      _pendingLaunchTokens.removeWhere(
        (p) => p.address.toLowerCase() == a.toLowerCase(),
      );
      tokenNotice = '当前代币已切换为 ${next.symbol} · BSC，请核对合约地址后交易。';
      for (final g in groups) {
        if (g is TradeGroup) g.states = {};
        if (g is LinkedGroup) g.states = {};
      }
      log.add('当前代币：${next.symbol}（${next.address}） · ${nextMarket.label}');
      _notify();
      unawaited(_warmBalances(_tokenRevision, next.address));
    } finally {
      _tokenSwitching = false;
      _notify();
    }
  }

  /// Snapshot all active wallets in one batch. A new token, removed group,
  /// key edit or manual refresh wins over an older background response.
  Future<void> _warmBalances(int revision, String address) async {
    Set<String> owners(GroupBase g) => {
      for (final w
          in (g is LinkedGroup
              ? [...g.sellers, ...g.buyers, ...g.transits]
              : g.allWallets))
        w.address.toLowerCase(),
    };
    final batches = {for (final g in groups) g: owners(g)};
    final requests = {
      for (final g in batches.keys)
        g: _balanceReads[g] = (_balanceReads[g] ?? 0) + 1,
    };
    final wallets = {for (final batch in batches.values) ...batch};
    if (wallets.isEmpty) return;
    bool current() =>
        !_disposed &&
        revision == _tokenRevision &&
        token?.address.toLowerCase() == address.toLowerCase();
    try {
      final list = await api.walletStates(wallets.toList(), token: address);
      if (!current()) return;
      final rows = {for (final r in list) r.wallet.toLowerCase(): r};
      for (final entry in batches.entries) {
        final g = entry.key;
        if (!groups.contains(g) ||
            requests[g] != _balanceReads[g] ||
            !setEquals(owners(g), entry.value))
          continue;
        final states = {
          for (final addr in entry.value)
            if (rows.containsKey(addr)) addr: rows[addr]!,
        };
        if (g is TradeGroup) g.update((g) => g.states = states);
        if (g is LinkedGroup) g.update((g) => g.states = states);
      }
    } on Object {
      if (current()) log.add('部分钱包余额未更新，可在日志中刷新钱包数据', level: LogLevel.error);
    }
  }

  void _validateTokenMarket(String address, TokenMeta meta, Market venue) {
    if (meta.address.toLowerCase() != address.toLowerCase() ||
        venue.address.toLowerCase() != address.toLowerCase() ||
        meta.decimals == null ||
        meta.decimals! < 0 ||
        meta.decimals! > 255 ||
        venue.decimals != meta.decimals) {
      throw StateError('代币或市场信息不一致，请重新读取；当前代币未更换');
    }
  }

  void _recordTradeParticipant(String token, TradeWallet wallet) {
    for (final launcher in [four, flap, genius]) {
      launcher.recordTradeParticipant(token, wallet);
    }
  }

  void _displayFourGraduation(TradeGroup group, Market venue) {
    final op = _operations[group], current = market;
    final address = venue.address.toLowerCase();
    if (_disposed || op == null || !op.executing || op.cancelled ||
        op.revision != _tokenRevision || token?.address.toLowerCase() != address ||
        current == null || current.address.toLowerCase() != address ||
        current.platform != 'four' || venue.platform != 'four' || !venue.external ||
        current.raw['identity'] == null || current.raw['identity'] != venue.raw['identity'] ||
        venue.block <= current.block ||
        (current.external && current.pool?.toLowerCase() != venue.pool?.toLowerCase())) return;
    market = venue;
    _notify();
  }

  // A concurrent market read can finish after another group has confirmed graduation.
  void _requireCurrentFourSnapshot(Market venue) {
    final current = market;
    if (current != null && current.platform == 'four' && current.external &&
        current.address.toLowerCase() == venue.address.toLowerCase() &&
        (venue.block < current.block || !venue.external ||
            venue.raw['identity'] != current.raw['identity'])) {
      throw StateError('Four 外盘状态已更新，请重新检查');
    }
  }

  TradeGroup addGroup() {
    final g = TradeGroup(_next++, api, log)..addListener(_notify);
    g.trader.onTradeSubmitted = _recordTradeParticipant;
    g.trader.onFourExternalVerified = (venue) => _displayFourGraduation(g, venue);
    groups.add(g);
    current = groups.length - 1;
    _notify();
    return g;
  }

  RapidGroup addRapidGroup() {
    final g = RapidGroup(_next++, api, log)..addListener(_notify);
    g.trader.onTradeSubmitted = _recordTradeParticipant;
    groups.add(g);
    current=groups.length-1;
    _notify();
    return g;
  }

  void select(int index) {
    current = index;
    _notify();
  }

  LinkedGroup addLinkedGroup() {
    final g = LinkedGroup(_next++, api, log)..addListener(_notify);
    g.trader.trader.onTradeSubmitted = _recordTradeParticipant;
    groups.add(g);
    current = groups.length - 1;
    _notify();
    return g;
  }

  void removeGroup(GroupBase g) {
    _requireEditable(g);
    if (g is LinkedGroup && g.trader.needsQuery) {
      throw StateError('有交易尚未确认，请先查询原交易');
    }
    if (g is TradeGroup && g.trader.unresolved.isNotEmpty) {
      throw StateError('有交易尚未确认，请先查询原交易');
    }
    groups.remove(g);
    _balanceReads.remove(g);
    g.dispose();
    current = groups.isEmpty ? 0 : current.clamp(0, groups.length - 1);
    _notify();
  }

  /// Groups may share a wallet. An overlap is reviewed when an operation starts.
  Future<int> setKeys(TradeGroup g, String text) async {
    _requireEditable(g);
    final parsed = parsePrivateKeys(text, existing: const {}, startIndex: 0);
    final kept = {for (final w in g.wallets) w.address: w};
    g.wallets = [for (final w in parsed) kept[w.address] ?? w];
    g.selected
      ..clear()
      ..addAll(g.wallets.map((w) => w.address));
    g.states = {};
    g.remaining = null;
    final backup = walletBackup?.capture(
      WalletBackupCategory.tradeGroup,
      g.wallets,
      scope: g.name,
    );
    g.update((_) {});
    await _save();
    await backup;
    if (_disposed || !groups.contains(g)) return parsed.length;
    if (g.wallets.isNotEmpty) {
      // Keys are already stored; a failed balance read only leaves the totals empty.
      await refresh(g).catchError(
        (Object e) => log.add('${g.name} 余额读取失败：$e', level: LogLevel.error),
      );
    }
    return parsed.length;
  }

  Future<void> refresh(TradeGroup g, {bool force = false}) async {
    if (g.wallets.isEmpty) return;
    final revision = _tokenRevision;
    final request = (_balanceReads[g] ?? 0) + 1;
    _balanceReads[g] = request;
    final read = force ? api.refreshWalletStates : api.walletStates;
    final list = await read([
      for (final w in g.wallets) w.address,
    ], token: token?.address);
    if (_disposed ||
        revision != _tokenRevision ||
        _balanceReads[g] != request ||
        !groups.contains(g))
      return;
    g.update(
      (x) => x.states = {for (final s in list) s.wallet.toLowerCase(): s},
    );
  }

  Future<void> refreshWalletLedger() async {
    if (_operations.isNotEmpty ||
        transfers.running ||
        [four, flap, genius].any((l) => l.busy)) {
      throw StateError('请先结束当前操作，再刷新钱包数据');
    }
    await api.refreshKnownWallets();
    await Future.wait([
      for (final g in List.of(groups))
        if (g is TradeGroup)
          refresh(g)
        else if (g is LinkedGroup)
          refreshLinked(g),
    ]);
  }

  Future<RapidPrepared> prepareRapid(RapidGroup g) async {
    final op=_beginOperation(g);
    try {
      final venue = await _readOperationMarket(g, op);
      final plan=g.rapidPlan(op.token,op.settings.intervalLive,venue);
      await walletBackup?.requireStoredIfConnected(WalletBackupCategory.tradeGroup, plan.wallets,scope:g.name);
      _checkOperation(g,op);
      requireReceivable(plan.wallets.map((w)=>w.address));
      final prepared = await g.trader.prepareRapid(plan, () => !_disposed && !op.cancelled && identical(_operations[g],op));
      _checkOperation(g,op);
      op.rapid=prepared;op.phase='等待确认';_notify();
      return prepared;
    } catch (_) { _releaseOperation(g,op); rethrow; }
  }

  Future<TradeOutcome> startRapid(RapidGroup g,RapidPrepared prepared) async {
    final op=_operations[g];
    if(op==null || op.executing || !identical(op.rapid,prepared)) throw StateError('本次快速组检查已失效');
    op.executing=true;op.phase='执行中';_notify();
    try {
      _checkOperation(g,op);
      if(!identical(op.settings,impactSettings)) throw StateError('风控设置已变更，请重新检查');
      await walletBackup?.requireStoredIfConnected(WalletBackupCategory.tradeGroup,prepared.plan.wallets,scope:g.name);
      _checkOperation(g,op);
      await _executionMarket(g, op, prepared.plan.market!);
      return await g.trader.runRapid(prepared);
    } finally { _releaseOperation(g,op); }
  }

  /// Draw and quote the first round (web "预计使用" / "预计到账" / "首轮参考到账") before anything is signed.
  Future<PreparedRound> prepare(TradeGroup g, {bool resume = false, WarmGroupQuote? warmed}) async {
    final op = _beginOperation(g);
    final budget = op.quoteProgress = QuoteProgress(_notify);
    try {
      if (resume && g.remaining == null) throw StateError('剩余进度不可用，请结束本组后重新开始');
      final initial = g.plan(
        op.token.address,
        op.token.decimals,
        market: market,
        maxImpactPercent: op.settings.intervalLive,
        resume: resume ? Map.of(g.remaining!) : null,
      );
      if (walletBackup != null) {
        await _checkTradeBackup(g, op, initial);
      }
      final venue = await budget.read(() => _readOperationMarket(g, op));
      final plan = _tradePlan(initial, venue);
      op.tradePlan = plan;
      if(warmed!=null) {_takeWarm(g,warmed,venue);op.warmed=warmed;}
      final PreparedRound prepared = warmed?.normal ?? await budget.read<PreparedRound>(() => g.trader.prepare(plan));
      _checkOperation(g, op);
      if (!plan.buy && plan.market?.innerPlatform==null) {
        await g.trader.prepareSellApprovals(token: plan.token, market: plan.market, wallets: plan.wallets,
            amounts: plan.loop ? {for (final key in prepared.amounts.keys) key: prepared.startingBalances[key]!} : prepared.amounts,
            allowSubmit:warmed?.needsApproval??true, active: () => !op.cancelled && identical(_operations[g], op));
        _checkOperation(g, op);
      }
      final grants = await g.trader.forecastRouteGrants(plan.market, plan.buy, prepared.amounts,
          cycleBudget: plan.loop ? prepared.startingBalances : null, settlement: plan.settlement);
      await g.trader.checkRouteGrants(plan.market,plan.wallets,grants,
          allowSubmit:warmed?.needsApproval??true,active:() => !op.cancelled && identical(_operations[g],op));
      _checkOperation(g, op);
      op.prepared = prepared;
      final use = _walletUses[g];
      if (use != null && !plan.loop) {
        use.addresses.retainAll(prepared.amounts.keys);
      }
      op.review = ImpactReview(
        plan.mode,
        prepared.impact,
        op.settings,
        v4: prepared.v4ImpactUnavailable,
        canConfirmUnknown: prepared.canConfirmUnknown,
      );
      budget.finish();
      op.quoteProgress = null;
      op.phase = '等待确认';
      _notify();
      return prepared;
    } on Object {
      _releaseOperation(g, op);
      rethrow;
    }
  }

  /// Execute the pinned token, wallets, direction and exact amounts the user confirmed.
  Future<TradeOutcome> start(
    TradeGroup g, {
    bool resume = false,
    PreparedRound? prepared,
    bool impactConfirmed = false,
  }) async {
    final existing = _operations[g];
    if (prepared == null ||
        existing == null ||
        !identical(existing.prepared, prepared)) {
      throw StateError('准备结果已失效，请重新准备并核对代币地址');
    }
    if (existing.executing || existing.phase != '等待确认') {
      throw StateError('本组正在处理，请勿重复执行');
    }
    if (existing.review == null) {
      throw StateError('请先准备本次交易并确认');
    }
    final op = existing;
    final review = op.review!;
    final ceiling = review.ceiling(impactConfirmed);
    op.executing = true;
    op.phase = '执行中';
    _notify();
    try {
      _checkOperation(g, op);
      if (resume && g.remaining == null) throw StateError('剩余进度不可用，请结束本组后重新开始');
      final initial = op.tradePlan!;
      if (walletBackup != null) {
        await _checkTradeBackup(g, op, initial, amounts: prepared.amounts);
      }
      final venue = await _executionMarket(g, op, initial.market!);
      if (!identical(op.settings, _impactSettings))
        throw StateError('价格影响设置已更新，请重新准备并确认');
      _checkWarmExecution(g,op);
      final plan = _tradePlan(
        initial,
        venue,
        amounts: op.prepared!.amounts,
        startingBalances: op.prepared!.startingBalances,
        ceiling: ceiling,
        allowUnknownImpact: impactConfirmed && review.canConfirmUnknown,
      );
      g.remaining = null;
      final out = await g.trader.run(plan);
      if (out.stopped && out.remaining.isNotEmpty) {
        g.remaining = Map.of(out.remaining);
        g.remainingBasis = prepared.startingBalances;
      }
      g.update((_) {});
      await refresh(g).catchError((Object _) {});
      return out;
    } finally {
      _releaseOperation(g, op);
    }
  }

  Future<void> _checkTradeBackup(
    TradeGroup g,
    _GroupOperation op,
    TradePlan plan, {
    Map<String, BigInt>? amounts,
  }) async {
    final selected = plan.loop ? null : amounts ?? plan.resume;
    final wallets = plan.wallets.where(
      (w) => selected == null || selected.containsKey(w.address.toLowerCase()),
    );
    await walletBackup!.requireStoredIfConnected(
      WalletBackupCategory.tradeGroup,
      wallets,
      scope: g.name,
    );
    _checkOperation(g, op);
    requireReceivable(wallets.map((w) => w.address));
  }

  void _checkWarmExecution(GroupBase g,_GroupOperation op){
    final warm=op.warmed;
    if(warm!=null&&(!warm.fresh||quoteIdentity(g)!=warm.identity)) throw StateError('报价或参数已变更，请重新检查');
  }

  Future<Market> _readOperationMarket(GroupBase g, _GroupOperation op) async {
    final venue = Market(await api.platform(op.token.address));
    _checkOperation(g, op);
    _validateTokenMarket(op.token.address, op.token, venue);
    _requireCurrentFourSnapshot(venue);
    op.marketRead = DateTime.now();
    market = venue;
    _notify();
    return venue;
  }

  Future<Market> _executionMarket(
    GroupBase group,
    _GroupOperation op,
    Market prepared,
  ) async {
    if (op.marketRead != null &&
        DateTime.now().difference(op.marketRead!) <
            const Duration(seconds: 2)) {
      return prepared;
    }
    final current = await PreviewDeadline().read(
      () => _readOperationMarket(group, op),
    );
    if (!sameTradeMarket(prepared, current))
      throw StateError('交易市场已变化，请重新准备并确认');
    return current;
  }

  TradePlan _tradePlan(
    TradePlan p,
    Market venue, {
    Map<String, BigInt>? amounts,
    Map<String, BigInt>? startingBalances,
    double? ceiling,
    bool allowUnknownImpact = false,
  }) => TradePlan(
    token: p.token,
    buy: p.buy,
    wallets: List.unmodifiable(p.wallets),
    mode: p.mode,
    amount: p.amount,
    intervalMin: p.intervalMin,
    intervalMax: p.intervalMax,
    loop: p.loop,
    randomOrder: p.randomOrder,
    market: venue,
    maxImpactPercent: ceiling ?? p.maxImpactPercent,
    allowUnknownImpact: allowUnknownImpact,
    savedRouter: p.market?.platform == venue.platform ? p.savedRouter : null,
    exact: p.exact == null ? null : Map.unmodifiable(p.exact!),
    resume: amounts != null ? Map.unmodifiable(amounts) : p.resume,
    startingBalances: startingBalances ?? p.startingBalances,
    tip: p.tip,
  );

  LinkedPlan _linkedPlan(
    LinkedPlan p,
    Market venue, {
    double? firstLegCeiling,
    bool firstLegBuy = false,
    bool firstLegAllowUnknown = false,
  }) => LinkedPlan(
    token: p.token,
    market: venue,
    sellers: List.unmodifiable(p.sellers),
    buyers: List.unmodifiable(p.buyers),
    transits: p.transits == null ? null : List.unmodifiable(p.transits!),
    sizing: p.sizing,
    mode: p.mode,
    intervalMin: p.intervalMin,
    intervalMax: p.intervalMax,
    loop: p.loop,
    randomOrder: p.randomOrder,
    maxImpactPercent: p.maxImpactPercent,
    firstLegCeiling: firstLegCeiling,
    firstLegBuy: firstLegBuy,
    firstLegAllowUnknown: firstLegAllowUnknown,
    savedRouter: p.market?.platform == venue.platform ? p.savedRouter : null,
  );

  /// "结束本组": drop the remaining wallets of an interrupted round. Confirmed trades stay.
  void endGroup(TradeGroup g) {
    if (groupOperationBusy(g)) throw StateError('请先取消准备或等待当前操作完成');
    if (g.running) throw StateError('本组正在执行，请先停止');
    if (g.trader.unresolved.isNotEmpty) throw StateError('请先查询原交易');
    g.remaining = null;
    log.add('${g.name} 已结束本组');
    g.update((_) {});
  }

  Future<void> query(GroupBase g) async {
    if (g is LinkedGroup && g.trader.reconciling) {
      if (_disposed || !groups.contains(g)) throw StateError('当前组已关闭');
      await g.trader.query();
      return;
    }
    final op = _beginOperation(g, queryOriginal: true);
    op.executing = true;
    op.phase = '查询交易中';
    try {
      if (g is TradeGroup) {
        if (g is RapidGroup) { await g.trader.queryRapid(); } else { await g.trader.query(); }
        await refresh(g).catchError((Object _) {});
      } else if (g is LinkedGroup) {
        await g.trader.query();
        await refreshLinked(g).catchError((Object _) {});
      }
    } finally {
      _releaseOperation(g, op);
    }
  }

  // ---------------------------------------------------------------- linked groups

  /// Replace one side's keys. Buyers get one generated relay each (kept for re-added buyers).
  Future<int> setLinkedKeys(
    LinkedGroup g, {
    required bool sellers,
    required String text,
  }) async {
    _requireEditable(g);
    if (g.locked) throw StateError('本轮未结束，请先结束本轮再修改私钥');
    final otherSide = {
      for (final w in (sellers ? g.buyers : g.sellers)) w.address.toLowerCase(),
    };
    final relays = {for (final w in g.allTransits) w.address.toLowerCase()};
    final parsed = parsePrivateKeys(text, existing: const {}, startIndex: 0);
    if (parsed.any((w) => otherSide.contains(w.address.toLowerCase()))) {
      throw StateError('买卖两侧的钱包不能重复');
    }
    if (parsed.any((w) => relays.contains(w.address.toLowerCase()))) {
      throw StateError('中转地址不能作为买卖钱包');
    }
    if (!_editingLinkedKeys.add(g)) throw StateError('正在保存关联组钱包，请稍后重试');
    try {
      final backup = walletBackup;
      await backup?.capture(
        sellers ? WalletBackupCategory.linkedSeller : WalletBackupCategory.linkedBuyer,
        parsed,
        scope: g.name,
      );
      final pairs = sellers ? const <String, TradeWallet>{} : await _verifiedRelays(
        recipients: parsed.map((w) => w.address),
        existing: g.transitByBuyer,
        drafts: g._draftRelays,
        category: WalletBackupCategory.linkedTransit,
        prefix: 'T',
        scope: g.name,
      );
      if (_disposed || !groups.contains(g)) throw StateError('关联组已关闭');
      _requireEditable(g);
      if (g.locked) throw StateError('本轮未结束，请先结束本轮再修改私钥');
      if (sellers) {
        g.sellers = parsed;
      } else {
        g.transitByBuyer.addAll(pairs);
        g._draftRelays.removeWhere((recipient, _) => pairs.containsKey(recipient));
        g.buyers = parsed;
      }
      g.states = {};
      g.update((_) {});
      await _save();
    } finally {
      _editingLinkedKeys.remove(g);
    }
    if (_disposed || !groups.contains(g)) return parsed.length;
    if (g.sellers.isNotEmpty || g.buyers.isNotEmpty) {
      await refreshLinked(g).catchError(
        (Object e) => log.add('${g.name} 余额读取失败：$e', level: LogLevel.error),
      );
    }
    return parsed.length;
  }

  Future<void> refreshLinked(LinkedGroup g, {bool force = false}) async {
    final all = [...g.sellers, ...g.buyers, ...g.transits];
    if (all.isEmpty) return;
    final revision = _tokenRevision;
    final request = (_balanceReads[g] ?? 0) + 1;
    _balanceReads[g] = request;
    final read = force ? api.refreshWalletStates : api.walletStates;
    final list = await read([
      for (final w in all) w.address,
    ], token: token?.address);
    if (_disposed ||
        revision != _tokenRevision ||
        _balanceReads[g] != request ||
        !groups.contains(g))
      return;
    g.update(
      (x) => x.states = {for (final s in list) s.wallet.toLowerCase(): s},
    );
  }

  Future<void> _checkLinkedBackup(LinkedGroup g, _GroupOperation op) async {
    final backup = walletBackup;
    if (backup != null) {
      await Future.wait([
        backup.requireStoredIfConnected(
          WalletBackupCategory.linkedSeller, g.sellers, scope: g.name,
        ),
        backup.requireStoredIfConnected(
          WalletBackupCategory.linkedBuyer, g.buyers, scope: g.name,
        ),
        backup.requireTransitsStoredIfConnected(
          WalletBackupCategory.linkedTransit, g.activeTransitPairs, scope: g.name,
        ),
      ]);
      _checkOperation(g, op);
      requireReceivable(groupWallets(g));
    }
    if (!g.transitsBackedUp) {
      throw StateError(backup == null
          ? '中转地址会接收资金，开始前请先复制保存中转私钥'
          : '中转私钥尚未写入本地备份目录，请完成备份后重试');
    }
  }

  Future<LinkedPreview> prepareLinked(LinkedGroup g,{WarmGroupQuote? warmed}) async {
    final op = _beginOperation(g);
    final budget = op.quoteProgress = QuoteProgress(_notify);
    try {
      g.trader.discardPrepared();
      await _checkLinkedBackup(g, op);
      final initial = g.plan(
        op.token.address,
        op.token.decimals,
        market: market,
        maxImpactPercent: op.settings.bundle,
      );
      final venue = await budget.read(() => _readOperationMarket(g, op));
      final plan = _linkedPlan(initial, venue);
      op.linkedPlan = plan;
      if(warmed!=null) {_takeWarm(g,warmed,venue);op.warmed=warmed;}
      final LinkedPreview prepared = warmed?.linked ?? await budget.read<LinkedPreview>(() => g.trader.prepare(plan));
      if(warmed!=null) g.trader.adoptPreview(plan,prepared);
      _checkOperation(g, op);
      if ((!prepared.buy || plan.loop) && plan.market?.innerPlatform==null) {
        final needed = await g.trader.sellApprovalAmounts(plan, prepared);
        _checkOperation(g, op);
        await g.trader.trader.prepareSellApprovals(token: plan.token, market: plan.market, wallets: plan.sellers,
            amounts: needed, allowSubmit:warmed?.needsApproval??true, active: () => !op.cancelled && identical(_operations[g], op));
        _checkOperation(g, op);
      }
      await g.trader.checkLinkedGrants(plan, prepared, allowSubmit:warmed?.needsApproval??true,
          active:() => !op.cancelled && identical(_operations[g],op));
      _checkOperation(g, op);
      op.linkedBuy = prepared.buy;
      op.review = ImpactReview(
        plan.mode,
        prepared.impact,
        op.settings,
        v4: prepared.v4,
        canConfirmUnknown: prepared.canConfirmUnknown,
      );
      budget.finish();
      op.quoteProgress = null;
      op.phase = '等待确认';
      _notify();
      return prepared;
    } on Object {
      g.trader.discardPrepared();
      _releaseOperation(g, op);
      rethrow;
    }
  }

  Future<LinkedProgress> startLinked(
    LinkedGroup g, {
    bool impactConfirmed = false,
    Object? handle,
  }) async {
    final existing = _operations[g];
    if (existing != null && (existing.executing || existing.phase != '等待确认')) {
      throw StateError('本组正在处理，请勿重复执行');
    }
    if (existing == null ||
        existing.review == null ||
        existing.linkedPlan == null ||
        !identical(handle, existing)) {
      throw StateError('请先准备关联交易并确认');
    }
    final op = existing;
    final review = op.review!;
    final ceiling = review.ceiling(impactConfirmed);
    op.executing = true;
    op.phase = '执行中';
    _notify();
    try {
      _checkOperation(g, op);
      await _checkLinkedBackup(g, op);
      final initial = op.linkedPlan!;
      final venue = await _executionMarket(g, op, initial.market!);
      if (!identical(op.settings, _impactSettings))
        throw StateError('价格影响设置已更新，请重新准备并确认');
      _checkWarmExecution(g,op);
      final out = await g.trader.run(
        _linkedPlan(
          initial,
          venue,
          firstLegCeiling: ceiling,
          firstLegBuy: op.linkedBuy,
          firstLegAllowUnknown: impactConfirmed && review.canConfirmUnknown,
        ),
      );
      await refreshLinked(g).catchError((Object _) {});
      return out;
    } finally {
      _releaseOperation(g, op);
    }
  }

  void finishLinked(LinkedGroup g) {
    if (groupOperationBusy(g)) throw StateError('请先取消准备或等待当前操作完成');
    g.trader.finish();
    unawaited(refreshLinked(g).catchError((Object _) {}));
  }

  /// Relay keys for an explicit export (active relays first).
  String exportTransits(LinkedGroup g) {
    final active = g.transits;
    final list = [
      ...active,
      ...g.allTransits.where((t) => !active.contains(t)),
    ];
    return exportKeys(list);
  }

  // ---------------------------------------------------------------- tools

  void stopGeneratingWallets() {
    if (!generatingWallets || _stopGenerationRequested || _generatedWalletCount == _generationTarget) return;
    _stopGenerationRequested = true;
    _notify();
  }

  Future<List<TradeWallet>> generate(int count) async {
    if (count < 1 || count > 10000) throw const FormatException('数量需在 1–10000 之间');
    if (_disposed) throw StateError('工作台已关闭');
    if (generatingWallets) throw StateError('已有钱包正在生成');
    final directory = walletBackup;
    if (directory?.selecting == true) throw const WalletBackupException('请等待备份目录连接完成');
    final epoch = directory?.selectionEpoch;
    final created = <TradeWallet>[];
    Future<void>? backup;
    _generationTarget = count;
    _notify();
    try {
      // Browser input and painting run on the same thread as key derivation.
      // Bound each work slice by elapsed time, including on slower computers.
      const pause = Duration(milliseconds: 1);
      if (count >= 32) await Future<void>.delayed(pause);
      final slice = Stopwatch()..start();
      final progress = Stopwatch()..start();
      while (created.length < count && !_stopGenerationRequested &&
          !_disposed && epoch == directory?.selectionEpoch) {
        created.add(TradeWallet.generate('N${created.length + 1}'));
        _generatedWalletCount = created.length;
        if (count > 2 && created.length < count &&
            (slice.elapsedMilliseconds >= 12 || (count >= 32 && created.length == 1))) {
          if (created.length == 1 || progress.elapsedMilliseconds >= 80) {
            _notify();
            progress.reset();
          }
          await Future<void>.delayed(pause);
          slice.reset();
        }
      }
      if (_disposed) throw StateError('工作台已关闭');
      if (epoch != directory?.selectionEpoch) {
        throw const WalletBackupException('备份目录已切换，请重新生成');
      }
      if (created.isNotEmpty) {
        final batch = GeneratedWalletBatch(
          id: created.first.address.toLowerCase(),
          number: _nextGeneratedNumber++,
          wallets: List.unmodifiable(created),
        );
        _generatedBatches.add(batch);
        backup = directory?.capture(
          WalletBackupCategory.toolGenerated, created, scope: batch.id,
        );
      }
      final result = _stopGenerationRequested
          ? '已停止生成，本次生成 ${created.length}/$count 个钱包'
          : '已生成 ${created.length} 个钱包';
      log.add(directory == null && created.isNotEmpty ? '$result，接收资金前请先复制保存私钥' : result);
    } finally {
      _generationTarget = 0;
      _generatedWalletCount = 0;
      _stopGenerationRequested = false;
      _notify();
    }
    // Stopping key generation never cancels the write or its readback.
    await backup;
    return created;
  }

  Future<void> renameGeneratedBatch(GeneratedWalletBatch batch, String value) async {
    final name = value.trim();
    if (name.isEmpty || name.length > 64 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
      throw const FormatException('组名需为 1–64 个字符，不可包含控制字符');
    }
    if (!_generatedBatches.contains(batch)) throw StateError('分组已更新，请重新选择');
    final backup = walletBackup;
    if (backup != null) {
      if (batch.wallets.any((wallet) => !wallet.canReceiveFunds)) {
        throw const WalletBackupException('请先完成本组私钥备份');
      }
      await backup.renameGeneratedBatch(batch, name);
    }
    if (_disposed || !_generatedBatches.contains(batch)) return;
    batch.storedName = name;
    _notify();
  }

  Future<void> deleteGeneratedBatch(GeneratedWalletBatch batch) async {
    if (_disposed) throw StateError('工作台已关闭');
    if (!_generatedBatches.contains(batch)) throw StateError('分组已更新，请重新选择');
    if (generatingWallets) throw StateError('请等待钱包生成结束');
    if (batch.wallets.any((wallet) => !wallet.canReceiveFunds)) {
      throw const WalletBackupException('请先完成本组私钥备份');
    }
    await walletBackup?.deleteGeneratedBatch(batch);
    if (!_disposed && _generatedBatches.remove(batch)) _notify();
  }

  /// The embedding host may use a confirmed clipboard export as its backup.
  /// The Web workspace unlocks generated wallets only after a directory write.
  String exportKeys(List<TradeWallet> list) {
    final keys = formatPrivateKeyLines(list);
    markKeysCopied(list);
    return keys;
  }

  void markKeysCopied(List<TradeWallet> list) {
    if (walletBackup == null) {
      for (final w in list) {
        w.backedUp = true;
      }
    }
    _notify();
  }

  /// Also covers historical relays whose group has been removed before backup.
  Set<String> get unbackedAddresses => {
    ...?walletBackup?.unbackedAddresses,
    for (final batch in _generatedBatches)
      for (final w in batch.wallets)
        if (!w.canReceiveFunds) w.address.toLowerCase(),
  };

  void requireReceivable(Iterable<String> addresses) {
    final blocked = walletBackup?.unbackedAddresses;
    if (blocked != null &&
        addresses.any((a) => blocked.contains(a.toLowerCase()))) {
      throw const WalletBackupException('本次收款地址含尚未写入本地目录的新钱包，请先完成钱包备份。');
    }
  }

  /// Stop sending in every group (scope revoked / module closed). Submitted transactions are not withdrawn.
  void stopAll() {
    for (final g in groups) {
      g.cancel();
    }
    transfers.stop();
  }

  Future<T> guard<T>(Future<T> Function() run) async {
    if (busy) throw StateError('请等待当前操作完成');
    busy = true;
    _notify();
    try {
      return await run();
    } finally {
      busy = false;
      _notify();
    }
  }

  /// Restore a complete file against an independently supplied recipient list.
  Future<int> restoreTransits(
    String text,
    String recipients, {
    LinkedGroup? group,
  }) async {
    final category = group == null
        ? WalletBackupCategory.distributionTransit
        : WalletBackupCategory.linkedTransit;
    final expected = parseRecipients(
      recipients,
      rejectDuplicates: true,
    ).map((a) => a.toLowerCase()).toSet();
    final file = parseWalletFile(
      text,
      target: (category: category, scope: group?.name ?? ''),
      recipients: expected,
    );
    if (file.category != category ||
        (group != null && file.scope != group.name)) {
      throw const FormatException('备份用途或关联组编号与当前位置不同');
    }
    if (file.pairs.isEmpty || expected.length != file.pairs.length ||
        !expected.containsAll(file.pairs.keys)) {
      throw const FormatException('核对的接收地址与备份对应关系不一致');
    }
    final map = group?.transitByBuyer ?? distributionTransits;
    void check() {
      if (_disposed) throw StateError('工作台已关闭');
      if (group != null) {
        if (!groups.contains(group)) throw StateError('关联组已关闭');
        _requireEditable(group);
        if (_editingLinkedKeys.contains(group)) throw StateError('关联组正在保存钱包，请稍后恢复');
        if (group.locked) throw StateError('请先结束本轮再恢复中转备份');
      } else if (transfers.running) {
        throw StateError('分发或归集正在执行');
      }
      final recipients = {...map.keys, ...file.pairs.keys};
      final owners = {
        for (final e in map.entries) e.value.address.toLowerCase(): e.key,
      };
      final participants = {
        if (group != null)
          ...[
            ...group.sellers,
            ...group.buyers,
          ].map((w) => w.address.toLowerCase()),
      };
      for (final e in file.pairs.entries) {
        final relay = e.value.address.toLowerCase(),
            current = map[e.key]?.address.toLowerCase();
        if ((current != null && current != relay) ||
            (owners[relay] != null && owners[relay] != e.key) ||
            recipients.contains(relay) ||
            owners.containsKey(e.key) ||
            participants.contains(relay)) {
          throw StateError('接收方或中转地址与已有钱包或对应关系冲突，已保留原记录');
        }
      }
    }

    check();
    for (final wallet in file.wallets) {
      walletBackup?.rememberOriginalCategory(wallet.address, file.originalCategoryFor(wallet));
    }
    await walletBackup?.requireTransitsStoredIfConnected(
      category,
      file.pairs,
      scope: group?.name ?? '',
    );
    check();
    final added = Map.of(file.pairs)..removeWhere((recipient, _) => map.containsKey(recipient));
    map.addAll(added);
    try {
      await _save();
    } on Object {
      for (final e in added.entries) {
        if (identical(map[e.key], e.value)) map.remove(e.key);
      }
      rethrow;
    }
    if (group != null) group.update((_) {});
    log.add('${group?.name ?? '分发'}已恢复 ${file.pairs.length} 对中转钱包');
    _notify();
    return file.pairs.length;
  }

  Future<Map<String, TradeWallet>> _verifiedRelays({
    required Iterable<String> recipients,
    required Map<String, TradeWallet> existing,
    required Map<String, TradeWallet> drafts,
    required String category,
    required String prefix,
    String scope = '',
  }) async {
    final owners = recipients.map((address) => address.toLowerCase()).toSet();
    if (owners.isEmpty) return {};
    final backup = walletBackup;
    if (backup != null && !backup.hasSelectedDirectory) {
      throw const WalletBackupException('请先连接本地备份目录，再生成中转地址');
    }
    final pairs = {
      for (final owner in owners)
        owner: existing[owner] ?? drafts.putIfAbsent(owner,
            () => TradeWallet.generate('$prefix${existing.length + drafts.length + 1}')),
    };
    if (backup != null) {
      await backup.requireTransitsStoredIfConnected(category, pairs, scope: scope);
      if (pairs.values.any((wallet) => !wallet.canReceiveFunds)) {
        throw WalletBackupException(backup.errorMessage ?? '中转私钥尚未完成写入与回查');
      }
    }
    for (final e in pairs.entries) {
      if (existing[e.key] case final current? when current.address != e.value.address) {
        throw StateError('中转钱包对应关系已变化，请重试');
      }
    }
    return pairs;
  }

  /// A Web relay is published only after its recipient-bound record is durable.
  Future<Map<String, TradeWallet>> transitsFor(List<String> recipients) async {
    final pairs = await _verifiedRelays(
      recipients: recipients, existing: distributionTransits, drafts: _draftDistribution,
      category: WalletBackupCategory.distributionTransit, prefix: 'D',
    );
    if (_disposed) throw StateError('工作台已关闭');
    distributionTransits.addAll(pairs);
    _draftDistribution.removeWhere((recipient, _) => pairs.containsKey(recipient));
    await _save();
    return pairs;
  }

  Future<void> _save() => store.save([
    for (final g in groups) ...g.allWallets,
    ...distributionTransits.values,
  ]);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    walletBackup?.dispose();
    for (final op in _operations.values) {
      op.quoteProgress?.cancel();
    }
    _operations.clear();
    _walletUses.clear();
    for (final launcher in [four, flap, genius]) {
      launcher.removeListener(_launchChanged);
    }
    for (final g in groups) {
      g.dispose();
    }
    transfers.dispose();
    four.dispose();
    flap.dispose();
    genius.dispose();
    log.dispose();
    super.dispose();
  }
}
