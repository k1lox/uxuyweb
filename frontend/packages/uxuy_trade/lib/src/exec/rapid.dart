part of 'executor.dart';

enum RapidDirection { buy, sell, both }

/// Immutable settings pinned to the token and participating wallets at check time.
class RapidPlan {
  const RapidPlan({
    required this.token,
    this.market,
    required this.wallets,
    required this.direction,
    required this.buyAmount,
    required this.percentSell,
    required this.sellValue,
    required this.interval,
    required this.total,
    required this.minNative,
    required this.minToken,
    required this.impactLimit,
  });

  final String token;
  final Market? market;
  final List<TradeWallet> wallets;
  final RapidDirection direction;
  final BigInt buyAmount, sellValue, minNative, minToken;
  final bool percentSell;
  final Duration interval;
  final int total;
  final double impactLimit;

  (int, bool) at(int position) => (
    (direction == RapidDirection.both ? position ~/ 2 : position) %
        wallets.length,
    direction == RapidDirection.buy ||
        direction == RapidDirection.both && position.isEven,
  );

  static RapidPlan parse({
    required String token,
    required int decimals,
    Market? market,
    required List<TradeWallet> wallets,
    required RapidDirection direction,
    required String buyAmount,
    required bool percentSell,
    required String sellAmount,
    required String sellPercent,
    required String interval,
    required String total,
    required String minNative,
    required String minToken,
    required double impactLimit,
  }) {
    if (wallets.isEmpty || wallets.length > 200)
      throw StateError('快速组需选择 1–200 个钱包');
    final count = int.tryParse(total.trim());
    if (count == null || count < 1 || count > 10000)
      throw StateError('交易总数须在 1–10,000 笔之间');
    if (!RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(interval.trim()))
      throw StateError('间隔支持最多三位小数');
    final ms = parseUnits(interval, 3);
    if (ms > BigInt.from(86400000)) throw StateError('间隔须在 0–86,400 秒之间');
    final hasSell =
        direction != RapidDirection.buy &&
        (direction != RapidDirection.both || count > 1);
    final sell = !hasSell
        ? BigInt.zero
        : parseUnits(
            percentSell ? sellPercent : sellAmount,
            percentSell ? 2 : decimals,
          );
    if (hasSell &&
        (sell == BigInt.zero &&
                (!percentSell || direction == RapidDirection.sell) ||
            percentSell && sell > BigInt.from(10000)))
      throw StateError('卖出数量或比例无效');
    final buy = direction == RapidDirection.sell
        ? BigInt.zero
        : parseUnits(buyAmount, 18);
    if (direction != RapidDirection.sell && buy == BigInt.zero)
      throw StateError('每笔买入须大于 0');
    final effective = direction == RapidDirection.both && sell == BigInt.zero
        ? RapidDirection.buy
        : direction;
    final used = effective == RapidDirection.both ? (count + 1) ~/ 2 : count;
    return RapidPlan(
      token: token,
      market: market,
      wallets: List.unmodifiable(wallets.take(used)),
      direction: effective,
      buyAmount: buy,
      percentSell: percentSell,
      sellValue: sell,
      interval: Duration(milliseconds: ms.toInt()),
      total: count,
      minNative: parseUnits(minNative.trim().isEmpty ? '0' : minNative, 18),
      minToken: parseUnits(minToken.trim().isEmpty ? '0' : minToken, decimals),
      impactLimit: impactLimit,
    );
  }

  String get fingerprint => [
    token.toLowerCase(),
    direction,
    buyAmount,
    percentSell,
    sellValue,
    interval.inMilliseconds,
    total,
    minNative,
    minToken,
    impactLimit,
    ...wallets.map((w) => w.address.toLowerCase()),
  ].join('|');

  BigInt sellFrom(BigInt balance) {
    final units = percentSell
        ? balance * sellValue ~/ BigInt.from(10000)
        : sellValue;
    return market?.sellUnits(units) ?? units;
  }

  String? threshold(WalletState row) {
    if (row.native < minNative) return '${row.wallet} BNB 余额低于停止线';
    if (minToken > BigInt.zero && row.tokenBalance == null)
      throw StateError('代币余额读取不完整');
    if ((row.tokenBalance ?? BigInt.zero) < minToken)
      return '${row.wallet} 代币余额低于停止线';
    return null;
  }
}

