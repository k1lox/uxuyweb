part of 'launch.dart';

/// A conversion only concerns a pool asset that already exists. Each wallet obtains
/// its own UXUY call, then spends the guaranteed pool-token units on the new token.
class LaunchFundingTx extends LaunchTx {
  LaunchFundingTx(
    TradeWallet wallet,
    RoutePlan plan,
    this.asset,
    this.poolSpend,
  ) : super(
        'BNB 兑换底池币',
        wallet,
        plan.to,
        hexToBytes(plan.data),
        plan.value,
        plan.gasLimit,
        kind: 'funding',
        purchasedToken: asset.address,
        minimumDelivery: plan.minOut,
        validUntil: plan.deadline,
      );
  final TokenMeta asset;
  final BigInt poolSpend;
  LaunchTx? _purchase;

  /// Amounts attributable to this wallet's two original confirmed transactions.
  /// The wallet's pre-existing collateral never participates in this calculation.
  ({BigInt spent, BigInt remaining})? get confirmedSettlement {
    final purchase = _purchase;
    if (purchase == null) return null;
    final fundingReceipt = _originalReceipt(this);
    final buyReceipt = _originalReceipt(purchase);
    if (fundingReceipt == null ||
        buyReceipt == null ||
        fundingReceipt.block != buyReceipt.block ||
        fundingReceipt.index >= buyReceipt.index)
      return null;
    final acquired = _collateralDelta(fundingReceipt.row);
    final buyDelta = _collateralDelta(buyReceipt.row);
    if (acquired == null ||
        buyDelta == null ||
        acquired < minimumDelivery! ||
        buyDelta >= BigInt.zero ||
        -buyDelta > poolSpend ||
        -buyDelta > acquired)
      return null;
    return (spent: -buyDelta, remaining: acquired + buyDelta);
  }

  static ({Map row, String block, BigInt index})? _originalReceipt(
    LaunchTx tx,
  ) {
    final row = tx.receipt;
    if (tx.status != 'confirmed' || row == null || tx.hash == null) return null;
    final block = '${row['blockHash']}'.toLowerCase();
    final index = BigInt.tryParse('${row['transactionIndex']}');
    if (BigInt.tryParse('${row['status']}') != BigInt.one ||
        !RegExp(r'^0x[0-9a-f]{64}$').hasMatch(block) ||
        index == null ||
        index < BigInt.zero ||
        '${row['transactionHash']}'.toLowerCase() != tx.hash!.toLowerCase() ||
        '${row['from']}'.toLowerCase() != tx.from.address.toLowerCase() ||
        '${row['to']}'.toLowerCase() != tx.to?.toLowerCase())
      return null;
    return (row: row, block: block, index: index);
  }

  BigInt? _collateralDelta(Map row) {
    final logs = row['logs'];
    if (logs is! List) return null;
    for (final log in logs) {
      if (log is! Map) return null;
      if ('${log['address']}'.toLowerCase() != asset.address.toLowerCase())
        continue;
      final topics = log['topics'];
      if (topics is! List || topics.isEmpty) return null;
      if ('${topics.first}'.toLowerCase() != _collateralTransfer) continue;
      if (log['removed'] == true ||
          topics.length != 3 ||
          !topics.skip(1).every((t) => _addressWord.hasMatch('$t')) ||
          !_uintWord.hasMatch('${log['data']}'))
        return null;
    }
    return launchReceiptDelivery(row, asset.address, from.address);
  }

  static final _collateralTransfer = bytesToHex(
    keccak256('Transfer(address,address,uint256)'.codeUnits),
  );
  static final _addressWord = RegExp(r'^0x0{24}[0-9a-fA-F]{40}$');
  static final _uintWord = RegExp(r'^0x[0-9a-fA-F]{64}$');
}

class LaunchFunding {
  LaunchFunding._(this._quote, this._buyers, this._config, this._asset);
  final TokenMeta? _asset;
  final String _quote;
  final List<LaunchBuyer> _buyers;
  final ModuleConfig? _config;
  final Map<String, BigInt> _amounts = {};
  final Map<String, LaunchFundingTx> _conversions = {};

  static Future<LaunchFunding> prepare(
    BackendClient api,
    String quote,
    Iterable<LaunchBuyer> entries, {
    required bool convert,
  }) async {
    final buyers = convert
        ? entries.where((b) => b.amount > BigInt.zero).toList()
        : <LaunchBuyer>[];
    final config = buyers.isEmpty ? null : await api.config();
    config?.requireUxuySwap();
    if (config != null &&
        (!config.maxImpact.isFinite ||
            config.maxImpact < 0 ||
            config.maxImpact > 100))
      throw StateError('UXUY 价格冲击上限无效');
    final asset = buyers.isEmpty ? null : await api.token(quote);
    if (asset != null &&
        (asset.address.toLowerCase() != quote.toLowerCase() ||
            asset.decimals == null ||
            asset.decimals! < 0 ||
            asset.decimals! > 36 ||
            asset.symbol.isEmpty))
      throw StateError('底池币名称或精度无法验证');
    final result = LaunchFunding._(quote, buyers, config, asset);
    if (buyers.isNotEmpty) await result._quoteBuyers(api, forecast: true);
    return result;
  }

