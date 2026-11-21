part of 'executor.dart';

class _IntermediateOrder {
  const _IntermediateOrder(this.owner, this.hashes, this.legs);
  final String owner;
  final List<String> hashes;
  final List<RouteLeg> legs;
}

final _depositEvent = bytesToHex(
  keccak256('Deposit(address,uint256)'.codeUnits),
);
final _withdrawEvent = bytesToHex(
  keccak256('Withdrawal(address,uint256)'.codeUnits),
);

/// Wallet net flow from ERC20 transfers. WBNB's original contract uses
/// Deposit/Withdrawal instead of mint/burn Transfer events on its own wrap calls.
BigInt intermediateTokenDelta(
  Map receipt,
  RouteLeg leg,
  String token,
  String wallet,
) {
  final owner = '0x${wallet.substring(2).toLowerCase().padLeft(64, '0')}';
  final logs = receipt['logs'];
  if (logs is! List || hasConflictingReceiptLogs(receipt)) {
    throw StateError('缺少有效的原交易中间币回执');
  }
  var credited = BigInt.zero, debited = BigInt.zero, wrapped = BigInt.zero;
  final isWrap =
      token.toLowerCase() == wbnb.toLowerCase() &&
      leg.to.toLowerCase() == token.toLowerCase() &&
      {'wrap', 'unwrap'}.contains(leg.kind);
  for (final row in logs) {
    if (row is! Map) throw StateError('中间币事件无效');
    if ('${row['address']}'.toLowerCase() != token.toLowerCase()) continue;
    final topics = row['topics'];
    if (topics is! List || topics.isEmpty) continue;
    final event = '${topics[0]}'.toLowerCase();
    final transfer = event == _transferSignature;
    final wrap =
        isWrap &&
        event == (leg.kind == 'wrap' ? _depositEvent : _withdrawEvent);
    if (!transfer && !wrap) continue;
    if (topics.length != (transfer ? 3 : 2)) throw StateError('中间币事件格式无效');
    final data = row['data'];
    if (data is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(data))
      throw StateError('中间币事件数量无效');
    final n = BigInt.parse(data.substring(2), radix: 16);
    if (transfer) {
      if ('${topics[1]}'.toLowerCase() == owner) debited += n;
      if ('${topics[2]}'.toLowerCase() == owner) credited += n;
    } else if ('${topics[1]}'.toLowerCase() == owner) {
      wrapped += n;
    }
  }
  if (isWrap) {
    if (wrapped != leg.amountIn) throw StateError('未核实实际 WBNB 包装或解包数量');
    return leg.kind == 'wrap' ? wrapped : -wrapped;
  }
  // A silent token is unverifiable. An unchanged intermediate in a third leg
  // legitimately has no token events.
  if (leg.tokenIn.toLowerCase() == token.toLowerCase() &&
          debited == BigInt.zero ||
      leg.tokenOut.toLowerCase() == token.toLowerCase() &&
          credited == BigInt.zero) {
    throw StateError('缺少中间币的实际收付事件');
  }
  return credited - debited;
}

extension IntermediateReceiptAccounting on BatchTrader {
  Future<void> _retryRemainders() async {
    final waiting = _waitingRemainders.entries.toList();
    for (var i = 0; i < waiting.length; i += 6) {
      await Future.wait(
        waiting
            .skip(i)
            .take(6)
            .map(
              (entry) => reconcileIntermediateReceipt(entry.key, entry.value),
            ),
      );
    }
  }

  Future<void> reconcileIntermediateReceipt(
    String finalHash,
    TradeOutcome out, {
    Map<String, Object?>? known,
  }) async {
    final order = out._intermediates[finalHash];
    if (order == null) return;
    try {
      final assets =
          order.legs
              .take(order.legs.length - 1)
              .map((leg) => leg.tokenOut.toLowerCase())
              .toSet()
            ..remove(order.legs.first.tokenIn.toLowerCase())
            ..remove(order.legs.last.tokenOut.toLowerCase());
      final deltas = {for (final asset in assets) asset: BigInt.zero};
      final receipts = known == null
          ? await _originalReceipts(order.hashes)
          : [for (final hash in order.hashes) known[hash]];
      for (var i = 0; i < order.hashes.length; i++) {
        final hash = order.hashes[i],
            leg = order.legs[i],
            receipt = receipts[i];
        if (receipt == null) {
          final status = await api.reconcileStatus(hash);
          if (status.refused || status.status == 'not_included') continue;
          throw StateError('原交易回执尚未返回');
        }
        if (receipt is! Map || hasConflictingReceiptLogs(receipt) ||
            '${receipt['transactionHash']}'.toLowerCase() !=
                hash.toLowerCase() ||
            '${receipt['from']}'.toLowerCase() != order.owner.toLowerCase() ||
            '${receipt['to']}'.toLowerCase() != leg.to.toLowerCase())
          throw StateError('中间币回执与原交易不符');
        if (receipt['blockHash'] is! String ||
            !RegExp(r'^0x[0-9a-fA-F]{64}$')
                .hasMatch(receipt['blockHash'] as String) ||
            _chainNumber(receipt['transactionIndex']) == null)
          throw StateError('缺少中间币交易的包含位置');
        final status = _chainNumber(receipt['status']);
        if (status == BigInt.zero) continue;
        if (status != BigInt.one) throw StateError('原交易状态尚未确认');
        for (final asset in assets) {
          final change = asset == zeroAddress
              ? await api.nativeReceiptPrincipal(hash, order.owner, receipt)
              : intermediateTokenDelta(receipt, leg, asset, order.owner);
          deltas[asset] = deltas[asset]! + change;
        }
      }
      final lines = <String>[];
      for (final e in deltas.entries) {
        if (e.value == BigInt.zero) continue;
        String amount;
        if (e.key == zeroAddress || e.key == wbnb.toLowerCase()) {
          amount =
              '${formatUnits(e.value.abs(), 18, maxFraction: 18)} ${e.key == zeroAddress ? "BNB" : "WBNB"}';
        } else {
          TokenMeta? meta = _remainderMeta[e.key];
          if (meta == null) {
            try {
              final raw = await api.token(e.key);
              if (raw.address.toLowerCase() == e.key &&
                  raw.symbol.isNotEmpty &&
                  raw.decimals != null &&
                  raw.decimals! >= 0 &&
                  raw.decimals! <= 36)
                meta = _remainderMeta[e.key] = raw;
            } on Object {
              /* The raw receipt amount remains available. */
            }
          }
          amount = meta == null
              ? '${e.value.abs()} 最小单位（${e.key}）'
              : '${formatUnits(e.value.abs(), meta.decimals!, maxFraction: meta.decimals!)} ${meta.symbol}（${e.key}）';
        }
        lines.add(
          e.value > BigInt.zero
              ? '${order.owner} 本笔换币后仍留有 $amount'
              : '${order.owner} 本笔额外支出 $amount',
        );
      }
      out.remainingAssets[finalHash] = lines;
      out._intermediates.remove(finalHash);
      _waitingRemainders.remove(finalHash);
      for (final line in lines) {
        _log('$line · $finalHash');
      }
    } on Object {
      if (!_waitingRemainders.containsKey(finalHash))
        _log('${order.owner} 换币结余待核实，可查询原交易 $finalHash');
      _waitingRemainders[finalHash] = out;
    }
  }
}