class RapidPrepared {
  RapidPrepared(
    this.plan,
    this.spender,
    this.gasPrice,
    this.gasLimits,
    this.maximumGasCost,
    this.remainingCount,
  ) : createdAt = DateTime.now();
  final RapidPlan plan;
  final String spender;
  final DateTime createdAt;
  final BigInt gasPrice, maximumGasCost;
  final Map<(String, bool), int> gasLimits;
  final int remainingCount;
  bool _used = false;
}

extension RapidExecution on BatchTrader {
  Map<String, WalletState> _rapidRows(
    List<WalletState> rows,
    Iterable<String> owners,
  ) {
    final byOwner = {for (final r in rows) r.wallet.toLowerCase(): r};
    if (owners.any((a) => byOwner[a.toLowerCase()]?.tokenBalance == null))
      throw StateError('钱包余额读取不完整');
    return byOwner;
  }

  Future<RapidPrepared> prepareRapid(
    RapidPlan plan,
    bool Function() active,
  ) async {
    if (running || unresolved.isNotEmpty) throw StateError('请先核实本组原交易');
    void check() {
      if (!active()) throw StateError('已取消本次检查');
    }

    final config = await api.config();
    _configureRoute(config, plan.market, plan.token);
    check();
    final spender = _approvalSpender!;
    final head = await api.gas();
    check();
    if (head.gasPrice <= BigInt.zero ||
        head.gasPrice > BigInt.from(100000000000)) {
      throw StateError('BSC 网络费单价异常，请重新检查');
    }
    final owners = plan.wallets.map((w) => w.address).toList();
    await api.requireIdleRapidWallets(owners);
    check();
    final rows = _rapidRows(
      await api.refreshWalletStates(
        owners,
        token: plan.token,
        spender: spender,
      ),
      owners,
    );
    check();
    if (_rapidFingerprint != plan.fingerprint) {
      _rapidSubmitted.clear();
      _rapidFingerprint = plan.fingerprint;
    }
    final futureLegs = List.generate(owners.length, (_) => <bool>[]);
    final buys = List.filled(owners.length, 0),
        sells = List.filled(owners.length, 0);
    for (var i = 0; i < plan.total; i++) {
      if (_rapidSubmitted.contains(i)) continue;
      final (index, buy) = plan.at(i);
      futureLegs[index].add(buy);
      if (buy) {
        buys[index]++;
      } else {
        sells[index]++;
      }
    }
    final approvals = <String, BigInt>{};
    final grants = RouteGrants();
    final gasLimits = <(String, bool), int>{};
    Future<RoutePlan> simulate(String owner, bool buy, BigInt amount) async {
      final req = RouteRequestData(
        wallet: owner,
        token: plan.token,
        market: plan.market,
        buy: buy,
        amount: amount,
        maxImpactPercent: plan.impactLimit,
      );
      final quote = await api.route(req);
      check();
      _matchRoute(req, quote);
      gasLimits[(owner.toLowerCase(), buy)] = quote.gasLimit;
      _checkImpact(adverseRouteImpact(quote), plan.impactLimit);
      return quote;
    }

    Future<void> prepareWallet(int i) async {
      check();
      final legs = futureLegs[i];
      if (legs.isEmpty) return;
      final owner = owners[i], key = owner.toLowerCase(), row = rows[key]!;
      final reason = plan.threshold(row);
      if (reason != null) throw StateError(reason);
      var balance = row.tokenBalance!, credit = BigInt.zero;
      var probeSellGrants = <RouteApproval>[], probeSellInput = BigInt.one;
      if (buys[i] > 0 && row.native <= plan.buyAmount) {
        throw StateError('$owner BNB 不足以支付首笔买入和网络费');
      }
      if (buys[i] > 0 && sells[i] > 0 && legs.first) {
        final probe = await api.checkRapidRoundTrip(
          RouteRequestData(
            wallet: owner,
            token: plan.token,
            market: plan.market,
            buy: true,
            amount: plan.buyAmount,
            maxImpactPercent: plan.impactLimit,
          ),
          plan.sellValue,
          plan.percentSell,buyOrders:buys[i],sellOrders:sells[i],
        );
        check();
        if (probe.before != balance) throw StateError('快速组持仓已变化，请重新检查');
        credit = probe.received;
        // Sell-side requirements are scaled below using the projected sum of
        // debits, including the diminishing tail of percentage sales.
        for (final a in probe.buyApprovals) {
          grants.add(
            owner,
            RouteApproval.fromJson(a),
            BigInt.from(buys[i]),
            BigInt.one,
          );
        }
        probeSellGrants = [
          for (final a in probe.sellApprovals) RouteApproval.fromJson(a),
        ];
        probeSellInput = probe.sellAmount;
        gasLimits[(key, true)] = probe.buyGas;
        gasLimits[(key, false)] = probe.sellGas;
      } else {
        if (buys[i] > 0) {
          final quote = await simulate(owner, true, plan.buyAmount);
          credit = quote.quoteOut;
          for (final grant in quote.approvals) {
            grants.add(owner, grant, BigInt.from(buys[i]), BigInt.one);
          }
        }
        if (sells[i] > 0) {
          probeSellInput = plan.sellFrom(balance);
          if (probeSellInput <= BigInt.zero) {
            final reason = balance == BigInt.zero ? '没有可卖的代币' : '卖量低于最小交易单位';
            throw StateError('$owner $reason');
          }
          final quote = await simulate(owner, false, probeSellInput);
          probeSellGrants = quote.approvals;
        }
      }
      var planned = BigInt.zero;
      for (final buy in legs) {
        if (buy) {
          balance += credit;
        } else {
          final amount = plan.sellFrom(balance);
          if (amount <= BigInt.zero || amount > balance) {
            // Future fills may differ. Only fixed unfunded sales and an
            // unexecutable first leg make the whole check invalid.
            if (planned == BigInt.zero || !plan.percentSell) {
              throw StateError('$owner 卖出数量超过可用持仓或低于最小单位');
            }
            continue;
          }
          balance -= amount;
          planned += amount;
        }
      }
      if (planned > BigInt.zero) {
        approvals[key] = planned;
        for (final a in probeSellGrants) {
          grants.add(owner, a, planned, probeSellInput,scheduledOrders:sells[i]);
        }
      }
    }

    for (var i = 0; i < owners.length; i += 8) {
      await Future.wait([
        for (var j = i; j < min(i + 8, owners.length); j++) prepareWallet(j),
      ]);
    }
    check();
    final approvalBudgets = {
      for (final e in grants.amounts.entries) e.key: Map.of(e.value),
    };
    final primary = approvalBudgets.putIfAbsent((
      plan.token.toLowerCase(),
      spender.toLowerCase(),
    ), () => <String, BigInt>{});
    for (final e in approvals.entries) {
      if ((primary[e.key] ?? BigInt.zero) < e.value) primary[e.key] = e.value;
    }
    final approvalGas = <String, int>{};
    for (final e in approvalBudgets.entries) {
      if (e.value.isEmpty) continue;
      final balances =
          e.key == (plan.token.toLowerCase(), spender.toLowerCase())
          ? rows.values
          : await api.refreshWalletStates(
              e.value.keys.toList(),
              token: e.key.$1,
              spender: e.key.$2,
            );
      final allowance = {
        for (final r in balances) r.wallet.toLowerCase(): r.routerAllowance,
      };
      for (final entry in e.value.entries) {
        final held = allowance[entry.key];
        if (held == null) throw StateError('无法核实待授权钱包的额度');
        if (held < entry.value) {
          approvalGas[entry.key] =
              (approvalGas[entry.key] ?? 0) +
              ((held == BigInt.zero ? 1 : 2) * _approvalGas);
        }
      }
    }
    for (var i = 0; i < owners.length; i++) {
      final owner = owners[i].toLowerCase();
      final principal = buys[i] > 0 ? plan.buyAmount : BigInt.zero;
      final gas =
          (gasLimits[(owner, true)] ?? 0) +
          (gasLimits[(owner, false)] ?? 0) +
          (approvalGas[owner] ?? 0);
      if (rows[owner]!.native < principal + BigInt.from(gas) * head.gasPrice) {
        throw StateError('${owners[i]} BNB 不足以支付首笔本金、授权和买卖网络费');
      }
    }
    check();
    if (approvals.isNotEmpty && plan.market?.innerPlatform==null) {
      await prepareSellApprovals(
        token: plan.token,
        market: plan.market,
        wallets: plan.wallets,
        amounts: approvals,
        active: active,
      );
    }
    check();
    await checkRouteGrants(plan.market, plan.wallets, grants, active: active);
    check();
    final funded = _rapidRows(
      await api.refreshWalletStates(
        owners,
        token: plan.token,
        spender: spender,
      ),
      owners,
    );
    check();
    var totalGas = BigInt.zero;
    for (var i = 0; i < owners.length; i++) {
      final owner = owners[i].toLowerCase();
      final buyGas = gasLimits[(owner, true)] ?? 0,
          sellGas = gasLimits[(owner, false)] ?? 0;
      totalGas += BigInt.from(buys[i] * buyGas + sells[i] * sellGas);
      final principal = buys[i] > 0 ? plan.buyAmount : BigInt.zero;
      if (funded[owner]!.native <
          principal + head.gasPrice * BigInt.from(buyGas + sellGas)) {
        throw StateError('${owners[i]} BNB 不足以支付首笔本金和买卖网络费');
      }
    }
    return RapidPrepared(
      plan,
      spender,
      head.gasPrice,
      Map.unmodifiable(gasLimits),
      totalGas * head.gasPrice,
      plan.total - _rapidSubmitted.length,
    );
  }

