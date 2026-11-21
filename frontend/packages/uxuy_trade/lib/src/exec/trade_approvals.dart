part of 'executor.dart';

const _approvalGas = 150000;
const _approvalGasCap = 15000000;
const _approvalRelayLimit = 103;

typedef _Approval = ({TradeWallet wallet, BigInt amount, bool reset});

/// Bounded token allowances for distinct assets/spenders of a checked route.
class RouteGrants {
  final amounts = <(String, String), Map<String, BigInt>>{};
  final orders = <(String,String),Map<String,int>>{};
  void add(
    String wallet,
    RouteApproval item,
    BigInt numerator,
    BigInt denominator, {int? scheduledOrders}
  ) {
    if (item.amount <= BigInt.zero ||
        denominator <= BigInt.zero ||
        numerator <= BigInt.zero) {
      throw StateError('内盘授权金额无效');
    }
    final estimated=(numerator+denominator-BigInt.one)~/denominator;
    final overLimit=scheduledOrders==null && estimated>BigInt.from(10000);
    final count=scheduledOrders??(overLimit?10000:estimated.toInt());
    if(count<1||count>10000)throw StateError('授权计划笔数无效');
    final budget=overLimit?item.amount*BigInt.from(count):(item.amount*numerator+denominator-BigInt.one)~/denominator;
    final pair=(item.token.toLowerCase(), item.spender.toLowerCase());
    final owner=wallet.toLowerCase();
    final counts=orders.putIfAbsent(pair,()=>{});
    counts[owner]=(counts[owner]??0)+count;
    if(counts[owner]!>10000)throw StateError('单钱包授权计划超过一万笔');
    final rows=amounts.putIfAbsent(pair,()=>{});
    rows[owner] = (rows[owner] ?? BigInt.zero) + budget;
  }
}

/// An approval is a separate, confirmed transaction. Only the spender and exact
/// amount verified by the backend for this wallet and token may be signed.
extension SellApprovalPreparation on BatchTrader {
  Future<bool> checkRouteGrants(
    Market? market,
    List<TradeWallet> wallets,
    RouteGrants grants, {
    bool inspectOnly = false,
    bool allowSubmit = true,
    bool Function()? active,
  }) async {
    if (grants.amounts.isEmpty) return false;
    if (market?.innerPlatform == null) throw StateError('无法核实授权对应的内盘');
    final config = await api.config(), venue = market!;
    for (final entry in grants.amounts.entries) {
      final (token, spender) = entry.key;
      final isAsset =
          token == venue.address.toLowerCase() ||
          token == venue.quote.toLowerCase();
      final validTarget =
          spender == venue.innerTarget?.toLowerCase() && isAsset ||
          token == venue.quote.toLowerCase() &&
              spender == config.approvalSpender?.toLowerCase();
      if (!validTarget || BigInt.parse(token) == BigInt.zero)
        throw StateError('内盘授权代币或合约与已核实市场不符');
      if (inspectOnly) {
        final rows = await api.refreshWalletStates(
          entry.value.keys.toList(),
          token: token,
          spender: spender,
        );
        final allowances = {
          for (final row in rows) row.wallet.toLowerCase(): row.routerAllowance,
        };
        if (entry.value.entries.any(
          (r) => (allowances[r.key] ?? BigInt.zero) < r.value,
        ))
          return true;
      } else {
        await prepareSellApprovals(
          token: token,
          market: venue,
          targetSpender: spender,
          orderCounts:grants.orders[entry.key]!,
          wallets: wallets,
          amounts: entry.value,
          allowSubmit: allowSubmit,
          active: active,
        );
      }
    }
    return false;
  }

