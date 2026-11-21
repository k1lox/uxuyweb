import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../crypto/keccak.dart';
import '../crypto/secp256k1.dart' show toBytes32, bytesToBigInt;
import '../evm/abi.dart';
import '../evm/evm.dart';
import '../wallet/wallet.dart';
import 'executor.dart';
import 'flap_vault.dart';
import 'flap_vault_adapters.dart';
import 'market.dart';
import 'preview_deadline.dart';

part 'flap_launch_buys.dart';
part 'launch_funding.dart';

/// Launchpad bundles use the same priority premium and ceiling as BotAI.
BigInt launchBundleGasPrice(BigInt suggested) {
  final price = suggested + BigInt.from(500000000);
  if (suggested.isNegative || price > BigInt.from(100000000000)) {
    throw StateError('发币捆绑 Gas 单价无效或超过 100 Gwei');
  }
  return price;
}

Future<GasInfo> launchBundleGas(BackendClient api) async {
  final head = await api.gas();
  return GasInfo(launchBundleGasPrice(head.gasPrice), head.blockNumber);
}

/// One buyer of a launch bundle: wallet and its payment (wei, or quote units when paying with the pool token).
class LaunchBuyer {
  const LaunchBuyer(this.wallet, this.amount);
  final TradeWallet wallet;
  final BigInt amount;
}

/// One transaction of a launch bundle before signing.
class LaunchTx {
  LaunchTx(
    this.label,
    this.from,
    this.to,
    this.data,
    this.value,
    this.gasLimit, {
    this.kind = 'buy',
    this.purchasedToken,
    this.creationFee,
    this.alphaToken,
    this.protocolCheck,
    this.minimumDelivery,
    this.validUntil,
  });
  final String label;
  final TradeWallet from;

  /// Null deploys a contract.
  final String? to;
  final Uint8List data;
  final BigInt value;
  int gasLimit;
  final String kind;
  final String? purchasedToken;
  final BigInt? creationFee;
  final String? alphaToken;
  final String? Function(Map receipt)? protocolCheck;
  final BigInt? minimumDelivery;
  final int? validUntil;
  String? protocolError;
  Map<String, dynamic>? receipt;
  BigInt? simulatedDelivery;
  int? simulatedGasUsed;
  BigInt? get actualNetworkFee {
    final used = BigInt.tryParse('${receipt?['gasUsed']}');
    final price = BigInt.tryParse('${receipt?['effectiveGasPrice']}');
    return used == null || price == null ? null : used * price;
  }

  BigInt? get delivered {
    if (receipt == null || purchasedToken == null) return null;
    return launchReceiptDelivery(receipt!, purchasedToken!, from.address);
  }

  String? hash;
  String status = 'waiting';
}

/// A pre-purchase inside the official creation is possible before token discovery.
void validateLaunchPurchases(
  LaunchBuyer dev,
  List<LaunchBuyer> internal,
  List<LaunchBuyer> external, {
  required bool migrate,
}) {
  if (dev.amount < BigInt.zero) throw const FormatException('Dev 首买金额不能为负数');
  if (!migrate && external.isNotEmpty)
    throw const FormatException('内盘模式不能包含外盘买家');
  if (migrate && internal.isEmpty && dev.amount == BigInt.zero)
    throw const FormatException('内外盘模式至少需要一位内盘买家');
  final addresses = {dev.wallet.address.toLowerCase()};
  for (final buyer in [...internal, ...external]) {
    if (buyer.amount <= BigInt.zero)
      throw const FormatException('每个买家的金额必须大于零');
    if (!addresses.add(buyer.wallet.address.toLowerCase()))
      throw const FormatException('Dev、内盘和外盘钱包之间不能重复');
  }
}

BigInt launchReceiptDelivery(Map receipt, String token, String recipient) =>
    receiptTokenDelta(receipt, token, recipient);

final _alphaPromoted = bytesToHex(
  keccak256('AlphaPromoted(address,address,uint256)'.codeUnits),
);

bool launchAlphaPaid(Map receipt, LaunchTx tx) {
  final token = tx.alphaToken;
  final logs = receipt['logs'];
  if (token == null || logs is! List || tx.value <= BigInt.zero ||
      hasConflictingReceiptLogs(receipt)) return false;
  String topic(String a) =>
      '0x${a.substring(2).toLowerCase().padLeft(64, '0')}';
  return logs.whereType<Map>().any((row) {
    final topics = row['topics'];
    return '${row['address']}'.toLowerCase() == tx.to?.toLowerCase() &&
        topics is List &&
        topics.length == 3 &&
        '${topics[0]}'.toLowerCase() == _alphaPromoted &&
        '${topics[1]}'.toLowerCase() == topic(token) &&
        '${topics[2]}'.toLowerCase() == topic(tx.from.address) &&
        '${row['data']}'.toLowerCase() ==
            '0x${tx.value.toRadixString(16).padLeft(64, '0')}';
  });
}

const launchBundleTransactionLimit = 300;
const _fourFlapBundleLimit = 103;

/// The next transaction must fit in the gas left after previous actual usage.
void checkLaunchBlockCapacity(List<LaunchTx> txs, BigInt blockGasLimit) {
  if (blockGasLimit <= BigInt.zero) throw StateError('无法读取单区块 Gas 容量');
  var consumed = BigInt.zero;
  for (final tx in txs) {
    final used = tx.simulatedGasUsed;
    if (used == null || used <= 0 || used > tx.gasLimit) {
      throw StateError('${tx.label} 的模拟 Gas 无效，请重新准备');
    }
    if (consumed + BigInt.from(tx.gasLimit) > blockGasLimit) {
      throw StateError('同块交易超过当前区块 Gas 容量，请减少购买地址');
    }
    consumed += BigInt.from(used);
  }
}

enum LaunchState { idle, preparing, pending, launched, failed }

bool sameTradeMarket(Market a, Market b) =>
    a.address.toLowerCase() == b.address.toLowerCase() &&
    a.platform == b.platform &&
    a.buyTaxBps == b.buyTaxBps &&
    a.sellTaxBps == b.sellTaxBps &&
    a.venue == b.venue &&
    a.external == b.external &&
    a.quote.toLowerCase() == b.quote.toLowerCase() &&
    a.pool?.toLowerCase() == b.pool?.toLowerCase() &&
    a.geniusPhase == b.geniusPhase &&
    a.innerTarget?.toLowerCase() == b.innerTarget?.toLowerCase() &&
    a.nativeToQuoteSwapEnabled == b.nativeToQuoteSwapEnabled;

/// What a confirmed launch leaves behind for "准备清仓".
class LaunchSession {
  LaunchSession({
    required this.platform,
    required this.token,
    required this.symbol,
    required this.dev,
    required this.wallets,
    this.poolToken = zeroAddress,
    BigInt? tip,
    BigInt? reserved,
  }) : tip = tip ?? BigInt.zero,
       reserved = reserved ?? BigInt.zero;
  final String platform;
  final String token;
  final String symbol;
  final TradeWallet dev;
  final List<TradeWallet> wallets;
  final String poolToken;
  final _laterWallets = <String, TradeWallet>{};

  List<TradeWallet> get liquidationWallets => {
    for (final w in wallets) w.address.toLowerCase(): w,
    ..._laterWallets,
  }.values.toList();

  final BigInt tip;
  final BigInt reserved;
}

/// Shared launch runner: sign locally, one private bundle, receipts decide, never resend; then liquidation.
abstract class Launcher extends ChangeNotifier {
  Launcher(
    this.api,
    this.log, {
    Sleep? sleep,
    this.pollEvery = const Duration(seconds: 2),
    this.label = '发射',
    int transactionLimit = launchBundleTransactionLimit,
  }) : _transactionLimit = transactionLimit,
       _sleep = sleep ?? Future<void>.delayed;

  final BackendClient api;
  final ExecutionLog log;
  final Duration pollEvery;
  final String label;
  final int _transactionLimit;
  final Sleep _sleep;
  void Function()? checkWorkspace;
  Future<bool> Function(List<LaunchTx>, BigInt, LaunchSession)? confirmCosts;
  Future<bool> Function(
    String token,
    String spender,
    List<LaunchBuyer> buyers,
    BigInt networkCeiling,
  )?
  confirmApproval;
  Future<void> waitForNextPoll() => _sleep(pollEvery);

  LaunchState state = LaunchState.idle;
  String stage = '';
  String? error;
  LaunchSession? session;
  LaunchSession? _lastClearedSession;
  bool _receivePoolToken = false;
  bool get receivePoolToken => _receivePoolToken;

  void selectLiquidationOutput(bool usePoolToken) {
    if (busy || pendingLiquidation) throw StateError('清仓正在处理，请先查询原交易');
    if (usePoolToken && (session == null || session!.poolToken.toLowerCase() == zeroAddress)) {
      throw StateError('本轮使用 BNB 底池');
    }
    if (_receivePoolToken == usePoolToken) return;
    _receivePoolToken = usePoolToken;
    invalidateLiquidationPreview();
    changed();
  }

  void recordTradeParticipant(String token, TradeWallet wallet) {
    final s = session ?? _lastClearedSession;
    if (s == null || s.token.toLowerCase() != token.toLowerCase()) return;
    final restoring = session == null;
    if (restoring) {
      if (_guardActive || state != LaunchState.idle) return;
      session = s;
      state = LaunchState.launched;
    }
    final key = wallet.address.toLowerCase();
    final known = s._laterWallets.containsKey(key);
    s._laterWallets[key] = wallet;
    if (!restoring && known && _clearPreview == null && !_clearing) return;
    // A submitted order can change an existing holder's balance as well.
    invalidateLiquidationPreview();
    if (_clearTrader?.running == true) _clearTrader!.cancel();
    changed();
  }

  List<LaunchTx> transactions = [];

  bool _disposed = false;
  bool _guardActive = false;
  bool _querying = false;

  bool get busy =>
      state == LaunchState.preparing || _clearing || _guardActive || _querying;