  Future<TradeOutcome> runRapid(RapidPrepared checked) async {
    if (running || unresolved.isNotEmpty) throw StateError('本组已有待处理交易');
    if (checked._used ||
        checked.plan.fingerprint != _rapidFingerprint ||
        checked.remainingCount != checked.plan.total - _rapidSubmitted.length) {
      throw StateError('快速组检查已使用或进度已变化，请重新检查');
    }
    checked._used = true;
    if (DateTime.now().difference(checked.createdAt) >
        const Duration(minutes: 2))
      throw StateError('快速组检查已超过两分钟，请重新检查');
    final plan = checked.plan,
        owners = plan.wallets.map((w) => w.address).toList();
    final scope = Object(), out = TradeOutcome(), stopWake = Completer<void>();
    running = true;
    _cancel = false;
    last = out;
    _changed();
    void stop(String why) {
      if (out.stopped) return;
      out.stopped = true;
      _log(why, level: LogLevel.error);
      if (!stopWake.isCompleted) stopWake.complete();
      _changed();
    }

    bool withinBalanceLimits(WalletState row) {
      final reason = plan.threshold(row);
      if (reason != null) stop(reason);
      return reason == null;
    }

    void syncStop() {
      if (_cancel || _disposed) stop('快速组已停止后续提交');
    }

    addListener(syncStop);
    var finished = false;
    bool live() => !finished && !_cancel && !_disposed && !out.stopped;
    final outstanding = <Future<void>>{}, signing = <int, Future<void>>{};
    final lastHashes = <int, String>{};
    final nextNonce = <int, int>{};
    final initialNonce = <String, int>{};
    final positions = List.generate(owners.length, (_) => <int>[]);
    for (var i = 0; i < plan.total; i++) {
      if (!_rapidSubmitted.contains(i)) positions[plan.at(i).$1].add(i);
    }
    final cursors = List.filled(owners.length, 0);
    final pipeline = plan.direction == RapidDirection.buy || !plan.percentSell;
    Timer? timer;
    var checking = false;
    Future<void> monitor() async {
      if (checking || !live()) return;
      checking = true;
      try {
        final snapshot = _rapidRows(
          await api.rapidWalletStates(owners, plan.token, checked.spender),
          owners,
        );
        if (!live()) return;
        for (final owner in owners) {
          if (!withinBalanceLimits(snapshot[owner.toLowerCase()]!)) return;
        }
      } catch (e) {
        if (live()) _log('余额监测暂不可用，下次继续检查：$e');
      } finally {
        checking = false;
      }
    }

    Future<bool> waitPrior(int index) async {
      final hash = lastHashes[index];
      if (hash == null || !unresolved.contains(hash)) return true;
      for (var attempt = 0; attempt < 60 && live(); attempt++) {
        final record = await api.status(hash);
        if (record.finished) {
          final batch = _rapidCompound[hash];
          if (batch != null) {
            await _verifyBundle(batch, out, manual: true);
            if (batch.hashes.any(unresolved.contains)) {
              stop('快速组交易的区块或顺序尚未核实，请查询原交易');
              return false;
            }
            _rapidCompound.remove(hash);
            return live();
          }
          if (unresolved.remove(hash)) {
            if (record.status == 'confirmed') {
              out.confirmed++;
            } else {
              out.failed++;
              stop('快速组原交易 ${record.status}：$hash');
            }
          }
          return live();
        }
        await Future.any([_sleep(pollEvery), stopWake.future]);
      }
      if (live()) stop('原交易尚未确认，请查询 $hash');
      return false;
    }

    Future<void> send(
      int index,
      int position,
      bool buy,
      void Function() release,
    ) async {
      final wallet = plan.wallets[index];
      if (!live()) return;
      final previous = lastHashes[index];
      // Percentage and buy-back legs depend on the wallet's preceding result.
      // Independent fixed buys still pipeline immediately.
      final settleFirst =
          previous != null &&
          plan.percentSell &&
          (!buy || plan.direction == RapidDirection.both);
      if (settleFirst && !await waitPrior(index)) return;
      final current = settleFirst
          ? await api.refreshWalletStates(
              [wallet.address],
              token: plan.token,
              spender: checked.spender,
            )
          : await api.rapidWalletStates(
              [wallet.address],
              plan.token,
              checked.spender,
            );
      var row = _rapidRows(current, [
        wallet.address,
      ])[wallet.address.toLowerCase()]!;
      if (!live()) return;
      if (!withinBalanceLimits(row)) return;
      var amount = buy ? plan.buyAmount : plan.sellFrom(row.tokenBalance!);
      if (previous != null &&
          unresolved.contains(previous) &&
          (buy ? row.native <= amount : amount > row.tokenBalance!)) {
        if (!await waitPrior(index)) return;
        row = _rapidRows(
          await api.refreshWalletStates(
            [wallet.address],
            token: plan.token,
            spender: checked.spender,
          ),
          [wallet.address],
        )[wallet.address.toLowerCase()]!;
        if (!withinBalanceLimits(row)) return;
        if (!buy) amount = plan.sellFrom(row.tokenBalance!);
      }
      if (!live()) return;
      if (amount <= BigInt.zero || (!buy && amount > row.tokenBalance!))
        throw StateError('${wallet.address} 卖出余额不足');
      if (!buy && (row.routerAllowance ?? BigInt.zero) < amount) {
        throw StateError('卖出授权额度已变化，请重新检查剩余订单');
      }
      final req = RouteRequestData(
        wallet: wallet.address,
        token: plan.token,
        market: plan.market,
        buy: buy,
        amount: amount,
        maxImpactPercent: plan.impactLimit,
      );
      final started = Stopwatch()..start();
      final data = await Future.wait<Object>([api.route(req), api.gas()]);
      if (!live()) return;
      final route = data.first as RoutePlan, head = data.last as GasInfo;
      final gas = GasInfo(checked.gasPrice, head.blockNumber);
      _matchRoute(req, route);
      if (route.gasLimit >
          checked.gasLimits[(wallet.address.toLowerCase(), buy)]!) {
        throw StateError('本笔网络费超过确认上限，请重新检查');
      }
      _checkImpact(adverseRouteImpact(route), plan.impactLimit);
      if (route.simulation != route.source) throw StateError('快速组授权已变化，请重新检查');
      if (started.elapsed > const Duration(seconds: 8))
        throw StateError('本笔报价已过期，请重新检查');
      final nonce =
          nextNonce[index] ?? initialNonce[wallet.address.toLowerCase()]!;
      if (row.nonce > nonce || (previous == null && row.nonce != nonce)) {
        throw StateError('${wallet.address} nonce 已变化，请重新检查待确认交易');
      }
      final state = WalletState(
        wallet.address,
        row.native,
        nonce,
        row.tokenBalance,
        row.routerAllowance,
      );
      final txs = _sign(wallet, plan.token, route, state, gas, amount, buy);
      out.trackIntermediates(route, txs);
      final tx = txs.last;
      final hashes = txs.map((s) => s.hash).toList();
      if (!live()) return;
      nextNonce[index] = nonce + txs.length;
      lastHashes[index] = tx.hash;
      final ack = api.groupBundle(
        [for (final leg in txs) leg.raw],
        gas.blockNumber + 20,
        active: live,
        schedule: scope,
      );
      _rapidSubmitted.add(position);
      out.sent.addAll(hashes);
      out.tradeHashes.add(tx.hash);
      if (txs.length > 1) {
        _rapidCompound[tx.hash] = _BundleCheck(
          hashes,
          {tx.hash: wallet.address},
          plan.token,
          buy,
        );
      }
      unresolved.addAll(hashes);
      if (pipeline) release();
      _changed();
      var submitted = true;
      try {
        await ack;
      } on BackendException catch (e) {
        if (e.notSubmitted) {
          submitted = false;
          unresolved.removeAll(hashes);
          _rapidCompound.remove(tx.hash);
          _rapidSubmitted.remove(position);
          out.sent.removeWhere(hashes.contains);
          out.tradeHashes.remove(tx.hash);
          out.failed++;
        }
        rethrow;
      } finally {
        if (submitted) onTradeSubmitted?.call(plan.token, wallet);
      }
    }

    try {
      await api.requireIdleRapidWallets(owners);
      final rows = _rapidRows(
        await api.refreshWalletStates(
          owners,
          token: plan.token,
          spender: checked.spender,
        ),
        owners,
      );
      for (final owner in owners) {
        initialNonce[owner.toLowerCase()] = rows[owner.toLowerCase()]!.nonce;
        if (!withinBalanceLimits(rows[owner.toLowerCase()]!)) break;
      }
      if (live())
        timer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(monitor()),
        );
      for (var scheduled = 0; scheduled < checked.remainingCount && live();) {
        if (outstanding.length >= (pipeline ? 64 : 8)) {
          if (pipeline) {
            stop('提交响应积压达 64 笔，已停止后续发送，请核对原交易');
            break;
          }
          await Future.any([...outstanding, stopWake.future]);
          continue;
        }
        int? index;
        var position = plan.total;
        for (var j = 0; j < owners.length; j++) {
          if (signing.containsKey(j) || cursors[j] >= positions[j].length)
            continue;
          final next = positions[j][cursors[j]];
          if (next < position) {
            position = next;
            index = j;
          }
        }
        if (index == null) {
          await Future.any([...signing.values, stopWake.future]);
          continue;
        }
        final i = index;
        cursors[i]++;
        scheduled++;
        final ready = Completer<void>();
        signing[i] = ready.future;
        void release() {
          if (!ready.isCompleted) {
            signing.remove(i);
            ready.complete();
          }
        }

        final clock = Stopwatch()..start();
        late Future<void> task;
        task = send(i, position, plan.at(position).$2, release)
            .catchError((Object e) {
              stop('快速组已停止：$e');
            })
            .whenComplete(() {
              release();
              outstanding.remove(task);
            });
        outstanding.add(task);
        if (pipeline) {
          await ready.future;
          clock.reset();
        }
        final delay = plan.interval - clock.elapsed;
        if (live() &&
            scheduled < checked.remainingCount &&
            delay > Duration.zero)
          await Future.any([_sleep(delay), stopWake.future]);
      }
      await Future.wait(outstanding.toList());
    } finally {
      if (_rapidSubmitted.length == plan.total) _rapidSubmitted.clear();
      finished = true;
      timer?.cancel();
      removeListener(syncStop);
      running = false;
      last = out;
      _changed();
    }
    return out;
  }

  Future<void> queryRapid() async {
    if (running) throw StateError('快速组正在处理');
    running = true;
    _changed();
    try {
      await _retryRemainders();
      final compoundLegs = {
        for (final batch in _rapidCompound.values) ...batch.hashes,
      };
      for (final entry in _rapidCompound.entries.toList()) {
        await _verifyBundle(entry.value, last!, manual: true);
        if (!entry.value.hashes.any(unresolved.contains))
          _rapidCompound.remove(entry.key);
      }
      final hashes = unresolved
          .where((h) => !compoundLegs.contains(h))
          .toList();
      for (var i = 0; i < hashes.length; i += 12) {
        await Future.wait(
          hashes.skip(i).take(12).map((h) async {
            final row = await api.reconcileStatus(h);
            if (!row.finished || !unresolved.remove(h)) return;
            if (last?.tradeHashes.contains(h) == true) {
              if (row.status == 'confirmed') {
                last?.confirmed++;
              } else {
                last?.failed++;
              }
            }
          }),
        );
      }
    } finally {
      running = false;
      _changed();
    }
  }
}