  bool get converted => _buyers.isNotEmpty;
  LaunchBuyer units(LaunchBuyer buyer) {
    final value = _amounts[buyer.wallet.address.toLowerCase()];
    return value == null ? buyer : LaunchBuyer(buyer.wallet, value);
  }

  Future<void> executable(BackendClient api) async {
    if (converted) await _quoteBuyers(api, forecast: false);
  }

  Future<void> _quoteBuyers(BackendClient api, {required bool forecast}) async {
    final config = _config!;
    final requests = [
      for (final b in _buyers)
        RouteRequestData(
          token: _quote,
          wallet: b.wallet.address,
          buy: true,
          amount: b.amount,
          forecastOnly: forecast,
          maxImpactPercent: config.maxImpact,
        ),
    ];
    final rows = await api.routes(requests);
    if (rows.length != _buyers.length) throw StateError('UXUY 无法获得合格报价');
    for (var i = 0; i < rows.length; i++) {
      final p = rows[i].plan,
          b = _buyers[i],
          owner = b.wallet.address.toLowerCase();
      if (rows[i].error case final error?) throw error;
      if (p == null ||
          p.chainId != bscChainId ||
          p.settlementToken != null ||
          p.buy != true ||
          p.token?.toLowerCase() != _quote.toLowerCase() ||
          p.quoteScope != 'wallet' ||
          p.wallet.toLowerCase() != owner ||
          p.amount != b.amount ||
          p.value != b.amount ||
          p.to.toLowerCase() != config.router.toLowerCase() ||
          p.spender.toLowerCase() != config.approvalSpender!.toLowerCase() ||
          p.deadline <= DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
          p.slippagePpm < 0 ||
          p.slippagePpm > requests[i].slippageBps * 100 ||
          p.minOut <= BigInt.zero ||
          p.minOut > p.quoteOut ||
          p.minOut <
              p.quoteOut *
                  BigInt.from(1000000 - p.slippagePpm) ~/
                  BigInt.from(1000000) ||
          !p.priceImpact.isFinite ||
          p.priceImpact < 0 ||
          p.priceImpact > config.maxImpact)
        throw StateError('UXUY 无法获得合格报价');
      if (forecast) {
        if (p.executed || p.simulation != 'forecast' || p.data != '0x')
          throw StateError('底池币预估格式错误');
        _amounts[owner] = p.minOut;
      } else {
        if (!p.executed ||
            p.simulation != 'uxuy' ||
            !RegExp(r'^0x5103aafa(?:[0-9a-fA-F]{2})+$').hasMatch(p.data) ||
            p.gasLimit < 21000 ||
            p.gasLimit > 30000000)
          throw StateError('UXUY 无法获得合格报价');
        // Approvals have already been confirmed for this exact downstream spend.
        if (p.minOut < _amounts[owner]!)
          throw StateError('底池币兑换最低到账已下降，请重新准备发币');
        _conversions[owner] = LaunchFundingTx(
          b.wallet,
          p,
          _asset!,
          _amounts[owner]!,
        );
      }
    }
  }

  List<LaunchTx> include(List<LaunchTx> trades) {
    if (!converted) return trades;
    final purchases = trades.where(
      (tx) => tx.purchasedToken != null && tx.kind != 'create',
    );
    final owners = purchases.map((tx) => tx.from.address.toLowerCase()).toSet();
    if (_conversions.length != _buyers.length ||
        !_conversions.keys.every(owners.contains)) {
      throw StateError('每个钱包的兑换与首买必须在同一捆绑中');
    }
    // Bind the actual final purchase object, including a rebuilt slippage floor.
    // Ambiguous multiple purchases cannot establish a two-receipt remainder.
    final paired = <String, LaunchTx?>{};
    for (final tx in purchases) {
      final owner = tx.from.address.toLowerCase();
      paired[owner] = paired.containsKey(owner) ? null : tx;
    }
    for (final entry in _conversions.entries) {
      entry.value._purchase = paired[entry.key];
    }
    // A large swap can move the shared pool past the next wallet's minimum.
    // Fund the smallest budgets first, while preserving every official launch step.
    final conversions = _buyers.indexed.toList()
      ..sort((a, b) {
        final amount = a.$2.amount.compareTo(b.$2.amount);
        return amount == 0 ? a.$1.compareTo(b.$1) : amount;
      });
    final firstBuy = trades.indexOf(purchases.first);
    return [
      ...trades.take(firstBuy),
      for (final (_, buyer) in conversions)
        _conversions[buyer.wallet.address.toLowerCase()]!,
      ...trades.skip(firstBuy),
    ];
  }
}