  void changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearPreparing?.cancel();
    _clearTrader?.dispose();
    super.dispose();
  }

  void step(String text) {
    stage = text;
    log.add('$label $text');
    changed();
  }

  void fail(Object e) {
    error = e is BackendException
        ? e.userMessage
        : (e is StateError
              ? e.message
              : (e is FormatException ? e.message : '$e'));
    log.add('$label ${error!}', level: LogLevel.error);
  }

  /// Run [body] as the preparation phase; leaves [state] at launched / pending / failed / idle.
  Future<void> guard(Future<void> Function() body) async {
    checkWorkspace?.call();
    if (busy) throw StateError('正在准备，请稍候');
    if (state == LaunchState.pending) throw StateError('上一批交易尚未确认，请先查询原交易');
    if (state == LaunchState.launched) throw StateError('本轮已发币，请先清仓或开始新一轮');
    _guardActive = true;
    _lastClearedSession = null;
    _liquidationRemainders.clear();
    _receivePoolToken = false;
    state = LaunchState.preparing;
    error = null;
    transactions = [];
    changed();
    try {
      await body();
      if (state == LaunchState.preparing) state = LaunchState.idle;
    } on Object catch (e) {
      fail(e);
      if (state == LaunchState.preparing) state = LaunchState.idle;
    } finally {
      _guardActive = false;
      changed();
    }
  }

  /// An official creator may pull a non-native initial payment. Confirm the
  /// exact allowance before asking it to create the token.
  Future<void> authorizeLaunchPayment(
    String token,
    String spender,
    TradeWallet wallet,
    BigInt amount, {
    Map<String, Object?>? launchContext,
  }) => authorizeLaunchPayments(token, spender, [
    LaunchBuyer(wallet, amount),
  ], launchContext: launchContext);

  Future<void> authorizeLaunchPayments(
    String token,
    String spender,
    List<LaunchBuyer> buyers, {
    bool fundedInBundle = false,
    Map<String, Object?>? launchContext,
  }) async {
    if (buyers.isEmpty) return;
    final unique = <String, LaunchBuyer>{};
    for (final buyer in buyers) {
      if (buyer.amount <= BigInt.zero) continue;
      final id = buyer.wallet.address.toLowerCase();
      unique[id] = LaunchBuyer(
        buyer.wallet,
        buyer.amount + (unique[id]?.amount ?? BigInt.zero),
      );
    }
    if (unique.isEmpty) return;
    Future<Map<String, WalletState>> read([List<String>? subset]) async {
      final ids = subset ?? unique.keys.toList();
      final rows = <String, WalletState>{};
      for (var offset = 0; offset < ids.length; offset += 100) {
        final batch = await api.refreshWalletStates(
          ids.skip(offset).take(100).toList(),
          token: token,
          spender: spender,
        );
        for (final info in batch) {
          rows[info.wallet.toLowerCase()] = info;
        }
      }
      return rows;
    }

    final balances = await read();
    final needed = <LaunchBuyer>[];
    for (final row in unique.entries) {
      final state = balances[row.key];
      if (state?.tokenBalance == null ||
          !fundedInBundle && state!.tokenBalance! < row.value.amount)
        throw StateError('${row.key} 底池币余额不足');
      if (state!.routerAllowance == null) throw StateError('未能读取发射台授权额度');
      if (state.routerAllowance! < row.value.amount) needed.add(row.value);
    }
    if (needed.isEmpty) return;
    var offset = 0;
    int? retrySize;
    while (offset < needed.length) {
      final header = (await api.rpc([
        ('eth_getBlockByNumber', ['latest', false]),
      ])).single;
      if (header is! Map || header['gasLimit'] is! String)
        throw StateError('无法读取当前区块 Gas 上限');
      final half = BigInt.parse(header['gasLimit'] as String) ~/ BigInt.two;
      final budget = half < BigInt.from(15000000)
          ? half
          : BigInt.from(15000000);
      final limit = (budget ~/ BigInt.from(150000)).toInt().clamp(0, 103);
      var count = 0;
      final group = <LaunchBuyer>[];
      for (final buyer in needed.skip(offset)) {
        final reset =
            balances[buyer.wallet.address.toLowerCase()]!.routerAllowance! >
            BigInt.zero;
        final number = reset ? 2 : 1;
        if (number > limit) throw StateError('单钱包授权超过当前区块 Gas 预算');
        if (count + number > limit ||
            retrySize != null && group.length >= retrySize)
          break;
        group.add(buyer);
        count += number;
      }
      final legs = <LaunchTx>[];
      for (final buyer in group) {
        if (balances[buyer.wallet.address.toLowerCase()]!.routerAllowance! >
            BigInt.zero)
          legs.add(
            LaunchTx(
              '清除旧授权',
              buyer.wallet,
              token,
              erc20Approve(spender, BigInt.zero),
              BigInt.zero,
              100000,
              kind: 'approve',
            ),
          );
        legs.add(
          LaunchTx(
            '授权本次购买',
            buyer.wallet,
            token,
            erc20Approve(spender, buyer.amount),
            BigInt.zero,
            100000,
            kind: 'approve',
          ),
        );
      }
      await simulateBundle(legs, requireSuccess: true);
      if (legs.fold(BigInt.zero, (sum, tx) => sum + BigInt.from(tx.gasLimit)) >
          budget) {
        if (group.length == 1) throw StateError('单钱包授权模拟超过当前区块 Gas 预算');
        retrySize = (group.length + 1) ~/ 2;
        continue;
      }
      final expiry = await api.checkLaunchPayments(token, spender, [
        for (final buyer in group)
          (
            wallet: buyer.wallet.address,
            amount: buyer.amount,
            reset:
                balances[buyer.wallet.address.toLowerCase()]!.routerAllowance! >
                BigInt.zero,
          ),
      ], launchContext: launchContext);
      final gas = await launchBundleGas(api);
      final nonces = await checkBalances(legs, gas.gasPrice);
      final approvalReview = confirmApproval;
      if (approvalReview != null &&
          !await approvalReview(
            token,
            spender,
            group,
            legs.fold(
              BigInt.zero,
              (sum, tx) => sum + gas.gasPrice * BigInt.from(tx.gasLimit),
            ),
          ))
        throw StateError('已取消本批授权，发币已停止');
      if (DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiry)
        throw StateError('预购授权检查已过期，请重新准备');
      final done = await submitBundle(
        legs,
        signAll(legs, nonces, gas.gasPrice),
        what: '底池币授权',
      );
      _finish(done);
      if (!done) throw StateError('底池币授权尚未全部确认，请先查询原交易');
      final settled = await read([
        for (final b in group) b.wallet.address.toLowerCase(),
      ]);
      if (group.any(
        (b) =>
            settled[b.wallet.address.toLowerCase()]?.routerAllowance !=
            b.amount,
      ))
        throw StateError('授权回执已确认，但本批实际额度与确认金额不一致');
      state = LaunchState.preparing;
      changed();
      offset += group.length;
      retrySize = null;
    }
    final after = await read();
    final changedWallets = needed
        .map((buyer) => buyer.wallet.address.toLowerCase())
        .toSet();
    for (final entry in unique.entries) {
      final allowance = after[entry.key]?.routerAllowance;
      if (allowance == null ||
          allowance < entry.value.amount ||
          (changedWallets.contains(entry.key) &&
              allowance != entry.value.amount)) {
        throw StateError('${entry.key} 实际授权额度与本次购买不符');
      }
    }
  }

  Future<List<WalletState>> _launchWallets(
    List<String> addresses, {
    bool fresh = false,
  }) async {
    final result = <WalletState>[];
    for (var offset = 0; offset < addresses.length; offset += 100) {
      final group = addresses.skip(offset).take(100).toList();
      result.addAll(
        fresh
            ? await api.refreshWalletStates(group)
            : await api.walletStates(group),
      );
    }
    return result;
  }

  void _checkBundleSize(int length, {String what = '主交易'}) {
    if (length > _transactionLimit) {
      throw StateError('$label $what 共 $length 笔，超过单个捆绑上限 $_transactionLimit，请减少购买钱包');
    }
  }

  void _checkFourFlapLaunchSize({
    required int purchases,
    required bool convertEachPurchase,
    required bool hasTip,
    bool prepayVault = false,
  }) {
    // Each separate purchase can need its own BNB conversion. Approvals are
    // confirmed independently and never consume slots in the creation block.
    final size = 1 + purchases + (convertEachPurchase ? purchases : 0) +
        (hasTip ? 1 : 0) + (prepayVault ? 1 : 0);
    _checkBundleSize(size);
  }

  /// Sign in order with consecutive nonces per wallet.
  List<String> signAll(
    List<LaunchTx> txs,
    Map<String, int> nonces,
    BigInt gasPrice,
  ) {
    _checkBundleSize(txs.length);
    if (gasPrice <= BigInt.zero || gasPrice > BigInt.from(100000000000)) {
      throw StateError('BSC Gas 单价无效或超过 100 Gwei，已停止签名');
    }
    final raws = <String>[];
    for (final t in txs) {
      final k = t.from.address.toLowerCase();
      final n = nonces[k] ?? (throw StateError('交易序号读取失败：${t.from.address}'));
      final signed = t.to == null
          ? api.sign(
              t.from,
              LegacyTx.deploy(
                nonce: n,
                gasPrice: gasPrice,
                gasLimit: t.gasLimit,
                data: t.data,
              ),
            )
          : api.sign(
              t.from,
              LegacyTx(
                nonce: n,
                gasPrice: gasPrice,
                gasLimit: t.gasLimit,
                to: checksumAddress(t.to!),
                value: t.value,
                data: t.data,
              ),
            );
      nonces[k] = n + 1;
      t.hash = signed.hash;
      raws.add(signed.raw);
    }
    return raws;
  }

  /// Submit one private bundle and settle every transaction from receipts. Returns true when all confirmed.
  Future<bool> submitBundle(
    List<LaunchTx> txs,
    List<String> raws, {
    String what = '主交易',
  }) async {
    _checkBundleSize(raws.length, what: what);
    final head = await api.gas();
    step('提交$what：${raws.length} 笔');
    transactions = txs;
    for (final t in txs) {
      t.status = 'submitted';
    }
    state = LaunchState.pending;
    changed();
    try {
      await api.bundle(raws, head.blockNumber + BackendClient.groupWindowBlocks);
    } catch (e) {
      final refused = e is BackendException && e.notSubmitted;
      for (final t in txs) {
        t.status = refused ? 'not_submitted' : 'unknown';
      }
      if (refused) state = LaunchState.failed;
      changed();
      rethrow;
    }
    return settle(txs);
  }

  Future<bool> settle(List<LaunchTx> txs) async {
    for (var round = 0; round < 60; round++) {
      final pending = txs
          .where((t) => t.status == 'submitted' || t.status == 'unknown')
          .toList();
      if (pending.isEmpty) break;
      for (var i = 0; i < pending.length; i += 12) {
        await Future.wait(
          pending.skip(i).take(12).map((t) async {
            try {
              final r = _querying
                  ? await api.reconcileStatus(t.hash!)
                  : await api.status(t.hash!);
              if (r.finished && r.hash.toLowerCase() == t.hash!.toLowerCase()) {
                t.status = r.status;
                t.receipt = r.receipt;
              }
            } on BackendException {
              // An unreadable receipt is inconclusive.
            } on TimeoutException {
              // Retry the original hash in the next round.
            }
          }),
        );
      }
      if (pending.every(
        (t) => t.status != 'submitted' && t.status != 'unknown',
      ))
        break;
      if (round < 59) await _sleep(pollEvery);
    }
    for (final t in txs.where((t) => t.status == 'submitted')) {
      t.status = 'unknown';
    }
    if (txs.any(
          (t) =>
              t.purchasedToken != null ||
              t.alphaToken != null ||
              t.protocolCheck != null,
        ) ||
        (txs.length > 1 && txs.any((t) => t.kind == 'create'))) {
      int? block;
      String? blockHash;
      int? previousIndex;
      final confirmed = txs.where((t) => t.status == 'confirmed').toList();
      for (final tx in confirmed) {
        try {
          var receipt = tx.receipt;
          if (_querying || receipt == null ||
              receipt['blockNumber'] == null || receipt['blockHash'] == null ||
              receipt['transactionIndex'] == null ||
              receipt['logs'] is! List) {
            receipt =
                (await api.rpc([
                      ('eth_getTransactionReceipt', [tx.hash!]),
                    ])).single
                    as Map<String, dynamic>?;
          }
          if (receipt == null ||
              receipt['transactionHash']?.toString().toLowerCase() !=
                  tx.hash!.toLowerCase() ||
              receipt['status'] != '0x1' ||
              receipt['logs'] is! List)
            throw const FormatException();
          final hash = '${receipt['blockHash']}'.toLowerCase();
          if (!RegExp(r'^0x[0-9a-f]{64}$').hasMatch(hash) ||
              hash == '0x${'0' * 64}' ||
              hasConflictingReceiptLogs(receipt)) {
            throw const FormatException('发币回执需要重新核实');
          }
          final height = int.parse(receipt['blockNumber'] as String);
          final index = int.parse(receipt['transactionIndex'] as String);
          if (height < 0 || index < 0) throw const FormatException();
          if (height == block && hash != blockHash) {
            // Equal heights with different hashes can be observations from competing forks.
            // Reconcile every original receipt before reporting that the bundle was included.
            for (final observed in confirmed) {
              observed.status = 'unknown';
              observed.receipt = null;
            }
            break;
          }
          if ((block != null && height != block) ||
              (previousIndex != null && index <= previousIndex)) {
            tx.status = 'order_mismatch';
          } else if (tx.purchasedToken != null &&
              launchReceiptDelivery(
                    receipt,
                    tx.purchasedToken!,
                    tx.from.address,
                  ) <
                  (tx.minimumDelivery ?? BigInt.one)) {
            tx.status = 'purchase_unproven';
          } else if (tx.alphaToken != null && !launchAlphaPaid(receipt, tx)) {
            tx.status = 'alpha_unproven';
          }
          if (tx.protocolCheck != null) {
            tx.protocolError = tx.protocolCheck!(receipt);
            if (tx.protocolError != null) {
              if (tx.status == 'confirmed') tx.status = 'protocol_unproven';
              if (tx.kind == 'create' && session != null) {
                final code = (await api.rpc([
                  ('eth_getCode', [session!.token, receipt['blockNumber']]),
                ])).single;
                if (code is! String ||
                    !RegExp(r'^0x(?:[a-fA-F0-9]{2})+$').hasMatch(code)) {
                  tx.status = 'unknown';
                }
              }
            }
          }
          tx.receipt = receipt;
          block = height;
          blockHash = hash;
          previousIndex = index;
        } on Object {
          tx.status = 'unknown';
        }
      }
    }
    changed();
    return txs.isNotEmpty && txs.every((t) => t.status == 'confirmed');
  }

  /// "查询原交易": re-read receipts of the submitted launch; never sends.
  Future<void> query() async {
    if (state != LaunchState.pending || busy) return;
    _querying = true;
    try {
      step('查询原交易，不会重复提交');
      _finish(await settle(transactions));
    } finally {
      _querying = false;
      changed();
    }
  }

  void _finish(bool ok) {
    final create = transactions.where((t) => t.kind == 'create');
    if (transactions.any(
      (t) => t.status == 'unknown' || t.status == 'submitted',
    )) {
      state = LaunchState.pending;
      fail(StateError('有交易尚未确认，请稍后查询原交易；不会重复发送'));
    } else if (transactions.isNotEmpty &&
        transactions.every((t) => t.kind == 'approve')) {
      state = ok ? LaunchState.idle : LaunchState.failed;
      error = ok ? null : '授权未全部成功，请检查原交易';
      log.add(
        error ?? '授权已确认，可以继续准备发币',
        level: ok ? LogLevel.success : LogLevel.error,
      );
    } else if (create.isNotEmpty &&
        create.every(
          (t) => [
            'confirmed',
            'purchase_unproven',
            'order_mismatch',
            'protocol_unproven',
          ].contains(t.status),
        )) {
      state = LaunchState.launched;
      final failed = transactions
          .where((t) => t.status != 'confirmed')
          .toList();
      error = failed.isEmpty
          ? null
          : '代币已创建。${failed.map((t) => '${t.label}：${switch (t.status) {
              'reverted' => '已回滚',
              'not_included' => '未收录',
              'purchase_unproven' => '未查到首买净到账',
              'alpha_unproven' => '未查到匹配此次付款的 Alpha 事件',
              'protocol_unproven' => t.protocolError ?? '平台回执与发币方案不符',
              'order_mismatch' => '区块或交易顺序与计划不符',
              _ => '未确认成功',
            }}').join('、')}，请核对原交易';
      log.add(
        error ?? '$label 发币成功：${session?.token}',
        level: failed.isEmpty ? LogLevel.success : LogLevel.error,
      );
    } else {
      state = LaunchState.failed;
      fail(
        StateError(
          '创建交易未成功（${create.isEmpty ? '无' : create.first.status}），本轮未发币',
        ),
      );
    }
    changed();
  }

  /// Submit the main launch bundle and record the session for liquidation.
  Future<void> launchBundle(
    List<LaunchTx> txs,
    Map<String, int> nonceMap,
    BigInt gasPrice,
    LaunchSession s,
  ) async {
    final review = confirmCosts;
    if (review != null) {
      final preparedAt = DateTime.now();
      final ceilings = [for (final tx in txs) tx.gasLimit];
      if (!await review(txs, gasPrice, s)) return;
      if (DateTime.now().difference(preparedAt) > const Duration(seconds: 60))
        throw StateError('预览已超过 60 秒，请重新准备发币');
      final states = await _launchWallets(nonceMap.keys.toList(), fresh: true);
      if (states.length != nonceMap.length ||
          states.any((row) => row.nonce != nonceMap[row.wallet.toLowerCase()]))
        throw StateError('签名前钱包交易序号已变化，请重新准备');
      for (final row in states) {
        final need = txs
            .where(
              (t) => t.from.address.toLowerCase() == row.wallet.toLowerCase(),
            )
            .fold(
              BigInt.zero,
              (total, tx) =>
                  total + tx.value + gasPrice * BigInt.from(tx.gasLimit),
            );
        if (row.native < need) throw StateError('签名前 BNB 余额已不足，请重新准备');
      }
      await simulateBundle(txs, requireSuccess: true);
      for (var i = 0; i < txs.length; i++) {
        if (txs[i].gasLimit > ceilings[i])
          throw StateError('模拟的网络费上限已增加，请重新确认');
        txs[i].gasLimit = ceilings[i];
      }
      if (s.platform == 'genius' && s.wallets.length > 1) {
        await verifyGeniusBlockCapacity(txs);
      }
    }
    if (txs.any((tx) => tx.validUntil != null && tx.validUntil! <= DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
      throw StateError('底池币兑换报价已过期，请重新准备发币');
    }
    final raws = signAll(txs, nonceMap, gasPrice);
    transactions = txs;
    session = s;
    final ok = await submitBundle(txs, raws);
    _finish(ok);
  }

  /// Ordered simulation of the whole bundle with the real senders (eth_simulateV1): every step must
  /// succeed; gas = 2x used (refund headroom). When the node cannot
  /// simulate, a legacy launcher may explicitly retain its fixed ceilings.
  Future<void> simulateBundle(
    List<LaunchTx> txs, {
    bool requireSuccess = false,
    String? expectedCreatedToken,
  }) async {
    _checkBundleSize(txs.length);
    final calls = [
      for (final t in txs)
        {
          'from': t.from.address,
          if (t.to != null) 'to': checksumAddress(t.to!),
          'data': bytesToHex(t.data),
          'value': '0x${t.value.toRadixString(16)}',
          'gas': '0x${t.gasLimit.toRadixString(16)}',
          'gasPrice': '0x0',
        },
    ];
    List<Map> results;
    try {
      final r = (await api.rpc([
        (
          'eth_simulateV1',
          [
            {
              'blockStateCalls': [
                {'calls': calls},
              ],
              'validation': false,
              'traceTransfers': false,
            },
            'latest',
          ],
        ),
      ])).single;
      results = (((r! as List).first! as Map)['calls'] as List).cast<Map>();
    } on BackendException catch (e) {
      final unsupported = RegExp(
        r'^(?:method (?:not found|unavailable|not supported)|unsupported method)(?:$|[: .])|^(?:the method )?eth_simulatev1 (?:does not exist|is not (?:available|supported))',
        caseSensitive: false,
      ).hasMatch(e.message.trim());
      if (requireSuccess || !unsupported) {
        throw StateError('$label 连续模拟不可用，已停止发币准备：${e.message}');
      }
      log.add('$label 节点不支持连续模拟，使用原有网络费上限');
      return;
    } on TypeError {
      throw StateError('$label 连续模拟结果无效，已停止发币准备，请重试');
    } on TimeoutException {
      throw StateError('$label 连续模拟超时，已停止发币准备，请重试');
    }
    if (results.length != txs.length) throw StateError('连续交易预检返回不完整');
    for (var i = 0; i < txs.length; i++) {
      final r = results[i];
      if (r['status'] != '0x1') {
        final failure = r['error'] as Map?;
        final rule8 = '0x16fba6af${'8'.padLeft(64, '0')}';
        if (txs[i].label == 'newTokenV7WithVault' &&
            [r['returnData'], failure?['data']].contains(rule8)) {
          throw StateError(flapV7VaultRejection);
        }
        final err =
            failure?['message'] ??
            '${r['returnData'] ?? ''}'.padRight(10).substring(0, 10);
        throw StateError('${txs[i].label}预检失败：$err');
      }
      if (expectedCreatedToken != null && txs[i].kind == 'create') {
        final output = r['returnData'];
        if (output is! String ||
            !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(output) ||
            decodeSequence(
                  [AbiType.parse('address')],
                  hexToBytes(output),
                  0,
                ).single.toString().toLowerCase() !=
                expectedCreatedToken.toLowerCase()) {
          throw StateError('$label 创建模拟返回的代币地址与本次预测不一致，已停止');
        }
      }
      if (txs[i].alphaToken != null && !launchAlphaPaid(r, txs[i])) {
        throw StateError('模拟缺少匹配当前代币、付款钱包和费用的 Alpha 事件，已停止签名');
      }
      final protocolError = txs[i].protocolCheck?.call(r);
      if (protocolError != null)
        throw StateError('${txs[i].label} · $protocolError');
      final purchase = txs[i].purchasedToken;
      if (purchase != null) {
        final received = launchReceiptDelivery(
          r,
          purchase,
          txs[i].from.address,
        );
        if (received < (txs[i].minimumDelivery ?? BigInt.one))
          throw StateError('${txs[i].label}连续模拟未核实首买代币到账，已停止签名');
        txs[i].simulatedDelivery = received;
      }
      final used = int.parse('${r['gasUsed']}'.substring(2), radix: 16);
      if (used <= 0) throw StateError('网络费准备失败');
      txs[i].simulatedGasUsed = used;
      // Simulated gasUsed is net of storage refunds; execution needs more headroom (web: 2x for swaps).
      // Unused gas is not charged, so every step gets 2x, never above the block-safe 30M.
      txs[i].gasLimit = used * 2 > 30000000 ? 30000000 : used * 2;
    }
    log.add('$label 连续预检通过：${txs.length} 笔');
  }

  Future<void> verifyGeniusBlockCapacity(List<LaunchTx> txs) async {
    final latest = (await api.rpc([
      ('eth_getBlockByNumber', ['latest', false]),
    ])).single;
    final limit = latest is Map ? BigInt.tryParse('${latest['gasLimit']}') : null;
    if (limit == null) throw StateError('无法读取单区块 Gas 容量');
    checkLaunchBlockCapacity(txs, limit);
  }

  ({
    LaunchSession session,
    Market market,
    PreparedRound prepared,
    Map<String,BigInt> observedBalances,
    TokenMeta? settlement,
    DateTime readAt,
  })?
  _clearPreview;
  bool _clearing = false;
  BatchTrader? _clearTrader;
  QuoteProgress? _clearPreparing;
  bool get checkingLiquidation => _clearPreparing != null;
  bool get slowLiquidation => _clearPreparing?.slow == true;
  void cancelLiquidationPreview() => _clearPreparing?.cancel();
  int _liquidationSettingsRevision = 0;
  void invalidateLiquidationPreview() {
    _liquidationSettingsRevision++;
    cancelLiquidationPreview();
    _clearPreview = null;
  }

  final _liquidationRemainders = <String,List<String>>{};
  Iterable<String> get liquidationRemainders => {
    ..._liquidationRemainders, ...?_clearTrader?.last?.remainingAssets,
  }.entries.expand((order) => order.value.map((line) => '$line · ${order.key}'));
  bool get pendingLiquidation => _clearTrader?.unresolved.isNotEmpty == true ||
      _clearTrader?.hasPendingSaleTotals == true;
  Iterable<String> get unresolvedLiquidationHashes => {
    ...?_clearTrader?.unresolved, ...?_clearTrader?.last?.unverifiedSettlement, ...?_clearTrader?.pendingRemainderHashes,
  };

  TradePlan _liquidationPlan(
    LaunchSession s,
    Market market, {
    TokenMeta? settlement,
    Map<String, BigInt>? amounts,
    double ceiling = 20,
    bool allowUnknownImpact = false,
  }) => TradePlan(
    token: s.token,
    buy: false,
    wallets: s.liquidationWallets,
    settlement: settlement,
    mode: SendMode.bundle,
    amount: AmountRule(
      ratio: true,
      min: BigInt.from(10000),
      max: BigInt.from(10000),
    ),
    market: market,
    maxImpactPercent: ceiling,
    allowUnknownImpact: allowUnknownImpact,
    tip: s.tip > BigInt.zero ? BundleTip(s.dev, s.tip) : null,
    resume: amounts,
  );

  TokenMeta? get liquidationSettlement => _clearPreview?.settlement;

  /// Re-read eligible wallets and quote their balances into the chosen asset.
  Future<PreparedRound> prepareLiquidation() async {
    checkWorkspace?.call();
    final s = session;
    if (s == null || state != LaunchState.launched) {
      throw StateError('当前没有可清仓的会话');
    }
    if (_clearing) throw StateError('本轮正在清仓');
    _clearPreview = null;
    _clearing = true;
    final trader = _clearTrader ??= BatchTrader(
      api,
      log,
      label: '$label 清仓',
      strictSaleReceipts: true,
      pollEvery: pollEvery,
    );
    final progress = _clearPreparing = QuoteProgress(changed);
    changed();
    try {
      final reconciling = pendingLiquidation;
      if (reconciling) {
        await progress.read(() => trader.query());
        _liquidationRemainders.addAll(trader.last?.remainingAssets ?? {});
        if (pendingLiquidation) throw StateError('清仓原交易的回执或实际到账尚未核实，请稍后再查');
      }
      step('清仓 · 读取本轮持仓与价格影响');
      final readAt = DateTime.now();
      final market = Market(await progress.read(() => api.platform(s.token)));
      TokenMeta? settlement;
      if (_receivePoolToken) {
        if (!isAddress(s.poolToken) || s.poolToken.toLowerCase() == zeroAddress ||
            s.poolToken.toLowerCase() == s.token.toLowerCase() ||
            (market.platform == s.platform && market.quote.toLowerCase() != s.poolToken.toLowerCase())) {
          throw StateError('当前市场的底池币与发币记录不一致');
        }
        final meta = await progress.read<TokenMeta>(() => api.token(s.poolToken));
        settlement = meta;
        if (meta.address.toLowerCase() != s.poolToken.toLowerCase() ||
            meta.symbol.trim().isEmpty || meta.decimals == null ||
            meta.decimals! < 0 || meta.decimals! > 36) {
          throw StateError('无法核实清仓到账币种及精度');
        }
      }
      final plan = _liquidationPlan(s, market, settlement: settlement);
      final owners = plan.wallets.map((w) => w.address).toList();
      final balances = await progress.read(() => api.refreshWalletStates(owners, token: s.token));
      if (balances.any((w) => w.tokenBalance == null)) throw StateError('有参与钱包未返回代币余额');
      if (reconciling && s.platform != 'genius' && !progress.cancelled && identical(s, session) &&
          balances.length == owners.length && balances.every((w) => market.sellUnits(w.tokenBalance!) == BigInt.zero)) {
        _releaseSession(keepForLaterTrades: true);
        throw StateError('原清仓交易已核实，参与钱包已无可卖余额');
      }
      if (market.innerPlatform == 'four' && balances.any((w) => w.tokenBalance! > BigInt.zero) &&
          balances.every((w) => market.sellUnits(w.tokenBalance!) == BigInt.zero)) {
        throw StateError('参与钱包剩余代币均低于 Four 内盘最小可卖数量');
      }
      final prepared = await progress.read(() => trader.prepare(plan, walletSnapshot: balances));
      if(market.innerPlatform==null) await trader.prepareSellApprovals(
        token: s.token, market: market,
        wallets: plan.wallets,
        amounts: prepared.amounts,
        active: () => !progress.cancelled && identical(s, session),
      );
      if (progress.cancelled || !identical(s, session)) throw StateError('清仓会话已变化，请重新准备');
      final grants = await trader.forecastRouteGrants(market,false,prepared.amounts,settlement:plan.settlement);
      await trader.checkRouteGrants(market,plan.wallets,grants,active:() => !progress.cancelled && identical(s,session));
      if (progress.cancelled || !identical(s,session)) throw StateError('清仓会话已变化，请重新准备');
      _clearPreview = (
        session: s,
        market: market,
        prepared: prepared,
        observedBalances: Map.unmodifiable({for (final row in balances) row.wallet.toLowerCase():row.tokenBalance!}),
        settlement: settlement,
        readAt: readAt,
      );
      return prepared;
    } finally {
      progress.finish();
      _clearPreparing = null;
      _clearing = false;
      changed();
    }
  }

  /// Sell the confirmed amounts for this launch's participants into the selected asset.
  /// [prepared]: the confirmed amounts from [prepareLiquidation].
  Future<TradeOutcome> liquidate([
    PreparedRound? prepared,
    double threshold = 20,
    bool impactConfirmed = false,
  ]) async {
    checkWorkspace?.call();
    if (_clearing) throw StateError('本轮正在清仓');
    if (prepared == null) prepared = await prepareLiquidation();
    final revision = _liquidationSettingsRevision;
    final preview = _clearPreview;
    if (_clearing ||
        preview == null ||
        !identical(preview.prepared, prepared) ||
        !identical(preview.session, session) ||
        state != LaunchState.launched) {
      throw StateError('清仓准备已失效，请重新准备');
    }
    final impact = prepared.impact;
    if (!threshold.isFinite || threshold < 0 || threshold > 100)
      throw StateError('清仓阈值无效');
    if ((impact == null || !impact.isFinite || impact > threshold) &&
        !impactConfirmed) {
      throw StateError('请先确认本次清仓价格影响提醒');
    }
    _clearPreview = null;
    _clearing = true;
    final trader = _clearTrader!;
    try {
      final market =
          DateTime.now().difference(preview.readAt) < const Duration(seconds: 2)
          ? preview.market
          : Market(
              await PreviewDeadline().read(
                () => api.platform(preview.session.token),
              ),
            );
      final owners = preview.session.liquidationWallets.map((w) => w.address).toList();
      final current = await api.refreshWalletStates(owners, token: preview.session.token);
      final balances = {for (final row in current) row.wallet.toLowerCase(): row.tokenBalance};
      if (current.length != owners.length || balances.length != owners.length ||
          owners.any((owner) => balances[owner.toLowerCase()] !=
              preview.observedBalances[owner.toLowerCase()])) {
        throw StateError('参与钱包持仓已变化，请重新准备并确认最新清仓数量');
      }
      if (revision != _liquidationSettingsRevision) {
        throw StateError('参与钱包或清仓设置已更新，请重新准备');
      }
      if (!identical(preview.session, session) ||
          !sameTradeMarket(preview.market, market)) {
        throw StateError('清仓市场或会话已变化，请重新准备');
      }
      step('清仓 · 提交');
      final out = await trader.run(
        _liquidationPlan(
          preview.session,
          market,
          amounts: prepared.amounts,
          settlement: preview.settlement,
          ceiling: impact != null && impact.isFinite && impact > threshold
              ? impact
              : threshold,
          allowUnknownImpact: impactConfirmed && prepared.canConfirmUnknown,
        ),
      );
      _liquidationRemainders.addAll(out.remainingAssets);
      if (pendingLiquidation) throw StateError('清仓原交易的回执或实际到账尚未核实，请稍后再查');
      log.add(
        '$label 清仓：成功 ${out.confirmed}，失败 ${out.failed}，${out.stopped ? '已停止' : '已结束'}',
        level: out.failed == 0 && !out.stopped
            ? LogLevel.success
            : LogLevel.error,
      );
      if (!out.stopped &&
          out.failed == 0 &&
          out.confirmed > 0 &&
          preview.session.platform != 'genius') {
        final holders = preview.session.liquidationWallets.map((w) => w.address).toList();
        try {
          final rows = await api.refreshWalletStates(
            holders,
            token: preview.session.token,
          );
          final byAddress = {
            for (final row in rows) row.wallet.toLowerCase(): row.tokenBalance,
          };
          if (holders.any(
            (address) => byAddress[address.toLowerCase()] == null,
          )) {
            throw StateError('有参与钱包未返回代币余额');
          }
          if (revision == _liquidationSettingsRevision && holders.every(
            (address) => market.sellUnits(byAddress[address.toLowerCase()]!) == BigInt.zero,
          )) {
            for (final row in rows.where((r) => r.tokenBalance! > BigInt.zero)) {
              log.add('${row.wallet} 剩余 ${formatUnits(row.tokenBalance!, market.decimals,maxFraction:market.decimals)} ${preview.session.symbol}，低于 Four 内盘最小可卖数量');
            }
            _releaseSession(keepForLaterTrades: true);
            log.add('$label 已核对全部参与钱包，已无可卖余额，可开始新一轮', level: LogLevel.success);
          } else {
            log.add('$label 钱包仍有可卖余额，保留本轮清仓');
          }
        } on Object {
          log.add('$label 卖出交易已确认，无法核实全部钱包余额，保留本轮清仓', level: LogLevel.error);
        }
      }
      return out;
    } finally {
      _clearing = false;
      changed();
    }
  }

  /// "新建下一轮": forget the launched session (wallet keys stay in the form).
  void reset() {
    if (_clearing) throw StateError('本轮正在清仓');
    if (state == LaunchState.pending || pendingLiquidation)
      throw StateError('有交易尚未确认，请先查询原交易');
    _releaseSession();
  }

  void _releaseSession({bool keepForLaterTrades = false}) {
    _lastClearedSession = keepForLaterTrades ? session : null;
    _receivePoolToken = false;
    _clearTrader?.dispose();
    _clearTrader = null;
    _clearPreview = null;
    state = LaunchState.idle;
    session = null;
    transactions = [];
    error = null;
    stage = '';
    changed();
  }

  BigInt bnbNeed(Map<String, BigInt> needs, TradeWallet w) =>
      needs[w.address.toLowerCase()] ?? BigInt.zero;

  /// Every wallet must hold its payments, network fees and a liquidation reserve.
  Future<Map<String, int>> checkBalances(
    List<LaunchTx> txs,
    BigInt gasPrice, {
    Map<String, BigInt> extra = const {},
    int reserveGas = 0,
  }) async {
    final need = <String, BigInt>{};
    final wallets = <String, TradeWallet>{};
    for (final t in txs) {
      final k = t.from.address.toLowerCase();
      wallets[k] = t.from;
      need[k] =
          (need[k] ?? BigInt.zero) +
          t.value +
          BigInt.from(t.gasLimit) * gasPrice;
    }
    for (final e in extra.entries) {
      need[e.key] = (need[e.key] ?? BigInt.zero) + e.value;
    }
    final states = await _launchWallets([
      for (final w in wallets.values) w.address,
    ]);
    final found = {for (final st in states) st.wallet.toLowerCase(): st};
    for (final k in wallets.keys) {
      final st = found[k] ?? (throw StateError('钱包状态不完整，请刷新'));
      final total = need[k]! + BigInt.from(reserveGas) * gasPrice;
      if (st.native < total) {
        throw StateError(
          '${st.wallet} BNB 不足：现有 ${formatUnits(st.native, 18)}，需要 ${formatUnits(total, 18)}（含主交易、网络费和清仓预留）',
        );
      }
    }
    return {for (final k in wallets.keys) k: found[k]!.nonce};
  }
}

