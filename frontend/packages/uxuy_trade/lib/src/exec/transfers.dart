import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../evm/abi.dart' show eventTopic;
import '../evm/evm.dart';
import '../wallet/wallet.dart';
import 'executor.dart';
import 'market.dart' show zeroAddress;

/// BNB (address null) or an ERC20 token.
class TransferAsset {
  const TransferAsset(this.address, this.symbol, this.decimals);
  static const bnb = TransferAsset(null, 'BNB', 18);
  final String? address;
  final String symbol;
  final int decimals;
  bool get native => address == null;
}

/// One distribution row, drawn once on "使用" and executed exactly as previewed (web DistributionAllocation).
class Allocation {
  Allocation({
    required this.recipient,
    required this.amount,
    this.sender,
    this.transit,
    this.percentageBps,
  });
  final String recipient;
  BigInt amount;
  final BigInt? percentageBps;

  /// Many-to-many: the paired sender. One-to-many rows use the single source.
  final TradeWallet? sender;

  /// 中转分发: a generated relay per recipient.
  final TradeWallet? transit;
}

enum TransferStatus {
  waiting,
  submitted,
  confirmed,
  failed,
  notIncluded,
  unknown,
  skipped,
}

/// One signed leg. A relay distribution has two (BNB) or three (token: gas, token, forward) legs.
class TransferLeg {
  TransferLeg({
    required this.row,
    required this.from,
    required this.recipient,
    required this.to,
    required this.data,
    required this.value,
    required this.amount,
    required this.gasLimit,
    this.token = false,
    this.capToBalance = false,
  });
  final int row;
  final TradeWallet from;
  final String recipient;
  final String to;
  Uint8List data;
  final BigInt value;
  BigInt amount;
  final int gasLimit;
  final bool token;

  /// Token relay forward: sends what the relay actually received (transfer-tax tokens).
  final bool capToBalance;
  TransferStatus status = TransferStatus.waiting;
  String? hash;
  String? raw;
  int? nonce;
}

class TransferRun {
  TransferRun({
    required this.label,
    required this.asset,
    required this.legs,
    required this.rows,
    required this.gasPrice,
    this.intervalMin = 0,
    this.intervalMax = 0,
  });
  final String label;
  final TransferAsset asset;
  final List<TransferLeg> legs;

  /// Display rows (recipient, amount); one per allocation.
  final List<Allocation> rows;
  final BigInt gasPrice;
  final num intervalMin;
  final num intervalMax;
  bool get bundle => intervalMin == 0 && intervalMax == 0;
  /// A background estimate is only fit for review. The freshly prepared
  /// transaction order, amounts and destinations must match that review.
  bool covers(TransferRun fresh) {
    if (asset.address != fresh.asset.address || legs.length != fresh.legs.length ||
        intervalMin != fresh.intervalMin || intervalMax != fresh.intervalMax) return false;
    for (var i = 0; i < legs.length; i++) {
      final a = legs[i], b = fresh.legs[i];
      if (a.row != b.row || a.from.address != b.from.address || a.to != b.to ||
          a.recipient != b.recipient || a.value != b.value || a.amount != b.amount ||
          a.token != b.token || a.capToBalance != b.capToBalance || !listEquals(a.data, b.data) ||
          BigInt.from(b.gasLimit) * fresh.gasPrice > BigInt.from(a.gasLimit) * gasPrice) {
        return false;
      }
    }
    return true;
  }

  BigInt get total => rows.fold(BigInt.zero, (a, r) => a + r.amount);

  late final _legsByRow = () {
    final grouped = List.generate(rows.length, (_) => <TransferLeg>[]);
    for (final leg in legs) grouped[leg.row].add(leg);
    return grouped;
  }();

  /// Row status: failed / not received / to verify / confirmed / waiting (web retry queue states).
  TransferStatus statusOf(int row) {
    final legs = _legsByRow[row];
    if (legs.isEmpty) return TransferStatus.skipped;
    for (final s in [
      TransferStatus.failed,
      TransferStatus.unknown,
      TransferStatus.notIncluded,
      TransferStatus.submitted,
    ]) {
      if (legs.any((l) => l.status == s)) return s;
    }
    return legs.every((l) => l.status == TransferStatus.confirmed)
        ? TransferStatus.confirmed
        : TransferStatus.waiting;
  }

  int count(TransferStatus s) =>
      [for (var i = 0; i < rows.length; i++) statusOf(i)]
          .where((x) => x == s)
          .length;
  bool get complete => legs.every(
    (l) =>
        l.status == TransferStatus.confirmed ||
        l.status == TransferStatus.skipped,
  );
  bool get hasUnknown => legs.any(
    (l) =>
        l.status == TransferStatus.unknown ||
        l.status == TransferStatus.submitted,
  );
  bool get retryable => !complete && !hasUnknown;
}

/// Web transferLanes: funding a relay and forwarding from it share a lane; unrelated wallets run independently.
List<List<TransferLeg>> transferLanes(List<TransferLeg> legs) {
  final parent = <String, String>{
    for (final l in legs)
      l.from.address.toLowerCase(): l.from.address.toLowerCase(),
  };
  String root(String k) {
    final p = parent[k]!;
    if (p == k) return k;
    final r = root(p);
    parent[k] = r;
    return r;
  }

  for (final l in legs) {
    final r = l.recipient.toLowerCase();
    if (parent.containsKey(r)) {
      parent[root(r)] = root(l.from.address.toLowerCase());
    }
  }
  final lanes = <String, List<TransferLeg>>{};
  for (final l in legs) {
    lanes.putIfAbsent(root(l.from.address.toLowerCase()), () => []).add(l);
  }
  return lanes.values.toList();
}