  Future<RouteGrants> forecastRouteGrants(
    Market? market,
    bool buy,
    Map<String, BigInt> first, {
    Map<String, BigInt>? cycleBudget,
    TokenMeta? settlement,
  }) async {
    final grants = RouteGrants();
    if (market?.innerPlatform == null || first.isEmpty) return grants;
    BigInt referenceAmount(String owner,BigInt firstAmount) {
      final budget=cycleBudget?[owner]??firstAmount;
      final maxOrders=BigInt.from(10000);
      if(budget<=firstAmount*maxOrders)return firstAmount;
      // Ask for a wallet-bound reference large enough to cover the finite
      // inventory even when a very small tranche would take over 10,000 rounds.
      final reference=(budget+maxOrders-BigInt.one)~/maxOrders;
      if(!buy && market!.innerPlatform=='four'){
        final lot=BigInt.from(1000000000);
        return (reference+lot-BigInt.one)~/lot*lot;
      }
      return reference;
    }
    final requests = [
      for (final entry in first.entries)
        RouteRequestData(
          token: market!.address,
          wallet: checksumAddress(entry.key),
          buy: buy,
          market: market,
          amount: referenceAmount(entry.key,entry.value),
          forecastOnly: true,
          maxImpactPercent: 100,
          settlementToken: settlement?.address,
          settlementDecimals: settlement?.decimals,
        ),
    ];
    final results = await api.routes(requests);
    if (results.length != requests.length) throw StateError('内盘授权报价不完整');
    for (var i = 0; i < requests.length; i++) {
      final r = requests[i], row = results[i];
      if (row.error != null) throw row.error!;
      final quote = row.plan!;
      _matchRoute(r, quote, forecast: true);
      final owner = r.wallet.toLowerCase();
      for (final a in quote.approvals) {
        grants.add(owner, a, cycleBudget?[owner] ?? r.amount, r.amount);
      }
    }
    return grants;
  }

  Future<void> prepareSellApprovals({
    required String token,
    Market? market,
    String? targetSpender,
    Map<String,int> orderCounts=const {},
    required List<TradeWallet> wallets,
    required Map<String, BigInt> amounts,
    bool Function()? active,
    bool allowSubmit = true,
  }) async {
    if (amounts.isEmpty) return;
    final unlimited = (BigInt.one << 256) - BigInt.one;
    if (amounts.values.any(
      (amount) => amount <= BigInt.zero || amount >= unlimited,
    )) {
      throw StateError('授权必须使用本次交易所需的有限正数额度');
    }
    if (_approving) throw StateError('正在检查授权');
    if (unresolved.isNotEmpty) throw StateError('请先查询未确认的原交易');
    _approving = true;
    void checkActive() {
      if (_disposed || (active != null && !active()))
        throw StateError('授权检查已停止');
    }

    try {
      checkActive();
      final config = await api.config();
      _configureRoute(config, market, market?.address ?? token);
      final spender = targetSpender ?? _approvalSpender!;
      final selected = {for (final w in wallets) w.address.toLowerCase(): w};
      if (!amounts.keys.every(selected.containsKey))
        throw StateError('授权钱包与交易钱包不一致');
      final owners = [
        for (final address in amounts.keys) selected[address]!.address,
      ];
      final rows = await api.refreshWalletStates(
        owners,
        token: token,
        spender: spender,
      );
      final byOwner = {for (final s in rows) s.wallet.toLowerCase(): s};
      final needed = <_Approval>[];
      for (final entry in amounts.entries) {
        final state = byOwner[entry.key];
        final allowance = state?.routerAllowance;
        if (allowance == null || entry.value <= BigInt.zero)
          throw StateError('无法确认卖出授权额度');
        if (allowance < entry.value) {
          needed.add((
            wallet: selected[entry.key]!,
            amount: entry.value,
            reset: allowance > BigInt.zero,
          ));
        }
      }
      if (needed.isEmpty) return;
      if (!allowSubmit) throw StateError('授权额度已变化，请重新检查授权');
      var offset = 0;
      while (offset < needed.length) {
        checkActive();
        final header = (await api.rpc([
          ('eth_getBlockByNumber', <Object?>['latest', false]),
        ])).single;
        if (header is! Map || header['gasLimit'] is! String)
          throw StateError('无法读取当前区块 Gas 上限');
        final blockGas = BigInt.parse(header['gasLimit'] as String);
        final budget = min(_approvalGasCap, (blockGas ~/ BigInt.two).toInt());
        final limit = min(_approvalRelayLimit, budget ~/ _approvalGas);
        var signatures = 0;
        final batch = <_Approval>[];
        while (offset < needed.length) {
          final row = needed[offset];
          final count = row.reset ? 2 : 1;
          if (count > limit) throw StateError('单钱包授权超过当前区块的 Gas 预算');
          if (signatures + count > limit) break;
          signatures += count;
          batch.add(row);
          offset++;
        }
        await _submitApprovalBatch(token, spender, market, batch, checkActive,orderCounts);
      }
    } finally {
      _approving = false;
      _changed();
    }
  }