BigInt _ceilDiv(BigInt a, BigInt b) =>
    a <= BigInt.zero ? BigInt.zero : (a + b - BigInt.one) ~/ b;

// =====================================================================================================
// Four.meme
// =====================================================================================================

const fourLabels = [
  'Meme',
  'AI',
  'Defi',
  'Games',
  'Infra',
  'De-Sci',
  'Social',
  'Depin',
  'Charity',
  'Others',
];

/// A raised (pool) token from Four's config (status PUBLISH).
class FourRaised {
  FourRaised(this.raw)
    : lookupSymbol = '${raw['nativeSymbol'] ?? raw['symbol'] ?? ''}'.trim(),
      address = checksumAddress('${raw['symbolAddress']}'),
      totalBAmount = '${raw['totalBAmount'] ?? ''}'.trim();
  final Map<String, dynamic> raw;
  final String lookupSymbol;
  final String address;
  final String totalBAmount;
  bool get native => lookupSymbol.toUpperCase() == 'BNB';
  String get display {
    final s = '${raw['symbol'] ?? ''}'.trim();
    return s.isNotEmpty && s.toUpperCase() != lookupSymbol.toUpperCase()
        ? '$lookupSymbol ($s)'
        : lookupSymbol;
  }
}

/// Port of fourBudget.js: the curve target including platform fee and buy tax (inclusive funds semantics).
({BigInt baseFunds, BigInt bondingFunds}) fourBondingBudget(
  BigInt totalTarget,
  BigInt feeRateBps,
  BigInt buyTaxPercent,
) {
  if (totalTarget <= BigInt.zero) throw StateError('Four.meme 内盘目标无效');
  if (buyTaxPercent < BigInt.zero || buyTaxPercent > BigInt.from(100)) {
    throw StateError('买入税率无效');
  }
  final platformFee = _ceilDiv(totalTarget * feeRateBps, BigInt.from(10000));
  final taxFee = _ceilDiv(totalTarget * buyTaxPercent, BigInt.from(100));
  final base = totalTarget + platformFee + taxFee;
  return (
    baseFunds: base,
    bondingFunds: base + _ceilDiv(base * BigInt.from(100), BigInt.from(10000)),
  );
}