/// Web parseRecipients: split on whitespace / commas / semicolons, checksum, reject zero and (paired) duplicates.
List<String> parseRecipients(String text, {bool rejectDuplicates = false}) {
  final entries = text
      .split(RegExp(r'[\s,;，；]+'))
      .where((x) => x.isNotEmpty)
      .toList();
  if (entries.isEmpty) throw const FormatException('请输入接收地址');
  if (entries.any((a) => !isAddress(a))) {
    throw const FormatException('接收地址格式无效');
  }
  if (entries.any(
    (a) => BigInt.parse(a.substring(2), radix: 16) == BigInt.zero,
  )) {
    throw const FormatException('接收地址不能为零地址');
  }
  final out = <String>[];
  final seen = <String>{};
  for (final a in entries) {
    final c = checksumAddress(a);
    if (seen.add(c.toLowerCase())) {
      out.add(c);
    } else if (rejectDuplicates) {
      throw const FormatException('接收地址不能重复，请按顺序一一对应');
    }
  }
  return out;
}

/// Wallet tools (web wallet-tools/transfers): distribute one-to-many / many-to-many, optionally through relays,
/// and collect. Every send is a private bundle; a stop never withdraws what was sent; retries resubmit the
/// original signed transaction (same nonce, same amount), never a new payment.
class TransferEngine extends ChangeNotifier {
  TransferEngine(
    this.api,
    this.log, {
    Sleep? sleep,
    Random? random,
    this.requireReceivable,
    this.checkWorkspace,
    this.pollEvery = const Duration(seconds: 2),
  }) : _intervalOverride = sleep,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random.secure();

  final BackendClient api;
  final ExecutionLog log;
  final void Function(Iterable<String> addresses)? requireReceivable;
  final void Function()? checkWorkspace;
  final Duration pollEvery;
  final Sleep _sleep;
  final Sleep? _intervalOverride;
  final _intervalStops = <void Function()>{};
  final Random _random;

  bool running = false;
  bool _cancel = false;
  bool _disposed = false;
  TransferRun? current;
  final _retained = <TransferRun>{};
  final _queries = <TransferRun>{};

  bool querying(TransferRun run) => _queries.contains(run);

  /// Displaced tasks with transfers to reconcile. A queried task remains available until
  /// the user finishes it or continues its unfinished legs.
  Iterable<TransferRun> get retainedRuns =>
      _retained.toList(growable: false).reversed;

  Iterable<TransferRun> get unresolvedRuns sync* {
    final active = current;
    if (active != null && active.hasUnknown) yield active;
    yield* _retained.where((run) => run.hasUnknown);
  }

  static const _bundleLimit = 103;
  int _activeRequests = 0;
  final _requestWaiters = Queue<Completer<void>>();