  Future<void> _submitApprovalBatch(
    String token,
    String spender,
    Market? market,
    List<_Approval> batch,
    void Function() checkActive,
    Map<String,int> orderCounts,
  ) async {
    final rows = [
      for (final row in batch)
        (wallet: row.wallet.address, amount: row.amount, reset: row.reset),
    ];
    final platform = market?.innerPlatform;
    final deadline = platform == null
        ? await api.checkSellApprovals(token, spender, rows)
        : await api.checkInnerApprovals(
            token,
            spender,
            rows,
            innerPlatform: platform,
            innerToken: market!.address,orderCounts:orderCounts,
          );
    checkActive();
    final owners = [for (final item in batch) item.wallet.address];
    final (states, gas) = await (
      api.refreshWalletStates(owners, token: token, spender: spender),
      api.gas(),
    ).wait;
    final byOwner = {for (final s in states) s.wallet.toLowerCase(): s};
    final pending = <(_Approval, WalletState)>[];
    for (final item in batch) {
      final st = byOwner[item.wallet.address.toLowerCase()]!;
      if (st.routerAllowance == null) throw StateError('无法确认授权余额');
      if (st.routerAllowance! >= item.amount) continue;
      if ((st.routerAllowance! > BigInt.zero) != item.reset)
        throw StateError('钱包授权已变化，请重新检查');
      _checkGasBudget(
        st,
        BigInt.zero,
        gas,
        _approvalGas * (item.reset ? 2 : 1),
      );
      pending.add((item, st));
    }
    if (pending.isEmpty) return;
    final latest = await api.rpc([
      for (final pair in pending)
        (
          'eth_getTransactionCount',
          <Object?>[pair.$1.wallet.address, 'latest'],
        ),
    ]);
    checkActive();
    final signed = <SignedTx>[];
    for (var i = 0; i < pending.length; i++) {
      final (item, st) = pending[i];
      if (latest[i] is! String ||
          BigInt.parse(latest[i] as String) != BigInt.from(st.nonce)) {
        throw StateError('钱包有待确认交易，请稍后重新检查授权');
      }
      var nonce = st.nonce;
      for (final amount in [if (item.reset) BigInt.zero, item.amount]) {
        signed.add(
          api.sign(
            item.wallet,
            LegacyTx(
              nonce: nonce++,
              gasPrice: gas.gasPrice,
              gasLimit: _approvalGas,
              to: checksumAddress(token),
              value: BigInt.zero,
              data: erc20Approve(spender, amount),
            ),
          ),
        );
      }
    }
    final head = await api.gas();
    checkActive();
    if (deadline <= DateTime.now().millisecondsSinceEpoch ~/ 1000)
      throw StateError('本批授权依据已过期，请重新检查');
    final hashes = [for (final tx in signed) tx.hash];
    _log('正在授权 ${pending.length} 个钱包，共 ${signed.length} 笔');
    _approvalHashes.addAll(hashes);
    unresolved.addAll(hashes);
    try {
      await api.bundle([
        for (final tx in signed) tx.raw,
      ], head.blockNumber + 20);
    } catch (error) {
      if (error is BackendException && error.notSubmitted) {
        unresolved.removeAll(hashes);
        _approvalHashes.removeAll(hashes);
      }
      rethrow;
    }
    var failed = false;
    for (var i = 0; i < hashes.length; i += 16) {
      final chunk = hashes.skip(i).take(16).toList();
      final statuses = await Future.wait(chunk.map(_awaitReceipt));
      for (var j = 0; j < chunk.length; j++) {
        if (statuses[j] == 'unknown') continue;
        unresolved.remove(chunk[j]);
        _approvalHashes.remove(chunk[j]);
        if (statuses[j] != 'confirmed') failed = true;
      }
    }
    if (unresolved.isNotEmpty || failed)
      throw StateError('授权未全部确认，已停止后续交易，请核对原授权');
    final checked = await api.refreshWalletStates(
      owners,
      token: token,
      spender: spender,
    );
    final actual = {
      for (final st in checked) st.wallet.toLowerCase(): st.routerAllowance,
    };
    for (final item in batch) {
      if ((actual[item.wallet.address.toLowerCase()] ?? BigInt.zero) <
          item.amount) {
        throw StateError('链上授权额度未达到本次卖出金额，请重新检查');
      }
    }
    _log('授权已确认并回查，${batch.length} 个钱包', level: LogLevel.success);
  }
}