/// Port of validateBondingPlan: internal mode must stay below the target; external mode may cross it only
/// with the final internal purchase.
void validateFourBonding({
  required bool external,
  required BigInt dev,
  required List<BigInt> internal,
  required BigInt target,
  required BigInt crossing,
}) {
  final total = internal.fold(dev, (a, b) => a + b);
  final withoutLast = internal.isEmpty ? dev : total - internal.last;
  if (!external) {
    if (total >= target) throw StateError('内盘买入合计已达到迁移目标，请改用内外盘模式或减少金额');
  } else {
    if (internal.isEmpty) throw StateError('内外盘模式至少需要一个内盘购买地址');
    if (withoutLast >= target || total < crossing) {
      throw StateError('只有最后一笔内盘买入可以达到迁移目标，请调整金额');
    }
  }
}

class FourTax {
  const FourTax({
    required this.feeRate,
    required this.feeRateSell,
    required this.burn,
    required this.divide,
    required this.liquidity,
    required this.recipient,
    this.recipientAddress = '',
    this.minSharing = 100000,
  });
  final int feeRate;
  final int feeRateSell;
  final int burn;
  final int divide;
  final int liquidity;
  final int recipient;
  final String recipientAddress;
  final int minSharing;

  void validate() {
    if (![1, 3, 5, 10].contains(feeRate) ||
        ![1, 3, 5, 10].contains(feeRateSell)) {
      throw const FormatException('买卖税必须为 1、3、5 或 10');
    }
    for (final v in [burn, divide, liquidity, recipient]) {
      if (v < 0 || v > 100) throw const FormatException('税收分配必须位于 0 至 100%');
    }
    if (burn + divide + liquidity + recipient != 100) {
      throw const FormatException('四项税收分配合计必须为 100');
    }
    if (!RegExp(r'^[1-9]0{5,}$').hasMatch('$minSharing')) {
      throw const FormatException('分红最低持仓必须是 100000、1000000 等有效整数');
    }
    if (recipient > 0 && !isAddress(recipientAddress.trim())) {
      throw const FormatException('指定收款比例大于 0 时必须填写有效地址');
    }
  }

  Map<String, Object> toJson() => {
    'feeRate': feeRate,
    'feeRateSell': feeRateSell,
    'burnRate': burn,
    'divideRate': divide,
    'liquidityRate': liquidity,
    'recipientRate': recipient,
    'recipientAddress': recipient == 0 ? '' : recipientAddress.trim(),
    'minSharing': minSharing,
  };
}

class FourLaunchForm {
  FourLaunchForm({
    required this.name,
    required this.shortName,
    required this.desc,
    this.label = 'Meme',
    this.webUrl = '',
    this.twitterUrl = '',
    this.telegramUrl = '',
    this.tax,
    required this.raised,
    this.external = false,
    this.payWithBnb = false,
    required this.image,
    BigInt? tip,
  }) : tip = tip ?? BigInt.zero;
  final String name;
  final String shortName;
  final String desc;
  final String label;
  final String webUrl;
  final String twitterUrl;
  final String telegramUrl;

  /// Null for ordinary tokens. Tax tokens include the creator-selected tax schedule.
  final FourTax? tax;
  final FourRaised raised;

  final bool external;
  final bool payWithBnb;
  final LaunchImage image;
  final BigInt tip;
}

final _fourCreate = AbiFunction.parse(
  'createToken(bytes args,bytes signature)',
);
final _fourLaunchFee = AbiFunction.parse('_launchFee() returns (uint256)');
final _fourTradingFee = AbiFunction.parse(
  '_tradingFeeRate() returns (uint256)',
);