  // A wallet waiting for its block window must not occupy an RPC slot. This
  // keeps independent lanes progressing even when earlier wallets keep retrying.
  Future<T> _limitedRequest<T>(Future<T> Function() request) async {
    if (_activeRequests == 12) {
      final turn = Completer<void>();
      _requestWaiters.add(turn);
      await turn.future;
    } else {
      _activeRequests++;
    }
    try {
      return await request();
    } finally {
      if (_requestWaiters.isEmpty) {
        _activeRequests--;
      } else {
        _requestWaiters.removeFirst().complete();
      }
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _log(String text, {LogLevel level = LogLevel.info}) =>
      log.add('工具 $text', level: level);

  void stop() {
    if (running) {
      _cancel = true;
      for (final cancel in _intervalStops.toList()) cancel();
    }
    _changed();
  }

  Future<void> _waitInterval(int milliseconds) async {
    if (milliseconds <= 0 || _cancel) return;
    final duration = Duration(milliseconds: milliseconds);
    final done = Completer<void>();
    Timer? timer;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _intervalStops.add(finish);
    try {
      if (_intervalOverride == null) {
        timer = Timer(duration, finish);
        await done.future;
      } else {
        await Future.any([_intervalOverride(duration), done.future]);
      }
    } finally {
      timer?.cancel();
      _intervalStops.remove(finish);
    }
  }

  /// "结束": forget the finished or stopped run. Not allowed while statuses are unknown.
  void finish([TransferRun? selected]) {
    final run = selected ?? current;
    if (run == null) return;
    if (running && identical(run, current)) throw StateError('请先停止');
    if (querying(run)) throw StateError('正在查询原转账');
    if (run.hasUnknown) throw StateError('有转账待核实，请先查询原转账');
    if (identical(current, run)) current = null;
    _retained.remove(run);
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<TransferAsset> asset(String? token) async {
    if (token == null) return TransferAsset.bnb;
    final address = token.trim();
    if (!isAddress(address) || address.toLowerCase() == zeroAddress) {
      throw const FormatException('请输入有效的代币地址');
    }
    final meta = await api.token(address);
    final d = meta.decimals ?? (throw StateError('代币精度读取失败'));
    return TransferAsset(checksumAddress(meta.address), meta.symbol, d);
  }

  BigInt _draw(BigInt lo, BigInt hi) => hi <= lo
      ? lo
      : lo +
            (hi - lo) *
                BigInt.from(_random.nextInt(1 << 30)) ~/
                BigInt.from(1 << 30);

  /// One-to-many: each recipient draws once in [min, max] (equal amounts when both are the same).
  List<Allocation> drawOneToMany(
    TradeWallet source,
    List<String> recipients,
    BigInt min,
    BigInt max, {
    Map<String, TradeWallet>? transits,
  }) {
    if (recipients.isEmpty || recipients.length > 10000) {
      throw const FormatException('请填写 1–10000 个接收地址');
    }
    if (min <= BigInt.zero || max < min) {
      throw const FormatException('每个地址的最小分发数量需大于 0，最小不大于最大');
    }
    _checkUnique([
      source.address,
      ...recipients,
      ...?transits?.values.map((t) => t.address),
    ]);
    return [
      for (final r in recipients)
        Allocation(
          recipient: r,
          amount: _draw(min, max),
          transit: transits?[r.toLowerCase()],
        ),
    ];
  }

  /// Many-to-many: sender i pays recipient i. [ratio] amounts are basis points of each sender's available
  /// balance (BNB keeps the transfer gas back); otherwise token units / wei. Drawn once.
  Future<List<Allocation>> drawPaired(
    List<TradeWallet> senders,
    List<String> recipients,
    TransferAsset asset, {
    required bool ratio,
    required BigInt min,
    required BigInt max,
    Map<String, TradeWallet>? transits,
  }) async {
    if (senders.length != recipients.length) {
      throw StateError(
        '多对多数量不一致：分发方 ${senders.length} 个，接收方 ${recipients.length} 个',
      );
    }
    if (min <= BigInt.zero ||
        max < min ||
        (ratio && max > BigInt.from(10000))) {
      throw const FormatException('分发数量需大于 0，最小不大于最大，比例不超过 100%');
    }
    _checkUnique([
      ...senders.map((s) => s.address),
      ...recipients,
      ...?transits?.values.map((t) => t.address),
    ]);
    final (states, gas) = await (
      _freshFunding([for (final s in senders) s.address], token: asset.address),
      api.gas(),
    ).wait;
    final keep =
        BigInt.from(21000) *
        gas.gasPrice *
        BigInt.from(transits == null ? 1 : 2);
    return [
      for (var i = 0; i < senders.length; i++)
        () {
          final st = states[i];
          final available = asset.native
              ? (st.native > keep ? st.native - keep : BigInt.zero)
              : (st.tokenBalance ?? BigInt.zero);
          final sample = _draw(min, max);
          final want = ratio
              ? available * sample ~/ BigInt.from(10000)
              : sample;
          return Allocation(
            recipient: recipients[i],
            sender: senders[i],
            amount: want < available ? want : available,
            percentageBps: ratio ? sample : null,
            transit: transits?[recipients[i].toLowerCase()],
          );
        }(),
    ];
  }

  void _checkUnique(List<String> addresses) {
    final lower = [for (final a in addresses) a.toLowerCase()];
    if (lower.toSet().length != lower.length) {
      throw StateError('分发方、接收方及中转地址不能重复');
    }
  }

  /// Preserve input order while limiting pressure on the read RPC.
  Future<List<T>> _readRows<T>(int count, Future<T> Function(int) read, {void Function()? checkPreview}) async {
    final out = <T>[];
    for (var start = 0; start < count; start += 12) {
      checkPreview?.call();
      out.addAll(
        await Future.wait([
          for (var i = start; i < min(start + 12, count); i++) read(i),
        ]),
      );
    }
    return out;
  }

  Future<List<WalletState>> _freshFunding(
    List<String> owners, {
    String? token,
    void Function()? checkPreview,
  }) async {
    final List<WalletState> states;
    if (checkPreview == null) {
      states = await api.transferWalletStates(owners, token: token, refresh: true);
    } else {
      final found = <String, WalletState>{};
      for (var i = 0; i < owners.length; i += 100) {
        checkPreview();
        final batch = owners.skip(i).take(100).toList();
        for (final state in await api.transferPreviewStates(batch, token: token)) {
          found[state.wallet.toLowerCase()] = state;
        }
      }
      states = [for (final owner in owners) found[owner.toLowerCase()] ?? (throw StateError('转账预估缺少钱包余额'))];
    }
    for (var i = 0; i < states.length; i += 128) {
      checkPreview?.call();
      final rows = states.sublist(i, min(i + 128, states.length));
      final latest = await api.rpc([
        for (final state in rows)
          ('eth_getTransactionCount', [state.wallet, 'latest']),
      ]);
      for (var j = 0; j < rows.length; j++) {
        final raw = latest[j];
        if (raw is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(raw))
          throw StateError('无法核实钱包交易序号');
        if (int.parse(raw.substring(2), radix: 16) != rows[j].nonce)
          throw StateError('${rows[j].wallet} 有待确认交易或节点尚未同步，请稍后重试');
      }
    }
    return states;
  }

  Future<Map<String, String>> _codes(Iterable<String> addresses, {void Function()? checkPreview}) async {
    final list = addresses.map((a) => a.toLowerCase()).toSet().toList();
    if (list.isEmpty) return const {};
    final out = <String, String>{};
    for (var i = 0; i < list.length; i += 50) {
      checkPreview?.call();
      final chunk = list.sublist(i, min(i + 50, list.length));
      final res = await api.rpc([
        for (final a in chunk) ('eth_getCode', [a, 'latest']),
      ]);
      for (var j = 0; j < chunk.length; j++) {
        out[chunk[j]] = '${res[j]}';
      }
    }
    return out;
  }

  Future<int> _gas(
    String from,
    String to,
    BigInt value,
    Uint8List data, {
    String? code,
  }) async {
    if (data.isEmpty && (code == null || code == '0x')) return 21000;
    final r = await api.rpc([
      (
        'eth_estimateGas',
        [
          {
            'from': from,
            'to': to,
            'value': '0x${value.toRadixString(16)}',
            'data': bytesToHex(data),
            'gasPrice': '0x0',
          },
        ],
      ),
    ]);
    final used = int.parse('${r.single}'.substring(2), radix: 16);
    return (used * 120 + 99) ~/ 100;
  }

  /// Build the legs, measure gas and check that every sender can pay its amounts and all network fees.
  Future<TransferRun> prepareDistribution(
    List<Allocation> allocation,
    TransferAsset asset, {
    required TradeWallet source,
    num intervalMin = 0,
    num intervalMax = 0,
    Set<String> unbacked = const {},
    void Function()? checkPreview,
  }) async {
    final rows = [
      for (final row in allocation)
        Allocation(
          recipient: row.recipient,
          amount: row.amount,
          sender: row.sender,
          transit: row.transit,
          percentageBps: row.percentageBps,
        ),
    ];
    if (rows.isEmpty) throw StateError('请先使用数量区间生成分发明细');
    requireReceivable?.call([
      for (final row in rows) ...[row.recipient, ?row.transit?.address],
    ]);
    final blocked = rows
        .where((r) => unbacked.contains(r.recipient.toLowerCase()))
        .length;
    if (blocked > 0) {
      throw StateError(
        requireReceivable == null
            ? '有 $blocked 个接收地址是新生成的钱包，尚未复制保存私钥，不能接收资金'
            : '有 $blocked 个收款地址的私钥尚未写入本地备份目录，不能接收资金',
      );
    }
    if (rows.any((r) => r.transit != null && !r.transit!.canReceiveFunds)) {
      throw StateError(
        requireReceivable == null
            ? '中转地址会接收资金，请先复制保存本次中转私钥'
            : '中转地址会接收资金，请先将中转私钥写入本地备份目录',
      );
    }
    if (!intervalMin.isFinite ||
        !intervalMax.isFinite ||
        intervalMin < 0 ||
        intervalMax < intervalMin ||
        intervalMax > 86400 ||
        intervalMin != double.parse(intervalMin.toStringAsFixed(3)) ||
        intervalMax != double.parse(intervalMax.toStringAsFixed(3))) {
      throw const FormatException('间隔秒数无效');
    }
    final senders = {
      for (final r in rows)
        (r.sender ?? source).address.toLowerCase(): r.sender ?? source,
    };
    final (gas, codes, fundingStates) = await (
      api.gas(),
      _codes([
        if (asset.native) ...rows.map((r) => r.recipient),
        ...rows.where((r) => r.transit != null).map((r) => r.transit!.address),
      ], checkPreview: checkPreview),
      _freshFunding([
        for (final s in senders.values) s.address,
      ], token: asset.address, checkPreview: checkPreview),
    ).wait;
    final states = {
      for (final st in fundingStates) st.wallet.toLowerCase(): st,
    };
    final rowLegs = await _readRows(rows.length, (i) async {
      final legs = <TransferLeg>[];
      final r = rows[i];
      if (r.amount <= BigInt.zero) return legs;
      final from = r.sender ?? source;
      bool cap(int gasUnits) {
        if (r.sender == null) return true;
        final state = states[from.address.toLowerCase()]!;
        final fees = BigInt.from(gasUnits) * gas.gasPrice;
        var available = state.native < fees
            ? BigInt.zero
            : asset.native
            ? state.native - fees
            : (state.tokenBalance ?? BigInt.zero);
        if (r.percentageBps != null)
          available = available * r.percentageBps! ~/ BigInt.from(10000);
        if (r.amount > available) r.amount = available;
        if (r.amount == BigInt.zero && checkPreview == null) _log('分发来源 ${i + 1} 已跳过：余额或网络费不足');
        return r.amount > BigInt.zero;
      }

      if (!cap(0)) return legs;
      if (r.transit != null &&
          codes[r.transit!.address.toLowerCase()] != '0x') {
        throw StateError('中转地址必须是普通钱包');
      }
      if (asset.native) {
        final forwardGas = await _gas(
          from.address,
          r.recipient,
          r.amount,
          Uint8List(0),
          code: codes[r.recipient.toLowerCase()],
        );
        if (!cap(forwardGas + (r.transit == null ? 0 : 21000))) return legs;
        if (r.transit == null) {
          legs.add(_native(i, from, r.recipient, r.amount, forwardGas));
        } else {
          legs.add(
            _native(
              i,
              from,
              r.transit!.address,
              r.amount + BigInt.from(forwardGas) * gas.gasPrice,
              21000,
            ),
          );
          legs.add(_native(i, r.transit!, r.recipient, r.amount, forwardGas));
        }
      } else {
        final forwardGas = await _gas(
          from.address,
          asset.address!,
          BigInt.zero,
          erc20Transfer(r.recipient, r.amount),
        );
        if (r.transit == null) {
          if (!cap(forwardGas)) return legs;
          legs.add(_token(i, from, r.recipient, asset, r.amount, forwardGas));
        } else {
          // A fresh relay cannot estimate before funding: measure from the sender, keep a forwarding floor.
          final fundGas = await _gas(
            from.address,
            asset.address!,
            BigInt.zero,
            erc20Transfer(r.transit!.address, r.amount),
          );
          final relayGas = max(forwardGas, 120000);
          if (!cap(21000 + fundGas + relayGas)) return legs;
          legs.add(
            _native(
              i,
              from,
              r.transit!.address,
              BigInt.from(relayGas) * gas.gasPrice,
              21000,
            ),
          );
          legs.add(
            _token(i, from, r.transit!.address, asset, r.amount, fundGas),
          );
          legs.add(
            _token(
              i,
              r.transit!,
              r.recipient,
              asset,
              r.amount,
              relayGas,
              capToBalance: true,
            ),
          );
        }
      }
      return legs;
    }, checkPreview: checkPreview);
    // A stable partition keeps sender order and funds every relay before its token forward.
    final legs = [
      for (final forward in [false, true])
        for (final row in rowLegs)
          for (final l in row)
            if (l.capToBalance == forward) l,
    ];
    if (legs.isEmpty) throw StateError('没有可分发的数量');

    final cost = <String, (BigInt, BigInt)>{};
    for (final l in legs) {
      final k = l.from.address.toLowerCase();
      if (!senders.containsKey(k)) continue;
      final c = cost[k] ?? (BigInt.zero, BigInt.zero);
      cost[k] = (
        c.$1 + l.value + BigInt.from(l.gasLimit) * gas.gasPrice,
        c.$2 + (l.token ? l.amount : BigInt.zero),
      );
    }
    var n = 0;
    for (final e in senders.entries) {
      n++;
      final st = states[e.key]!;
      final c = cost[e.key] ?? (BigInt.zero, BigInt.zero);
      if (st.native < c.$1) {
        throw StateError(
          '分发方 $n（${e.value.address}）BNB 不足（含中转与全部网络费），请调整明细后重试',
        );
      }
      if (!asset.native && (st.tokenBalance ?? BigInt.zero) < c.$2) {
        throw StateError('分发方 $n（${e.value.address}）分发总量超过代币余额，请调整明细后重试');
      }
    }
    final label = rows.any((r) => r.sender != null) ? '多对多分发' : '分发';
    return TransferRun(
      label: label,
      asset: asset,
      legs: legs,
      rows: rows,
      gasPrice: gas.gasPrice,
      intervalMin: intervalMin,
      intervalMax: intervalMax,
    );
  }

  /// Collect everything (BNB minus gas, or the whole token balance) into one address, in bundles.
  Future<TransferRun> prepareCollection(
    List<TradeWallet> sources,
    String recipient,
    TransferAsset asset, {
    void Function()? checkPreview,
  }) async {
    if (!isAddress(recipient)) throw const FormatException('请输入有效的归集地址');
    requireReceivable?.call([recipient]);
    if (sources.any(
      (s) => s.address.toLowerCase() == recipient.toLowerCase(),
    )) {
      throw StateError('归集方不能包含接收方');
    }
    final to = checksumAddress(recipient);
    if (to.toLowerCase() == zeroAddress ||
        sources.map((w) => w.address.toLowerCase()).toSet().length !=
            sources.length) {
      throw StateError('归集地址不能为零，来源钱包不能重复');
    }
    final (states, gas, codes) = await (
      _freshFunding([for (final s in sources) s.address], token: asset.address, checkPreview: checkPreview),
      api.gas(),
      _codes([if (asset.native) to], checkPreview: checkPreview),
    ).wait;
    final code = codes[to.toLowerCase()];
    final entries = await _readRows<(BigInt, int)?>(sources.length, (i) async {
      final s = sources[i];
      final st = states[i];
      if (asset.native) {
        var g = await _gas(s.address, to, BigInt.one, Uint8List(0), code: code);
        final amount = st.native - BigInt.from(g) * gas.gasPrice;
        if (amount <= BigInt.zero) return null;
        if (code != null && code != '0x') {
          var converged = false;
          for (var i = 0; i < 5; i++) {
            final candidate = st.native - BigInt.from(g) * gas.gasPrice;
            if (candidate <= BigInt.zero) return null;
            final next = await _gas(
              s.address,
              to,
              candidate,
              Uint8List(0),
              code: code,
            );
            if (next <= g) {
              converged = true;
              break;
            }
            g = next;
          }
          if (!converged) throw StateError('归集网络费估算不稳定，请检查接收合约后重试');
        }
        final send = st.native - BigInt.from(g) * gas.gasPrice;
        if (send <= BigInt.zero) return null;
        return (send, g);
      } else {
        final bal = st.tokenBalance ?? BigInt.zero;
        if (bal == BigInt.zero) return null;
        final g = await _gas(
          s.address,
          asset.address!,
          BigInt.zero,
          erc20Transfer(to, bal),
        );
        if (st.native < BigInt.from(g) * gas.gasPrice) {
          throw StateError('${s.address} 的 BNB 不足以支付归集网络费');
        }
        return (bal, g);
      }
    }, checkPreview: checkPreview);
    final rows = <Allocation>[];
    final legs = <TransferLeg>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry == null) continue;
      final (amount, gasLimit) = entry;
      final index = rows.length, sender = sources[i];
      rows.add(Allocation(recipient: to, amount: amount, sender: sender));
      legs.add(
        asset.native
            ? _native(index, sender, to, amount, gasLimit)
            : _token(index, sender, to, asset, amount, gasLimit),
      );
    }
    if (legs.isEmpty) throw StateError('没有可转出的余额');
    return TransferRun(
      label: '归集',
      asset: asset,
      legs: legs,
      rows: rows,
      gasPrice: gas.gasPrice,
    );
  }

  TransferLeg _native(
    int row,
    TradeWallet from,
    String to,
    BigInt value,
    int gas,
  ) => TransferLeg(
    row: row,
    from: from,
    recipient: to,
    to: checksumAddress(to),
    data: Uint8List(0),
    value: value,
    amount: value,
    gasLimit: gas,
  );

  TransferLeg _token(
    int row,
    TradeWallet from,
    String to,
    TransferAsset a,
    BigInt amount,
    int gas, {
    bool capToBalance = false,
  }) => TransferLeg(
    row: row,
    from: from,
    recipient: to,
    to: a.address!,
    data: erc20Transfer(to, amount),
    value: BigInt.zero,
    amount: amount,
    gasLimit: gas,
    token: true,
    capToBalance: capToBalance,
  );

  /// Execute (or continue) a run. Unknown statuses must be queried first; not-included legs are resubmitted
  /// with their original signature; reverted legs are never repeated.
  Future<void> execute(TransferRun run) async {
    checkWorkspace?.call();
    if (running) throw StateError('正在执行');
    if (querying(run)) throw StateError('正在查询原转账');
    if (run.hasUnknown) throw StateError('有转账待核实，请先查询原转账');
    if (run.legs.any((l) => l.status == TransferStatus.failed)) {
      throw StateError('原转账有失败记录，请结束后重新读取余额');
    }
    final previous = current;
    if (previous != null &&
        !identical(previous, run) &&
        (previous.hasUnknown || querying(previous))) {
      _retained.add(previous);
    }
    _retained.remove(run);
    current = run;
    running = true;
    _cancel = false;
    _changed();
    try {
      final nonces = <String, int>{};
      final wallets = {
        for (final l in run.legs)
          if (l.raw == null) l.from.address.toLowerCase(): l.from.address,
      };
      if (wallets.isNotEmpty) {
        final signedOwners = {
          for (final leg in run.legs)
            if (leg.raw != null) leg.from.address.toLowerCase(),
        };
        // Do not invalidate a pending original signature while preparing later legs.
        for (final refresh in [true, false]) {
          final batch = wallets.entries
              .where((row) => signedOwners.contains(row.key) != refresh)
              .map((row) => row.value)
              .toList();
          if (batch.isEmpty) continue;
          for (final state
              in await (refresh
                  ? _freshFunding(batch)
                  : api.transferWalletStates(batch))) {
            nonces[state.wallet.toLowerCase()] = state.nonce;
          }
        }
        // A retry keeps its original signature and reserves its nonce even before inclusion.
        for (final leg in run.legs) {
          final signedNonce = leg.nonce;
          if (signedNonce == null) continue;
          final sender = leg.from.address.toLowerCase();
          final next = nonces[sender];
          if (next != null && next <= signedNonce) {
            nonces[sender] = signedNonce + 1;
          }
        }
      }
      if (run.bundle) {
        final header = (await api.rpc([
          ('eth_getBlockByNumber', ['latest', false]),
        ])).single;
        final gasLimit = header is Map && header['gasLimit'] is String
            ? int.tryParse(
                (header['gasLimit'] as String).replaceFirst('0x', ''),
                radix: 16,
              )
            : null;
        if (gasLimit == null || gasLimit <= 0)
          throw StateError('无法核对 BSC 区块 Gas 容量');
        if (run.legs.any((leg) => leg.gasLimit > gasLimit))
          throw StateError('单笔转账 Gas 超过区块上限');
        final lanes = run.label == '多对多分发'
            ? transferLanes(run.legs)
            : [run.legs];
        await Future.wait([
          for (final lane in lanes) _bundles(run, nonces, lane, gasLimit),
        ]);
      } else {
        final lanes = transferLanes(
          run.legs.where((l) => l.status != TransferStatus.confirmed).toList(),
        );
        var delay = 0;
        await Future.wait([
          for (var i = 0; i < lanes.length; i++)
            () async {
              final wait = delay;
              delay += randomGroupInterval(
                _random,
                run.intervalMin,
                run.intervalMax,
              ).inMilliseconds;
              if (wait > 0) await _waitInterval(wait);
              await _lane(run, lanes[i], nonces, i + 1);
            }(),
        ]);
      }
    } finally {
      running = false;
      final ok = run.count(TransferStatus.confirmed);
      _log(
        '${run.label}：已确认 $ok/${run.rows.length}'
        '${run.count(TransferStatus.notIncluded) > 0 ? '，未接收 ${run.count(TransferStatus.notIncluded)}' : ''}'
        '${run.count(TransferStatus.failed) > 0 ? '，失败 ${run.count(TransferStatus.failed)}' : ''}'
        '${run.hasUnknown ? '，待核实 ${run.count(TransferStatus.unknown)}' : ''}',
        level: run.complete ? LogLevel.success : LogLevel.error,
      );
      if (_cancel) _log('已停止：未发送的转账不再发送，已发送的保留查询', level: LogLevel.error);
      _changed();
    }
  }

  void _sign(TransferLeg l, Map<String, int> nonces, BigInt gasPrice) {
    if (l.raw != null) return;
    final k = l.from.address.toLowerCase();
    final nonce = nonces[k] ?? (throw StateError('交易序号读取失败'));
    final tx = api.sign(
      l.from,
      LegacyTx(
        nonce: nonce,
        gasPrice: gasPrice,
        gasLimit: l.gasLimit,
        to: l.to,
        value: l.value,
        data: l.data,
      ),
    );
    nonces[k] = nonce + 1;
    l
      ..nonce = nonce
      ..raw = tx.raw
      ..hash = tx.hash;
  }

  /// Token relay forwards send what the relay actually holds (≤ planned amount).
  Future<void> _capForwards(TransferRun run, List<TransferLeg> legs) async {
    final caps = [
      for (final l in legs)
        if (l.capToBalance && l.raw == null) l,
    ];
    if (caps.isEmpty) return;
    final st = {
      for (final s in await api.transferWalletStates(
        [for (final l in caps) l.from.address],
        token: run.asset.address,
        refresh: true,
      ))
        s.wallet.toLowerCase(): s,
    };
    for (final l in caps) {
      final have =
          st[l.from.address.toLowerCase()]?.tokenBalance ?? BigInt.zero;
      if (have <= BigInt.zero) {
        throw StateError('中转地址 ${l.from.address} 未收到可转出的代币，请核对原转账');
      }
      if (have < l.amount) {
        l.amount = have;
        l.data = erc20Transfer(l.recipient, have);
      }
    }
  }

  Future<void> _bundles(
    TransferRun run,
    Map<String, int> nonces,
    List<TransferLeg> lane,
    int blockGas,
  ) async {
    var pending = lane
        .where((l) => l.status != TransferStatus.confirmed)
        .toList();
    while (pending.isNotEmpty && !_cancel) {
      final batch = <TransferLeg>[];
      var gas = 0;
      for (final l in pending) {
        if (batch.isNotEmpty &&
            (batch.length >= _bundleLimit ||
                gas + l.gasLimit > blockGas ||
                (l.capToBalance && batch.any((b) => !b.capToBalance)))) {
          break;
        }
        batch.add(l);
        gas += l.gasLimit;
      }
      await _limitedRequest(() => _capForwards(run, batch));
      if (_cancel) return;
      for (final l in batch) {
        _sign(l, nonces, run.gasPrice);
      }
      final ok = await _send(batch, distribution: run.label != '归集');
      _log(
        '${run.label} ${run.legs.indexOf(batch.first) + 1}–${run.legs.indexOf(batch.last) + 1}/${run.legs.length}',
      );
      if (!ok) return;
      pending = pending.skip(batch.length).toList();
    }
  }

  Future<void> _lane(
    TransferRun run,
    List<TransferLeg> lane,
    Map<String, int> nonces,
    int index,
  ) async {
    for (var i = 0; i < lane.length; i++) {
      final l = lane[i];
      if (l.status == TransferStatus.confirmed) continue;
      if (_cancel) return;
      if (i > 0 && l.raw == null) {
        final wait = randomGroupInterval(
          _random,
          run.intervalMin,
          run.intervalMax,
        ).inMilliseconds;
        if (wait > 0) await _waitInterval(wait);
        if (_cancel) return;
      }
      await _limitedRequest(() => _capForwards(run, [l]));
      if (_cancel) return;
      _sign(l, nonces, run.gasPrice);
      if (!await _send([l], distribution: true)) {
        _log(
          '队列 $index ${lane.first.from.address} 未完成，其他独立钱包继续',
          level: LogLevel.error,
        );
        return;
      }
    }
  }

  /// A definitely expired distribution retries its original bytes until the user stops.
  Future<bool> _send(
    List<TransferLeg> legs, {
    required bool distribution,
  }) async {
    for (var attempt = 0; !_cancel; attempt++) {
      final head = await _limitedRequest(api.gas);
      if (_cancel) return false;
      try {
        final sent = await _limitedRequest(() async {
          if (_cancel) return false;
          for (final l in legs) {
            l.status = TransferStatus.submitted;
          }
          _changed();
          await api.groupBundle(
            [for (final l in legs) l.raw!],
            head.blockNumber + BackendClient.groupWindowBlocks,
            active: () => !_disposed && !_cancel,
          );
          return true;
        });
        if (!sent) return false;
      } catch (e) {
        if (e is BackendException && e.notSubmitted) {
          for (final l in legs) {
            l.status = TransferStatus.notIncluded;
          }
          _log('提交未成功：${e.message}', level: LogLevel.error);
          _changed();
          return false;
        }
        _log('提交结果不明，正在按原哈希核对');
      }
      final statuses = await _pollOriginal(legs);
      for (var i = 0; i < legs.length; i++) {
        legs[i].status = switch (statuses[i]) {
          'confirmed' => TransferStatus.confirmed,
          'reverted' => TransferStatus.failed,
          'not_included' ||
          'rejected' ||
          'not_submitted' => TransferStatus.notIncluded,
          _ => TransferStatus.unknown,
        };
      }
      _changed();
      if (legs.every((l) => l.status == TransferStatus.confirmed)) return true;
      if (legs.any(
        (l) =>
            l.status == TransferStatus.failed ||
            l.status == TransferStatus.unknown,
      )) {
        return false;
      }
      if (_cancel ||
          legs.any((l) => l.status == TransferStatus.confirmed) ||
          !statuses.every((status) => status == 'not_included') ||
          (!distribution && attempt == 2))
        return false;
      _log('转账未上链，重新提交原交易（第 ${attempt + 2} 次）');
    }
    return false;
  }

  static final _transferTopic = bytesToHex(
    eventTopic('Transfer(address,address,uint256)'),
  );

  Future<String> _deliveryStatus(TransferLeg leg, TxRecord status) async {
    if (status.status != 'confirmed' || !leg.token) return status.status;
    final hash = leg.hash!;
    final record =
        status.receipt ??
        (await api.rpc([
          ('eth_getTransactionReceipt', <Object?>[hash]),
        ])).single;
    if (record is! Map ||
        record['transactionHash']?.toString().toLowerCase() !=
            hash.toLowerCase() ||
        record['status'] != '0x1' ||
        record['logs'] is! List || hasConflictingReceiptLogs(record))
      return 'delivery_unverified';
    final source =
        '0x${leg.from.address.substring(2).toLowerCase().padLeft(64, '0')}';
    final destination =
        '0x${leg.recipient.substring(2).toLowerCase().padLeft(64, '0')}';
    for (final event in record['logs'] as List) {
      if (event is! Map ||
          event['removed'] == true ||
          event['address']?.toString().toLowerCase() != leg.to.toLowerCase())
        continue;
      final topics = event['topics'];
      final data = event['data'];
      if (topics is List &&
          topics.length == 3 &&
          '${topics[0]}'.toLowerCase() == _transferTopic &&
          '${topics[1]}'.toLowerCase() == source &&
          '${topics[2]}'.toLowerCase() == destination &&
          data is String &&
          RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(data) &&
          BigInt.parse(data.substring(2), radix: 16) > BigInt.zero)
        return 'confirmed';
    }
    return 'delivery_unverified';
  }

  Future<List<String>> _pollOriginal(List<TransferLeg> legs) async {
    final statuses = List.filled(legs.length, 'unknown');
    for (var i = 0; i < 60; i++) {
      final pending = [
        for (var j = 0; j < legs.length; j++)
          if (statuses[j] == 'unknown') j,
      ];
      await _readRows(pending.length, (k) async {
        final j = pending[k];
        try {
          await _limitedRequest(() async {
            final r = await api.status(legs[j].hash!);
            if (r.finished) statuses[j] = await _deliveryStatus(legs[j], r);
          });
        } on BackendException {
          // Only a definitive receipt or terminal tracker result resolves a send.
        } on TimeoutException {
          // Retry the original hash.
        }
      });
      if (!statuses.contains('unknown')) break;
      if (i < 59) await _sleep(pollEvery);
    }
    return statuses;
  }

  /// "查询原转账": settle unknown legs from the backend's records; never sends.
  Future<void> query([TransferRun? selected]) async {
    final run = selected ?? current;
    if (run == null || !run.hasUnknown) return;
    final isCurrent = identical(run, current);
    if ((isCurrent && running) || (!isCurrent && !_retained.contains(run))) {
      return;
    }
    if (!_queries.add(run)) return;
    _changed();
    try {
      final pending = run.legs
          .where(
            (leg) =>
                leg.status == TransferStatus.unknown ||
                leg.status == TransferStatus.submitted,
          )
          .toList();
      Object? readError;
      await _readRows(pending.length, (i) async {
        final leg = pending[i];
        try {
          final receipt = await api.reconcileStatus(leg.hash!);
          if (!receipt.finished) return;
          leg.status = switch (await _deliveryStatus(leg, receipt)) {
            'confirmed' => TransferStatus.confirmed,
            'reverted' => TransferStatus.failed,
            'not_included' ||
            'rejected' ||
            'not_submitted' => TransferStatus.notIncluded,
            _ => TransferStatus.unknown,
          };
        } catch (e) {
          readError ??= e;
        }
      });
      if (readError case final Object error) throw error;
      _log(
        run.hasUnknown ? '仍有转账待核实，请稍后继续查询' : '原转账已核清',
        level: run.hasUnknown ? LogLevel.error : LogLevel.success,
      );
    } finally {
      _queries.remove(run);
      _changed();
    }
  }
}