const fourPancakeRouter = '0x10ED43C718714eb63d5aA57B78B54704E256024E';
final _fourBuy = AbiFunction.parse(
  'buyTokenAMAP(address,address,uint256,uint256)',
);
final _fourNativeOuter = AbiFunction.parse(
  'swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)',
);
final _fourQuoteOuter = AbiFunction.parse(
  'swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
);
final _fourGraduation = bytesToHex(
  keccak256('LiquidityAdded(address,uint256,address,uint256)'.codeUnits),
);
const _fourCreatedTopic =
    '0x396d5e902b675b032348d3d2e9517ee8f0c4a926603fbc075d3d282ff00cad20';

List<String> _fourEventData(Map receipt, String signature) => [
  for (final event in (receipt['logs'] as List? ?? const []).whereType<Map>())
    if ('${event['address']}'.toLowerCase() == fourManager.toLowerCase() &&
        event['topics'] is List &&
        (event['topics'] as List).length == 1 &&
        '${event['topics'][0]}'.toLowerCase() == signature &&
        event['data'] is String &&
        RegExp(r'^0x(?:[0-9a-fA-F]{64})+$').hasMatch(event['data'] as String))
      (event['data'] as String).substring(2).toLowerCase(),
];
String _addressWord(String value) =>
    value.substring(2).toLowerCase().padLeft(64, '0');
String? _verifyFourPhase(
  Map receipt,
  String token,
  String quote, {
  required bool graduates,
}) {
  final all = _fourEventData(receipt, _fourGraduation);
  final exact = all.where(
    (d) =>
        d.length == 256 &&
        d.startsWith(_addressWord(token)) &&
        d.substring(128, 192) == _addressWord(quote),
  );
  if (graduates)
    return all.length == 1 && exact.length == 1 ? null : '未找到本轮新币和底池唯一的毕业事件';
  return all.isEmpty ? null : '当前交易不应触发毕业';
}

Object? fourData(String action, Object? payload) {
  if (payload is! Map || ('${payload['code']}' != '0')) {
    final msg = payload is Map
        ? (payload['msg'] ?? payload['message'] ?? '平台未返回具体原因')
        : '平台返回数据不完整';
    // Four answered with a business refusal (code != 0); same code as the backend's explicit refusals.
    throw BackendException('FOUR_API_REJECTED', 'Four $action 失败：$msg', false);
  }
  return payload['data'];
}

String _hexOf(Object? v) {
  if (v is String && v.startsWith('0x')) return v;
  if (v is String && RegExp(r'^[0-9a-fA-F]+$').hasMatch(v)) return '0x$v';
  if (v is String) return bytesToHex(_base64(v));
  throw StateError('Four 返回的创建参数格式无效');
}

Uint8List _base64(String s) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final clean = s.replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
  final out = <int>[];
  var buf = 0, bits = 0;
  for (final c in clean.split('')) {
    buf = (buf << 6) | chars.indexOf(c);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buf >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// Create on the official Four.meme manager after signature and address verification.
class FourLauncher extends Launcher {
  FourLauncher(super.api, super.log, {super.sleep, super.pollEvery})
    : super(label: 'Four', transactionLimit: _fourFlapBundleLimit);

  Future<({BigInt crossing, BigInt base, int decimals})> previewTarget(
    FourRaised asset,
    int buyTaxPercent,
  ) async {
    final decimals = asset.native
        ? 18
        : (await api.token(asset.address)).decimals;
    if (decimals == null || decimals < 0 || decimals > 36)
      throw StateError('底池币精度无效');
    final rate =
        _fourTradingFee
                .decodeOutput(
                  await api.call(
                    fourManager,
                    bytesToHex(_fourTradingFee.encode([])),
                  ),
                )
                .single
            as BigInt;
    if (rate > BigInt.from(10000)) throw StateError('Four 交易费率无效');
    final budget = fourBondingBudget(
      parseUnits(asset.totalBAmount, decimals),
      rate,
      BigInt.from(buyTaxPercent),
    );
    return (
      crossing: budget.bondingFunds,
      base: budget.baseFunds,
      decimals: decimals,
    );
  }

  Future<List<FourRaised>> raisedTokens() async {
    final data = fourData('读取配置', await api.four('config'));
    if (data is! List) throw StateError('Four 配置格式无效');
    final seen = <String>{};
    final out = <FourRaised>[];
    for (final t in data.whereType<Map>()) {
      final m = t.cast<String, dynamic>();
      if (m['status'] != 'PUBLISH' || !isAddress('${m['symbolAddress']}')) {
        continue;
      }
      final r = FourRaised(m);
      if (r.lookupSymbol.isEmpty ||
          r.totalBAmount.isEmpty ||
          !seen.add(r.address.toLowerCase())) {
        continue;
      }
      out.add(r);
    }
    return out;
  }

  Future<void> launch(
    FourLaunchForm form, {
    required LaunchBuyer dev,
    List<LaunchBuyer> internal = const [],
    List<LaunchBuyer> external = const [],
  }) => guard(() async {
    // ---------------------------------------------------------------- 1. parameters
    step('1/8 校验参数');
    validateLaunchPurchases(dev, internal, external, migrate: form.external);
    if (internal.length + external.length > 100)
      throw const FormatException('Four 内外盘买家合计最多 100 位');
    if (form.external && (form.tax == null || external.isEmpty))
      throw StateError('Four 内外盘需要税币和至少一位外盘买家');
    if (form.name.trim().isEmpty ||
        form.shortName.trim().isEmpty ||
        form.desc.trim().isEmpty) {
      throw const FormatException('请完整填写代币名称、简写和描述');
    }
    if (!fourLabels.contains(form.label)) throw const FormatException('分类无效');
    if (form.image.bytes.isEmpty || form.image.bytes.length > 10000000) {
      throw const FormatException('请选择不超过 10 MB 的代币图片');
    }
    form.tax?.validate();
    final selected = form.raised;
    final options = await raisedTokens();
    final raised = options
        .where((o) => o.address == selected.address)
        .firstOrNull;
    if (raised == null || raised.lookupSymbol != selected.lookupSymbol) {
      throw StateError('所选底池代币已变更，请重新选择并确认');
    }
    final convertPayments = form.payWithBnb && !raised.native;
    _checkFourFlapLaunchSize(
      purchases: internal.length + external.length +
          (convertPayments && dev.amount > BigInt.zero ? 1 : 0),
      convertEachPurchase: convertPayments,
      hasTip: form.tip > BigInt.zero,
    );
    final launchFee =
        _fourLaunchFee
                .decodeOutput(
                  await api.call(
                    fourManager,
                    bytesToHex(_fourLaunchFee.encode([])),
                  ),
                )
                .single!
            as BigInt;
    final funding = await LaunchFunding.prepare(api, raised.address, [dev, ...internal, ...external],
        convert: convertPayments);
    if (funding.converted) {
      internal = [if (dev.amount > BigInt.zero) funding.units(dev), ...internal.map(funding.units)];
      external = external.map(funding.units).toList();
      // Four signs the requested presale before we submit the bundle. Buy from the
      // creator immediately after creation when its payment first needs converting.
      dev = LaunchBuyer(dev.wallet, BigInt.zero);
    }
    var creationValue = launchFee;
    var devQuotePayment = BigInt.zero;
    var presale = BigInt.zero;
    if (dev.amount > BigInt.zero) {
      final rate =
          _fourTradingFee
                  .decodeOutput(
                    await api.call(
                      fourManager,
                      bytesToHex(_fourTradingFee.encode([])),
                    ),
                  )
                  .single
              as BigInt;
      if (rate > BigInt.from(10000)) throw StateError('Four 交易费率无效');
      // The form accepts the total buy budget, as on BotAI. Four's API takes
      // a principal and adds its fee to the payable creation value.
      final bps = BigInt.from(10000);
      presale = ((dev.amount + BigInt.one) * bps - BigInt.one) ~/ (bps + rate);
      final total = presale + presale * rate ~/ bps;
      if (raised.native) {
        creationValue += total;
      } else {
        devQuotePayment = total;
      }
    }
    final decimals =
        !raised.native &&
            (dev.amount > BigInt.zero ||
                internal.isNotEmpty ||
                external.isNotEmpty)
        ? (await api.token(raised.address)).decimals ??
              (throw StateError('Four 底池币精度未知'))
        : 18;
    if (dev.amount > BigInt.zero || internal.isNotEmpty || form.external) {
      final budget = await previewTarget(raised, form.tax?.feeRate ?? 0);
      validateFourBonding(
        external: form.external,
        dev: dev.amount,
        internal: internal.map((b) => b.amount).toList(),
        target: budget.base,
        crossing: budget.crossing,
      );
    }
    // ---------------------------------------------------------------- 2. login and image
    step('2/8 登录 Four.meme');
    final nonce = fourData(
      '获取登录信息',
      await api.four('nonce', {'address': dev.wallet.address}),
    );
    final login = fourData(
      '登录',
      await api.four('login', {
        'payload': {
          'region': 'WEB',
          'langType': 'EN',
          'loginIp': '',
          'inviteCode': '',
          'verifyInfo': {
            'address': dev.wallet.address,
            'networkCode': 'BSC',
            'signature': dev.wallet.signMessage('You are sign in Meme $nonce'),
            'verifyType': 'LOGIN',
          },
          'walletName': 'MetaMask',
        },
      }),
    );
    if (login is! String || login.isEmpty) {
      throw StateError('Four 登录没有返回 access token');
    }
    step('3/8 上传图片');
    final imgUrl = fourData('上传图片', await api.fourUpload(login, form.image));
    if (imgUrl is! String || imgUrl.isEmpty) throw StateError('图片上传没有返回 URL');

    // ---------------------------------------------------------------- 4. create signature and address
    step('5/8 获取发币参数');
    final body = <String, Object?>{
      'name': form.name.trim(),
      'shortName': form.shortName.trim(),
      'desc': form.desc.trim(),
      'totalSupply':
          num.tryParse('${raised.raw['totalAmount'] ?? 1000000000}') ??
          1000000000,
      'raisedAmount': num.tryParse(raised.totalBAmount) ?? 24,
      'saleRate': num.tryParse('${raised.raw['saleRate'] ?? 0.8}') ?? 0.8,
      'reserveRate': 0,
      'imgUrl': imgUrl,
      'raisedToken': raised.raw,
      'launchTime': DateTime.now().millisecondsSinceEpoch,
      'funGroup': false,
      'label': form.label,
      'lpTradingFee': 0.0025,
      'preSale': formatUnits(presale, decimals, maxFraction: decimals),
      'clickFun': false,
      'symbol': raised.raw['symbol'],
      'dexType': 'PANCAKE_SWAP',
      'rushMode': false,
      'onlyMPC': false,
      'feePlan': false,
      if (form.webUrl.trim().isNotEmpty) 'webUrl': form.webUrl.trim(),
      if (form.twitterUrl.trim().isNotEmpty)
        'twitterUrl': form.twitterUrl.trim(),
      if (form.telegramUrl.trim().isNotEmpty)
        'telegramUrl': form.telegramUrl.trim(),
      if (form.tax != null) 'tokenTaxInfo': form.tax!.toJson(),
    };
    final created = fourData(
      '获取发币参数',
      await api.four('create', {'accessToken': login, 'payload': body}),
    );
    if (created is! Map) throw StateError('Four 创建参数为空');
    final createData = _fourCreate.encode([
      hexToBytes(_hexOf(created['createArg'])),
      hexToBytes(_hexOf(created['signature'])),
    ]);
    if (devQuotePayment > BigInt.zero) {
      // The create simulation pulls this exact amount from Dev. Check every
      // direct buyer's funding before allowing the first approval to go on chain.
      final purchases = [LaunchBuyer(dev.wallet, devQuotePayment), ...internal, ...external];
      final price = (await launchBundleGas(api)).gasPrice;
      for (var offset = 0; offset < purchases.length; offset += 100) {
        final batch = purchases.skip(offset).take(100).toList();
        final states = await api.refreshWalletStates(
          batch.map((b) => b.wallet.address).toList(), token: raised.address, spender: fourManager,
        );
        final byOwner = {for (final s in states) s.wallet.toLowerCase(): s};
        for (final buyer in batch) {
          final state = byOwner[buyer.wallet.address.toLowerCase()];
          final balance = state?.tokenBalance;
          if (balance == null || balance < buyer.amount) {
            throw StateError('${buyer.wallet.address} 底池币余额不足');
          }
          // The exact gas comes from ordered simulation. The common
          // liquidation reserve and minimum transaction cost are already known.
          final isDev = buyer.wallet.address == dev.wallet.address;
          final minimum = BigInt.from(2650000 + 21000) * price +
              (isDev ? creationValue + form.tip * BigInt.two +
                  (form.tip > BigInt.zero ? BigInt.from(21000) * price : BigInt.zero) : BigInt.zero);
          if (state!.native < minimum) throw StateError('${buyer.wallet.address} BNB 不足以支付发币和清仓预留');
        }
      }
      await authorizeLaunchPayment(raised.address, fourManager, dev.wallet, devQuotePayment);
    }
    step('6/8 预测代币地址');
    final predicted = await api.four('predictTokenAddress', {
      'from': dev.wallet.address,
      'createCalldata': bytesToHex(createData),
      'value': '0x${creationValue.toRadixString(16)}',
    });
    final tokenAddress = predicted is Map
        ? '${predicted['tokenAddress'] ?? ''}'
        : '';
    if (!isAddress(tokenAddress)) throw StateError('创建模拟没有返回有效代币地址');
    final token = checksumAddress(tokenAddress);
    if ('${(await api.rpc([
          ('eth_getCode', [token, 'latest']),
        ])).single}' !=
        '0x') {
      throw StateError('预测地址已有合约：$token');
    }

    final withBuyers = internal.isNotEmpty || external.isNotEmpty;
    final quote = raised.native ? zeroAddress : raised.address;
    final deadline = BigInt.from(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
    );
    final context = {
      'dev': dev.wallet.address,
      'to': fourManager,
      'data': bytesToHex(createData),
      'value': creationValue.toString(),
    };
    if (!raised.native && withBuyers) {
      await authorizeLaunchPayments(raised.address, fourManager, internal, fundedInBundle: funding.converted);
      await authorizeLaunchPayments(
        raised.address,
        fourPancakeRouter,
        external,
        launchContext: context,
        fundedInBundle: funding.converted,
      );
    }
    await funding.executable(api);
    final grouped = [...internal, ...external];
    LaunchTx walletBuy(int index, BigInt minimum) {
      final buyer = grouped[index],
          outer = index >= internal.length,
          crosses = form.external && index == internal.length - 1;
      final path = [raised.native ? wbnb : raised.address, token];
      final data = !outer
          ? _fourBuy.encode([
              token,
              buyer.wallet.address,
              buyer.amount,
              minimum,
            ])
          : raised.native
          ? _fourNativeOuter.encode([
              minimum,
              path,
              buyer.wallet.address,
              deadline,
            ])
          : _fourQuoteOuter.encode([
              buyer.amount,
              minimum,
              path,
              buyer.wallet.address,
              deadline,
            ]);
      return LaunchTx(
        outer
            ? '外盘买入'
            : crosses
            ? '末笔内盘买入并毕业'
            : '内盘买入',
        buyer.wallet,
        outer ? fourPancakeRouter : fourManager,
        data,
        raised.native ? buyer.amount : BigInt.zero,
        crosses ? 14500000 : 2500000,
        kind: outer ? 'outer' : 'inner',
        purchasedToken: token,
        minimumDelivery: minimum > BigInt.zero ? minimum : BigInt.one,
        protocolCheck: (receipt) =>
            _verifyFourPhase(receipt, token, quote, graduates: crosses),
      );
    }

    // ---------------------------------------------------------------- 5. bundle
    step('7/8 模拟创建交易');
    final txs = <LaunchTx>[
      LaunchTx(
        '创建代币',
        dev.wallet,
        fourManager,
        createData,
        creationValue,
        5000000,
        kind: 'create',
        creationFee: launchFee,
        protocolCheck: (receipt) {
          final events = _fourEventData(receipt, _fourCreatedTopic);
          if (events.length != 1 ||
              !events.single.startsWith(
                '${_addressWord(dev.wallet.address)}${_addressWord(token)}',
              ))
            return 'Four 创建事件与本轮 Dev、预测代币地址不符';
          return _verifyFourPhase(receipt, token, quote, graduates: false);
        },
        purchasedToken: dev.amount > BigInt.zero ? token : null,
      ),
      for (var i = 0; i < grouped.length; i++) walletBuy(i, BigInt.zero),
      if (form.tip > BigInt.zero)
        LaunchTx(
          '贿赂费',
          dev.wallet,
          bscBundleTipRecipient,
          Uint8List(0),
          form.tip,
          100000,
          kind: 'tip',
        ),
    ];
    await simulateBundle(funding.include(txs), requireSuccess: true);
    if (withBuyers) {
      for (var i = 0; i < grouped.length; i++) {
        final receive = txs[1 + i].simulatedDelivery!;
        txs[1 + i] = walletBuy(
          i,
          (receive * BigInt.from(9950) + BigInt.from(9999)) ~/
              BigInt.from(10000),
        );
      }
      await simulateBundle(funding.include(txs), requireSuccess: true);
    }
    final signedOrder = funding.include(txs);
    final gas = await launchBundleGas(api);
    final nonceMap = await checkBalances(
      signedOrder,
      gas.gasPrice,
      extra: {dev.wallet.address.toLowerCase(): form.tip},
      reserveGas: 2650000,
    );
    step('8/8 本地签名并提交');
    await launchBundle(
      signedOrder,
      nonceMap,
      gas.gasPrice,
      LaunchSession(
        platform: 'four',
        poolToken: quote,
        token: token,
        symbol: form.shortName.trim(),
        dev: dev.wallet,
        wallets: [dev.wallet, ...grouped.where((b) => b.wallet.address != dev.wallet.address).map((b) => b.wallet)],
        tip: form.tip,
        reserved: form.tip + BigInt.from(2650000) * gas.gasPrice,
      ),
    );
  });
}

// =====================================================================================================
// Flap
// =====================================================================================================

const flapVaultPortal = '0x90497450f2a706f1951b5bdda52B4E5d16f34C06';
const flapTaxV3Implementation = '0x024f18294970B5c76c0691b87f138A0317156422';
const flapNonTaxImplementation = '0x88881b6f03090462a969eC7f48385744Eeb63333';
const flapSignedCurveV1 =
    '0x3526f6a0e790306d64c896eeda5ec66052ea17889e20632ff0cf512923153dad';
const flapSignedCurveV2 =
    '0x0f1f338177d85790dd81a6e795b59ae3a205cb498e034240ce2261bf753f13a4';
final flapTaxDuration = BigInt.from(3153600000);
final flapMinDividendShare = BigInt.from(10000) * BigInt.from(10).pow(18);

int _flapPaymentDecimals(Object? value) =>
    value is num &&
        value.isFinite &&
        value >= 0 &&
        value <= 36 &&
        value == value.truncate()
    ? value.toInt()
    : -1;

/// A Flap payment (pool) token from the official catalog.
typedef FlapCatalogSnapshot = ({
  List<FlapPayment> tokens,
  bool partial,
  bool stale,
  String? refreshError,
});

class FlapPayment {
  FlapPayment(Map<String, dynamic> j)
    : address = isAddress('${j['address']}')
          ? checksumAddress('${j['address']}')
          : '',
      symbol = '${j['symbol'] ?? ''}',
      name = '${j['name'] ?? j['symbol'] ?? ''}',
      decimals = _flapPaymentDecimals(j['decimals']),
      r = '${j['r'] ?? ''}',
      h = '${j['h'] ?? '0'}',
      k = '${j['k'] ?? ''}',
      category = '${j['category'] ?? 'crypto'}',
      available =
          '${j['status'] ?? 'available'}' == 'available' &&
          isAddress('${j['address']}') &&
          _flapPaymentDecimals(j['decimals']) >= 0;

  /// Custom pool token typed by the user (web 自定义底池): creation needs Flap's signed curve.
  FlapPayment.custom(String token, this.symbol, this.decimals)
    : address = checksumAddress(token),
      name = symbol,
      r = '',
      h = '0',
      k = '',
      category = 'custom',
      available = decimals >= 0 && decimals <= 36;
  final String address;
  final String symbol;
  final String name;
  final int decimals;
  final String r;
  final String h;
  final String k;
  final String category;
  final bool available;
  bool get native => address.toLowerCase() == zeroAddress;
}

BigInt _scaled(String v, [int digits = 36]) {
  final t = v.trim();
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(t)) {
    throw StateError('Flap 曲线参数不是有效十进制数：$t');
  }
  final parts = t.split('.');
  var frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > digits) {
    if (!RegExp(r'^0*$').hasMatch(frac.substring(digits))) {
      throw StateError('Flap 曲线参数精度超过 $digits 位');
    }
    frac = frac.substring(0, digits);
  }
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(digits) +
      BigInt.parse(frac.padRight(digits, '0'));
}

/// Port of calculateFlapCurveGross: gross quote needed to buy the 800M curve tokens, with fee and buy tax.
BigInt flapCurveGross({
  required String r,
  String h = '0',
  required String k,
  required int quoteDecimals,
  required BigInt platformBuyFeeBps,
  required BigInt buyTaxBps,
  BigInt? tokenTargetUnits,
}) {
  final scale = BigInt.from(10).pow(36);
  final billion = BigInt.from(1000000000);
  final totalFee = platformBuyFeeBps + buyTaxBps;
  if (totalFee < BigInt.zero || totalFee >= BigInt.from(10000)) {
    throw StateError('买入费率必须小于 100%');
  }
  final target =
      tokenTargetUnits ?? BigInt.from(800000000) * BigInt.from(10).pow(18);
  if (target <= BigInt.zero || target >= billion * BigInt.from(10).pow(18))
    throw StateError('Flap 内盘目标无效');
  final denominator =
      billion * scale - target * BigInt.from(10).pow(18) + _scaled(h);
  if (denominator <= BigInt.zero) throw StateError('Flap 曲线分母无效');
  final reserveAtTarget = _ceilDiv(_scaled(k) * scale, denominator);
  final net = reserveAtTarget - _scaled(r);
  if (net <= BigInt.zero) throw StateError('Flap 曲线目标储备无效');
  final gross = _ceilDiv(
    net * BigInt.from(10000),
    BigInt.from(10000) - totalFee,
  );
  return _ceilDiv(gross * BigInt.from(10).pow(quoteDecimals), scale);
}

void validateFlapPlan({
  required bool external,
  required BigInt dev,
  required List<BigInt> internal,
  required BigInt curveGross,
}) {
  final total = internal.fold(dev, (a, b) => a + b);
  final withoutLast = internal.isEmpty ? dev : total - internal.last;
  if (!external) {
    if (total >= curveGross) throw StateError('内盘买入合计已达到 Flap 曲线目标，请改用内外盘模式');
  } else {
    if (internal.isEmpty) throw StateError('内外盘模式至少需要一个内盘购买地址');
    if (dev >= curveGross || withoutLast >= curveGross || total < curveGross) {
      throw StateError('只有最后一笔内盘买入可以达到 Flap 曲线目标');
    }
  }
}

/// CREATE2 address of a Flap token clone (minimal proxy of [implementation]) for [salt].
Uint8List flapProxyHash(String implementation) => keccak256(
  hexToBytes(
    '0x3d602d80600a3d3981f3363d3d373d3d3d363d73${implementation.substring(2).toLowerCase()}5af43d82803e903d91602b57fd5bf3',
  ),
);

String flapTokenAddress(Uint8List salt, Uint8List proxyHash) =>
    create2Address(flapPortal, salt, proxyHash);

/// Vanity salt search (web findFlapTaxSalt): address ends with [suffix] (7777 tax / 8888 non-tax) and is unused.
Future<(Uint8List, String)> findFlapSalt(
  String implementation,
  String suffix,
  Future<bool> Function(String) available, {
  Random? random,
  int maxIterations = 1000000,
}) async {
  final rnd = random ?? Random.secure();
  final hash = flapProxyHash(implementation);
  final portal = hexToBytes(flapPortal);
  final want = [
    int.parse(suffix.substring(0, 2), radix: 16),
    int.parse(suffix.substring(2), radix: 16),
  ];
  var salt = keccak256(List<int>.generate(32, (_) => rnd.nextInt(256)));
  for (var i = 0; i < maxIterations; i++) {
    final a = keccak256(
      Uint8List.fromList([0xff, ...portal, ...salt, ...hash]),
    );
    if (a[30] == want[0] && a[31] == want[1]) {
      final address = checksumAddress(bytesToHex(a.sublist(12)));
      if (await available(address)) return (Uint8List.fromList(salt), address);
    }
    salt = keccak256(salt);
    if (i % 2048 == 2047) await Future<void>.delayed(Duration.zero);
  }
  throw StateError('未能在限定次数内生成 Flap $suffix 地址');
}

class FlapLaunchForm {
  FlapLaunchForm({
    required this.nonTax,
    required this.name,
    required this.symbol,
    this.description = '',
    this.socials = const {},
    required this.payment,
    this.external = false,
    this.payWithBnb = false,
    this.buyTaxBps = 0,
    this.sellTaxBps = 0,
    this.marketingBps = 0,
    this.burnBps = 0,
    this.dividendBps = 0,
    this.liquidityBps = 0,
    this.beneficiary,
    this.vault,
    this.dividendToken,
    BigInt? vaultGasBudget,
    this.antiFarmerDays = 30,
    BigInt? minimumShare,
    required this.image,
    BigInt? tip,
  }) : minimumShare = minimumShare ?? BigInt.zero,
       vaultGasBudget = vaultGasBudget ?? BigInt.zero,
       tip = tip ?? BigInt.zero;

  /// The deployed BSC Portal uses V7 for non-tax tokens and V6 for taxed tokens.
  final bool nonTax;
  final String name;
  final String symbol;
  final String description;

  /// telegram / twitter / github / youtube / debox / website.
  final Map<String, String> socials;
  final FlapPayment payment;
  final bool external;
  final bool payWithBnb;
  final int buyTaxBps;
  final int sellTaxBps;
  final int marketingBps;
  final int burnBps;
  final int dividendBps;
  final int liquidityBps;

  int get tokenVersion => nonTax ? 7 : 6;

  FlapVaultLaunchContext vaultContext(String creator) => FlapVaultLaunchContext(
    creator: creator,
    quoteToken: payment.address,
    tokenVersion: tokenVersion,
    buyTaxBps: nonTax ? 0 : buyTaxBps,
    sellTaxBps: nonTax ? 0 : sellTaxBps,
    vaultBps: nonTax ? 10000 : marketingBps,
    burnBps: nonTax ? 0 : burnBps,
    dividendBps: nonTax ? 0 : dividendBps,
    liquidityBps: nonTax ? 0 : liquidityBps,
    dividendToken: nonTax ? zeroAddress : dividendToken ?? payment.address,
    minimumShare: nonTax ? BigInt.zero : minimumShare,
    migratorType: nonTax ? 3 : 1,
  );

  /// Empty means the creator's wallet. Used only by the tax-token branch.
  final String? beneficiary;
  final FlapVaultSelection? vault;

  /// Optional dividend currency (including documented Flap sentinels).
  /// A selected Vault may require a tracker even with zero direct dividend share.
  final String? dividendToken;

  /// Maximum extra BNB prepayment explicitly shown in the user's confirmation.
  final BigInt vaultGasBudget;
  final int antiFarmerDays;

  /// Token base units (18 decimals): dividend eligibility (tax) or holder income minimum (non-tax).
  final BigInt minimumShare;
  final LaunchImage image;
  final BigInt tip;

  void validate() {
    if (name.trim().isEmpty || name.trim().length > 64) {
      throw const FormatException('代币名称必须为 1 至 64 个字符');
    }
    if (symbol.trim().isEmpty) throw const FormatException('请输入代币简写');
    if (image.bytes.isEmpty || image.bytes.length > 10_000_000) {
      throw const FormatException('请选择不超过 10 MB 的代币图片');
    }
    if (!payment.available) throw StateError('所选支付币暂不可用');
    if (antiFarmerDays < 0 || antiFarmerDays > 365) {
      throw const FormatException('防挖提卖保护期必须位于 0 至 365 天');
    }
    if (vaultGasBudget.isNegative ||
        (vault == null && vaultGasBudget != BigInt.zero)) {
      throw const FormatException('金库预付款无效，请重新确认');
    }
    if (dividendToken != null && !isAddress(dividendToken!)) {
      throw const FormatException('分红代币地址无效');
    }
    if (vault != null) {
      if (nonTax) {
        if (!payment.native)
          throw const FormatException('Flap V7 金库仅支持 BNB 底池');
        if (!isFlapV7GiftFactory(vault!.factory)) {
          throw const FormatException('Flap V7 仅接受官方指定的礼物金库 Factory');
        }
      } else if (marketingBps <= 0) {
        throw const FormatException('启用金库时，金库税收分配必须大于 0');
      }
      if (beneficiary?.trim().isNotEmpty == true) {
        throw const FormatException('金库收益由金库接收，请清空创作者收款地址');
      }
      vault!.encode();
    }
    if (nonTax) {
      if (vault == null && minimumShare < flapMinDividendShare) {
        throw const FormatException('持有人收益最低持仓不能低于 10,000 枚代币');
      }
      return;
    }
    final recipient = beneficiary?.trim() ?? '';
    if (recipient.isNotEmpty &&
        (!isAddress(recipient) || recipient.toLowerCase() == zeroAddress)) {
      throw const FormatException('请输入有效且非零的税收接收地址，留空使用 Dev');
    }
    for (final v in [buyTaxBps, sellTaxBps]) {
      if (v != 0 && (v < 100 || v > 1000)) {
        throw const FormatException('Flap 买卖税分别只能为 0 或 1% 至 10%');
      }
    }
    if (buyTaxBps == 0 && sellTaxBps == 0) {
      throw const FormatException('税币的买卖税不能同时为 0，请选择无税币模式');
    }
    if ([
      marketingBps,
      burnBps,
      dividendBps,
      liquidityBps,
    ].any((value) => value < 0 || value > 10000)) {
      throw const FormatException('每项税收分配必须位于 0 至 100%');
    }
    if (marketingBps + burnBps + dividendBps + liquidityBps != 10000) {
      throw const FormatException('Flap 要求四项税收分配合计正好为 100%');
    }
    if (dividendBps > 0 && minimumShare < flapMinDividendShare) {
      throw const FormatException('启用分红时，最低持仓不能低于 10,000 枚代币');
    }
  }
}

final _portalQuoteConfig = AbiFunction.parse(
  'getQuoteTokenConfiguration(address) returns ((uint8,uint8,uint8,uint8,uint8))',
);
final _portalCreationDisabled = AbiFunction.parse(
  'quoteTokenCreationDisabled(address) returns (bool)',
);
final _vaultImpl = AbiFunction.parse('TOKEN_IMPL_TAXED_V3() returns (address)');
final _vaultNonTaxImpl = AbiFunction.parse('TOKEN_IMPL_V3() returns (address)');
final _flapV6 = AbiFunction.parse(
  'newTokenV6((string,string,string,uint8,bytes32,uint8,address,uint256,address,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8))',
);
final _flapV7 = AbiFunction.parse(
  'newTokenV7((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint16,uint16,uint64,uint64,address,uint8,(uint8,uint16,address,address,uint256)[4]))',
);
final flapV6WithVault = AbiFunction.parse(
  'newTokenV6WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8,address,bytes)) returns (address)',
);

final flapV7WithVault = AbiFunction.parse(
  'newTokenV7WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint64,uint16,uint16,uint64,address,(uint8,uint16,address,address,uint256)[4],address,bytes)) returns (address)',
);

/// Encode the deployed VaultPortal tuple for the selected token version.
Uint8List encodeFlapVaultCreation(
  FlapLaunchForm form, {
  required String cid,
  required Uint8List salt,
  required String extensionId,
  required Uint8List extensionData,
  String? creator,
  BigInt? purchase,
}) {
  final vault = form.vault ?? (throw StateError('尚未选择金库'));
  if (form.nonTax) {
    form.validate();
    if (creator == null ||
        !isAddress(creator) ||
        creator.toLowerCase() == zeroAddress) {
      throw const FormatException('V7 金库需要有效的创建者地址');
    }
    final none = [0, 0, zeroAddress, zeroAddress, BigInt.zero];
    // VaultPortal has its own tuple order. It replaces the slot recipient with
    // the newly created vault before forwarding the call to Portal.
    return flapV7WithVault.encode([
      [
        form.name.trim(),
        form.symbol.trim(),
        cid,
        1,
        salt,
        3,
        form.payment.address,
        purchase ?? BigInt.zero,
        Uint8List(0),
        hexToBytes(extensionId),
        extensionData,
        7,
        0,
        BigInt.from(form.antiFarmerDays * 86400),
        0,
        0,
        BigInt.zero,
        zeroAddress,
        [
          [1, 10000, checksumAddress(creator), zeroAddress, BigInt.zero],
          none,
          none,
          none,
        ],
        vault.factory,
        vault.encode(),
      ],
    ]);
  }
  return flapV6WithVault.encode([
    [
      form.name.trim(),
      form.symbol.trim(),
      cid,
      1,
      salt,
      1,
      form.payment.address,
      purchase ?? BigInt.zero,
      Uint8List(0),
      hexToBytes(extensionId),
      extensionData,
      0,
      0,
      form.buyTaxBps,
      form.sellTaxBps,
      flapTaxDuration,
      BigInt.from(form.antiFarmerDays * 86400),
      form.marketingBps,
      form.burnBps,
      form.dividendBps,
      form.liquidityBps,
      form.minimumShare,
      form.dividendToken ?? form.payment.address,
      zeroAddress,
      6,
      vault.factory,
      vault.encode(),
    ],
  ]);
}

/// Signed-curve extension (custom or not-yet-enabled pool tokens), web encodeFlapCurveExtension.
(String, Uint8List) flapCurveExtension(
  Map<String, dynamic> auth,
  String quote,
) {
  if (auth['allowed'] != true) throw StateError('Flap 尚未批准该自定义底池代币');
  if ('${auth['quote_token']}'.toLowerCase() != quote.toLowerCase()) {
    throw StateError('Flap 曲线授权与本次发币参数不一致');
  }
  final deadline = (auth['deadline'] as num).toInt();
  if (deadline <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10) {
    throw StateError('Flap 曲线授权已过期，请重新核对');
  }
  final price = BigInt.parse('${auth['price']}');
  final sig = hexToBytes('${auth['signature']}');
  if (auth['protocol'] == 'v2') {
    return (
      flapSignedCurveV2,
      encodeSequence(
        [
          AbiType.parse('uint256'),
          AbiType.parse('uint256'),
          AbiType.parse('bytes'),
        ],
        [price, BigInt.from(deadline), sig],
      ),
    );
  }
  return (
    flapSignedCurveV1,
    encodeSequence(
      [
        AbiType.parse('uint8'),
        AbiType.parse('uint256'),
        AbiType.parse('uint256'),
        AbiType.parse('bytes'),
      ],
      [(auth['curve_type'] as num).toInt(), price, BigInt.from(deadline), sig],
    ),
  );
}

/// Simulate Flap Portal creation and any confirmed Vault prepayment together.
class FlapLauncher extends Launcher {
  FlapLauncher(
    super.api,
    super.log, {
    super.sleep,
    super.pollEvery,
    this.random,
  }) : super(label: 'Flap', transactionLimit: _fourFlapBundleLimit);
  final Random? random;

  @override
  Future<bool> settle(List<LaunchTx> txs) async {
    if (!await super.settle(txs)) return false;
    for (final tx in txs.whereType<_FlapBuyTx>().where((tx) => tx.migration)) {
      final receipt = tx.receipt!;
      final token = tx.purchasedToken!,
          height = receipt['blockNumber'] as String;
      try {
        final state =
            _flapState
                    .decodeOutput(
                      await api.call(
                        flapPortal,
                        bytesToHex(_flapState.encode([token])),
                        block: height,
                      ),
                    )
                    .single
                as List;
        final pool = state[14].toString().toLowerCase();
        if (state[0] != BigInt.from(4) ||
            !_flapPoolMatches(receipt, token, tx.quote, pool) ||
            state[9].toString().toLowerCase() != tx.quote.toLowerCase() ||
            state[4] != BigInt.from(tx.version)) {
          tx.protocolError = '迁移区块的官方阶段、版本、底池或付款币与发币计划不同';
        } else {
          final code = (await api.rpc([
            ('eth_getCode', [pool, height]),
          ])).single;
          if (code == '0x') {
            tx.protocolError = '迁移区块中的外盘池没有合约代码';
          } else if (code is! String ||
              !RegExp(r'^0x(?:[0-9a-fA-F]{2})+$').hasMatch(code)) {
            throw const FormatException('外盘池代码读取结果无效');
          }
        }
        if (tx.protocolError != null) {
          tx.status = 'protocol_unproven';
          return false;
        }
      } on Object {
        tx.status = 'unknown';
        return false;
      }
    }
    return true;
  }

  Future<List<FlapPayment>> catalog() async =>
      (await catalogSnapshot(custom: false)).tokens;

  Future<({BigInt gross, BigInt block})> previewTarget(
    FlapPayment asset,
    int version,
    BigInt buyTaxBps,
  ) async {
    final result = await api.flap({
      'action': 'creationCurve',
      'quoteToken': asset.address,
      'tokenVersion': '$version',
    });
    if (result is! Map || result['tokenVersion'] != version)
      throw StateError('Flap 未返回当前版本的曲线');
    BigInt raw(String key) =>
        BigInt.tryParse('${result[key]}') ??
        (throw StateError('Flap 曲线缺少 $key'));
    return (
      gross: flapCurveGross(
        r: formatUnits(raw('r'), 18, maxFraction: 18),
        h: formatUnits(raw('h'), 18, maxFraction: 18),
        k: formatUnits(raw('k'), 18, maxFraction: 18),
        quoteDecimals: asset.decimals,
        platformBuyFeeBps: raw('bondingCurveFeeRate'),
        buyTaxBps: buyTaxBps,
        tokenTargetUnits: raw('dexSupplyThresh'),
      ),
      block: raw('blockNumber'),
    );
  }

  Future<FlapCatalogSnapshot> catalogSnapshot({required bool custom}) async {
    final body = await api.flap(custom ? {'action': 'customCatalog'} : null);
    if (body is! Map || body['tokens'] is! List)
      throw StateError('Flap 底池目录返回无效');
    return (
      tokens: [
        for (final row in (body['tokens'] as List).whereType<Map>())
          FlapPayment({
            ...row.cast<String, dynamic>(),
            if (custom) 'category': 'custom',
          }),
      ],
      partial: body['partial'] == true,
      stale: body['stale'] == true,
      refreshError: body['refreshError']?.toString(),
    );
  }

  Future<String> _uploadMeta(FlapLaunchForm form, TradeWallet dev) async {
    final payload = await api.flapUpload(form.image, {
      'creator': dev.address,
      'description': form.description.trim(),
      for (final f in [
        'telegram',
        'twitter',
        'github',
        'youtube',
        'debox',
        'website',
      ])
        f: (form.socials[f] ?? '').trim(),
    });
    final cid = payload is Map ? '${payload['cid'] ?? ''}' : '';
    if (!RegExp(r'^b[a-z2-7]{20,}$').hasMatch(cid)) {
      throw StateError('Flap 上传未返回有效 CID');
    }
    return cid;
  }

  Future<void> launch(
    FlapLaunchForm form, {
    required LaunchBuyer dev,
    List<LaunchBuyer> internal = const [],
    List<LaunchBuyer> external = const [],
    String? metaOverride,
  }) => guard(() async {
    step('1/9 校验参数');
    form.validate();
    validateLaunchPurchases(dev, internal, external, migrate: form.external);
    if (internal.length + external.length > 100) {
      throw const FormatException('Flap 内外盘额外买家合计最多 100 个');
    }
    if (form.external && (internal.isEmpty || external.isEmpty)) {
      throw const FormatException('Flap 内外盘模式至少各需一个买家');
    }
    final multiple = internal.isNotEmpty || external.isNotEmpty;
    final q = form.payment;
    final bnbForPool = form.payWithBnb && !q.native;
    final separateDev = (multiple || bnbForPool) && !q.native && dev.amount > BigInt.zero;
    final vault = form.vault;
    FlapVaultLaunchContext? vaultContext;
    var vaultGasPrepayment = BigInt.zero;
    if (vault != null) {
      step('核对金库格式、权限与发行条件');
      final context = form.vaultContext(dev.wallet.address);
      vaultContext = context;
      validateFlapCuratedLaunch(vault, context, quoteSymbol: q.symbol);
      final validations = await Future.wait<Object?>([
        FlapVaultService(api).revalidate(vault, context),
        validateFlapCuratedReadiness(api, vault, context),
        flapVaultGasDeficit(
          api,
          factory: vault.factory,
          creator: dev.wallet.address,
          quoteToken: q.address,
        ),
      ]);
      final validation = validations[0]! as FlapVaultValidation;
      for (final warning in validation.warnings) {
        log.add('金库：$warning');
      }
      vaultGasPrepayment = validations[2]! as BigInt;
      if (vaultGasPrepayment > form.vaultGasBudget) {
        throw StateError('金库所需 BNB 预付款已变化，请重新核对并确认金额');
      }
    }
    final config =
        (_portalQuoteConfig
                .decodeOutput(
                  await api.call(
                    flapPortal,
                    bytesToHex(_portalQuoteConfig.encode([q.address])),
                  ),
                )
                .single!
            as List);
    if (_portalCreationDisabled
            .decodeOutput(
              await api.call(
                flapPortal,
                bytesToHex(_portalCreationDisabled.encode([q.address])),
              ),
            )
            .single ==
        true) {
      throw StateError('所选支付币已被 Flap Portal 禁用创建');
    }
    final portalConverts = bnbForPool && (config[3] as BigInt) > BigInt.zero;
    final convertPayments = bnbForPool && !portalConverts;
    _checkFourFlapLaunchSize(
      purchases: internal.length + external.length + (separateDev ? 1 : 0),
      convertEachPurchase: convertPayments,
      hasTip: form.tip > BigInt.zero,
      prepayVault: vaultGasPrepayment > BigInt.zero,
    );
    final funding = await LaunchFunding.prepare(api, q.address, [dev, ...internal, ...external],
        convert: convertPayments);
    if (funding.converted) {
      dev = funding.units(dev);
      internal = internal.map(funding.units).toList();
      external = external.map(funding.units).toList();
    }
    final needsSignedCurve =
        q.category == 'custom' || (config[0] as BigInt).toInt() != 1;
    if (multiple && !q.native) {
      final decimals = AbiFunction.parse('decimals() returns (uint8)');
      final precision = decimals
          .decodeOutput(
            await api.call(q.address, bytesToHex(decimals.encode([]))),
          )
          .single;
      if (precision != BigInt.from(q.decimals))
        throw StateError('Flap 底池币链上精度与配置不同');
    }
    if (multiple &&
        !portalConverts &&
        !form.nonTax &&
        !needsSignedCurve &&
        q.r.isNotEmpty &&
        q.k.isNotEmpty) {
      final rate = AbiFunction.parse('getFeeRate() returns (uint256,uint256)');
      final fee =
          rate
                  .decodeOutput(
                    await api.call(flapPortal, bytesToHex(rate.encode([]))),
                  )
                  .first
              as BigInt;
      validateFlapPlan(
        external: form.external,
        dev: dev.amount,
        internal: internal.map((b) => b.amount).toList(),
        curveGross: flapCurveGross(
          r: q.r,
          h: q.h,
          k: q.k,
          quoteDecimals: q.decimals,
          platformBuyFeeBps: fee,
          buyTaxBps: BigInt.from(form.buyTaxBps),
        ),
      );
    }
    step('2/9 上传代币资料');
    final cid = metaOverride ?? await _uploadMeta(form, dev.wallet);

    step('3/9 生成并核对代币地址');
    final implementationCall = form.nonTax ? _vaultNonTaxImpl : _vaultImpl;
    late String implementation;
    try {
      final c =
          '${implementationCall.decodeOutput(await api.call(flapVaultPortal, bytesToHex(implementationCall.encode([])))).single}';
      if (!isAddress(c) || c.toLowerCase() == zeroAddress) {
        throw StateError('实现地址无效');
      }
      final code = (await api.rpc([
        ('eth_getCode', [c, 'latest']),
      ])).single;
      if (code is! String ||
          !RegExp(r'^0x(?:[0-9a-fA-F]{2})+$').hasMatch(code)) {
        throw StateError('实现合约代码不可用');
      }
      implementation = checksumAddress(c);
    } on Object {
      throw StateError('Flap 当前代币实现读取失败，已停止发币准备，请重试');
    }
    Future<bool> unused(String a) async =>
        '${(await api.rpc([
          ('eth_getCode', [a, 'latest']),
        ])).single}' ==
        '0x';
    final (salt, token) = await findFlapSalt(
      implementation,
      form.nonTax ? '8888' : '7777',
      unused,
      random: random,
    );

    var extensionId = '0x${'00' * 32}';
    var extensionData = Uint8List(0);
    if (needsSignedCurve) {
      step('4/9 读取 Flap 创建许可');
      final auth = await api.flap({
        'action': 'curveSignature',
        'quoteToken': q.address,
        'salt': bytesToHex(salt),
        'tokenVersion': form.nonTax ? '7' : '6',
      });
      if (auth is! Map) throw StateError('Flap 曲线授权格式无效');
      final (id, data) = flapCurveExtension(
        auth.cast<String, dynamic>(),
        q.address,
      );
      extensionId = id;
      extensionData = data;
    }
    step('5/9 准备创建参数');
    final createQuote = separateDev ? BigInt.zero : dev.amount;
    final createValue = q.native ? createQuote : BigInt.zero;
    if (!q.native && createQuote > BigInt.zero) {
      await authorizeLaunchPayment(
        q.address,
        vault == null ? flapPortal : flapVaultPortal,
        dev.wallet,
        createQuote,
      );
    }
    final buys = <_FlapBuy>[
      if (separateDev) _FlapBuy(dev, 'Dev 首买', 3000000),
      for (var i = 0; i < internal.length; i++)
        _FlapBuy(
          internal[i],
          '内盘首买 ${i + 1}',
          form.external && i == internal.length - 1 ? 8000000 : 3000000,
          migration: form.external && i == internal.length - 1,
        ),
      for (var i = 0; i < external.length; i++)
        _FlapBuy(external[i], '外盘首买 ${i + 1}', 5000000),
    ];
    if (!q.native && !portalConverts && buys.isNotEmpty) {
      await authorizeLaunchPayments(q.address, flapPortal, [
        for (final buy in buys) buy.buyer,
      ], fundedInBundle: funding.converted);
    }
    await funding.executable(api);
    final Uint8List createData;
    if (vault != null) {
      createData = encodeFlapVaultCreation(
        form,
        cid: cid,
        salt: salt,
        extensionId: extensionId,
        extensionData: extensionData,
        creator: dev.wallet.address,
        purchase: createQuote,
      );
    } else if (form.nonTax) {
      final none = [0, 0, zeroAddress, zeroAddress, BigInt.zero];
      createData = _flapV7.encode([
        [
          form.name.trim(),
          form.symbol.trim(),
          cid,
          1,
          salt,
          3,
          q.address,
          createQuote,
          Uint8List(0),
          hexToBytes(extensionId),
          extensionData,
          0,
          0,
          0,
          BigInt.zero,
          BigInt.from(form.antiFarmerDays * 86400),
          zeroAddress,
          7,
          [
            [2, 10000, zeroAddress, q.address, form.minimumShare],
            none,
            none,
            none,
          ],
        ],
      ]);
    } else {
      createData = _flapV6.encode([
        [
          form.name.trim(),
          form.symbol.trim(),
          cid,
          1,
          salt,
          1,
          q.address,
          createQuote,
          form.beneficiary?.trim().isNotEmpty == true
              ? checksumAddress(form.beneficiary!.trim())
              : dev.wallet.address,
          Uint8List(0),
          hexToBytes(extensionId),
          extensionData,
          0,
          0,
          form.buyTaxBps,
          form.sellTaxBps,
          flapTaxDuration,
          BigInt.from(form.antiFarmerDays * 86400),
          form.marketingBps,
          form.burnBps,
          form.dividendBps,
          form.liquidityBps,
          form.dividendBps == 0 ? BigInt.zero : form.minimumShare,
          form.dividendToken ?? q.address,
          zeroAddress,
          6,
        ],
      ]);
    }
    if (vault != null) {
      // Upload and vanity search can take time. The final
      // simulation must use the same schema the user confirmed, checked again now.
      final fresh = await Future.wait<Object?>([
        FlapVaultService(api).revalidate(vault, vaultContext!),
        flapVaultGasDeficit(
          api,
          factory: vault.factory,
          creator: dev.wallet.address,
          quoteToken: q.address,
        ),
      ]);
      vaultGasPrepayment = fresh[1]! as BigInt;
      if (vaultGasPrepayment > form.vaultGasBudget) {
        throw StateError('金库所需 BNB 预付款已变化，请重新核对并确认金额');
      }
    }
    final txs = <LaunchTx>[
      if (vaultGasPrepayment > BigInt.zero)
        LaunchTx(
          '金库 BNB 预付款',
          dev.wallet,
          vault!.factory,
          AbiFunction.parse('prepayGas()').encode([]),
          vaultGasPrepayment,
          500000,
          kind: 'vaultPrepayment',
        ),
      LaunchTx(
        'newTokenV${form.tokenVersion}${vault == null ? '' : 'WithVault'}',
        dev.wallet,
        vault != null ? flapVaultPortal : flapPortal,
        createData,
        createValue,
        8000000,
        kind: 'create',
        creationFee: BigInt.zero,
        purchasedToken: createQuote > BigInt.zero ? token : null,
        protocolCheck: (multiple || separateDev)
            ? (r) => _flapMigrationProblem(r, token, expected: false)
            : null,
      ),
      for (final buy in buys) buy.tx(q, token, BigInt.one, form.tokenVersion, nativeInput: portalConverts),
      if (form.tip > BigInt.zero)
        LaunchTx(
          '贿赂费',
          dev.wallet,
          bscBundleTipRecipient,
          Uint8List(0),
          form.tip,
          100000,
          kind: 'tip',
        ),
    ];
    step('6/9 连续预检与钱包余额');
    await simulateBundle(
      funding.include(txs),
      requireSuccess: true,
      expectedCreatedToken: vault != null || multiple || separateDev ? token : null,
    );
    if (buys.isNotEmpty) {
      final firstBuy = txs.indexWhere((tx) => tx is _FlapBuyTx);
      for (var i = 0; i < buys.length; i++) {
        final floor = txs[firstBuy + i].simulatedDelivery!;
        txs[firstBuy + i] = buys[i].tx(q, token, floor, form.tokenVersion, nativeInput: portalConverts);
      }
      await simulateBundle(
        funding.include(txs),
        requireSuccess: true,
        expectedCreatedToken: token,
      );
    }
    final signedOrder = funding.include(txs);
    final gas = await launchBundleGas(api);
    final nonceMap = await checkBalances(
      signedOrder,
      gas.gasPrice,
      extra: {dev.wallet.address.toLowerCase(): form.tip},
      reserveGas: 5150000,
    );
    if (!await unused(token)) throw StateError('预测 CA 在签名期间已被占用');
    step('7/9 本地签名并提交');
    await launchBundle(
      signedOrder,
      nonceMap,
      gas.gasPrice,
      LaunchSession(
        platform: 'flap',
        poolToken: q.native ? zeroAddress : q.address,
        token: token,
        symbol: form.symbol.trim(),
        dev: dev.wallet,
        wallets: [
          dev.wallet,
          ...internal.map((b) => b.wallet),
          ...external.map((b) => b.wallet),
        ],
        tip: form.tip,
        reserved: form.tip + BigInt.from(5150000) * gas.gasPrice,
      ),
    );
  });
}

/// Salt helper for tests and previews.
Uint8List saltFromInt(int v) => toBytes32(BigInt.from(v));
BigInt saltToInt(Uint8List s) => bytesToBigInt(s);
