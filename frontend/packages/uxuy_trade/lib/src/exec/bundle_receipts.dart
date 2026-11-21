part of 'executor.dart';

final _transferSignature = bytesToHex(
  keccak256('Transfer(address,address,uint256)'.codeUnits),
);

/// Reconcile token units delivered by this transaction, including token tax and transfers back out.
BigInt receiptTokenDelta(Map receipt, String token, String recipient) {
  final owner = '0x${recipient.substring(2).toLowerCase().padLeft(64, '0')}';
  var total = BigInt.zero;
  final logs = receipt['logs'];
  if (logs is! List || hasConflictingReceiptLogs(receipt)) return total;
  for (final row in logs.whereType<Map>()) {
    final topics = row['topics'];
    if ('${row['address']}'.toLowerCase() != token.toLowerCase() ||
        topics is! List ||
        topics.length != 3 ||
        '${topics[0]}'.toLowerCase() != _transferSignature)
      continue;
    final data = row['data'];
    if (data is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(data))
      continue;
    final amount = BigInt.parse(data.substring(2), radix: 16);
    if ('${topics[2]}'.toLowerCase() == owner) total += amount;
    if ('${topics[1]}'.toLowerCase() == owner) total -= amount;
  }
  return total;
}

BigInt? _chainNumber(Object? value) => value is int
    ? BigInt.from(value)
    : value is String
    ? BigInt.tryParse(value)
    : null;

class _BundleCheck {
  const _BundleCheck(this.hashes, this.swaps, this.token, this.buy);
  final List<String> hashes;
  final Map<String, String> swaps;
  final String token;
  final bool buy;
}

extension BundleReceiptVerification on BatchTrader {
  Future<void> _verifyBundle(
    _BundleCheck batch,
    TradeOutcome out, {
    bool manual = false,
  }) async {
    final statuses = <String, String>{};
    for (var i = 0; i < batch.hashes.length; i += 16) {
      await Future.wait(
        batch.hashes.skip(i).take(16).map((hash) async {
          try {
            statuses[hash] = manual
                ? (await api.reconcileStatus(hash)).status
                : await _awaitReceipt(hash);
          } catch (_) {
            statuses[hash] = 'unknown';
          }
        }),
      );
    }
    if (statuses.values.any(
      (s) => !const {
        'confirmed',
        'reverted',
        'not_included',
        'rejected',
        'not_submitted',
      }.contains(s),
    )) {
      out.stopped = true;
      unresolved.addAll(batch.hashes);
      _log('整包回执尚未齐全，请查询原交易', level: LogLevel.error);
      return;
    }
    Map<String,Object?>? confirmedReceipts;
    if (batch.hashes.length > 1 &&
        statuses.values.every((s) => s == 'confirmed')) {
      // A relay acknowledgement and a set of successes do not prove a private
      // bundle landed in the original order in one canonical block.
      try {
        final rows = await _originalReceipts(batch.hashes);
        confirmedReceipts = {for (var i=0; i<batch.hashes.length; i++) batch.hashes[i]:rows[i]};
        String? block;
        BigInt? previous;
        for (var i = 0; i < batch.hashes.length; i++) {
          final hash = batch.hashes[i], row = rows[i];
          if (row is! Map<String, dynamic> || hasConflictingReceiptLogs(row) ||
              row['transactionHash']?.toString().toLowerCase() !=
                  hash.toLowerCase() ||
              _chainNumber(row['status']) != BigInt.one ||
              row['blockHash'] is! String ||
              !RegExp(r'^0x[a-fA-F0-9]{64}$')
                  .hasMatch(row['blockHash'] as String) ||
              _chainNumber(row['transactionIndex']) == null)
            throw StateError('回执缺少包含位置');
          final current = (row['blockHash'] as String).toLowerCase(),
              index = _chainNumber(row['transactionIndex'])!;
          if ((block != null && block != current) ||
              (previous != null && index <= previous)) {
            out.stopped = true;
            _log('捆绑交易已分别上链，但区块或顺序与整包不一致，已停止后续交易', level: LogLevel.error);
          }
          block = current;
          previous = index;
        }
      } catch (_) {
        out.stopped = true;
        unresolved.addAll(batch.hashes);
        _log('整包区块与顺序尚未核实，请查询原交易', level: LogLevel.error);
        return;
      }
    }
    _waitingBundles.remove(batch);
    unresolved.removeAll(batch.hashes);
    for (final entry in statuses.entries) {
      final wallet = batch.swaps[entry.key];
      if (wallet != null) out.swapStatuses[entry.key] = entry.value;
      if (entry.value == 'confirmed') {
        if (wallet != null) {
          out.confirmed++;
          out.confirmedWallets.add(wallet);
          _log('$wallet 已确认', level: LogLevel.success);
        }
      } else {
        if (wallet != null) out.failed++;
        out.stopped = true;
        _log(
          '${wallet ?? '辅助交易'} ${BatchTrader._failure(entry.value)} ${entry.key}',
          level: LogLevel.error,
        );
      }
    }
    final originals = batch.swaps.keys.where(out._intermediates.containsKey).toList();
    for (var i = 0; i < originals.length; i += 6) {
      await Future.wait(originals.skip(i).take(6).map((h) => reconcileIntermediateReceipt(h, out, known: confirmedReceipts)));
    }
    if (!batch.buy) {
      final sold = [
        for (final hash in batch.swaps.keys)
          if (statuses[hash] == 'confirmed') hash,
      ];
      await _saleResult(out, sold, batch.token, [
        for (final hash in batch.hashes)
          if (statuses[hash] == 'confirmed' || statuses[hash] == 'reverted')
            hash,
      ]);
    }
  }

  Future<List<Object?>> _originalReceipts(List<String> hashes) async {
    final results = <Object?>[];
    for (var start = 0; start < hashes.length; start += 100) {
      final batch = hashes.skip(start).take(100).toList();
      final rows = await api.rpc([
        for (final hash in batch) ('eth_getTransactionReceipt', [hash]),
      ]);
      if (rows.length != batch.length) throw StateError('回执数量不完整');
      results.addAll(rows);
    }
    return results;
  }

  Future<void> _saleResult(
    TradeOutcome out,
    List<String> swaps,
    String token,
    List<String> allHashes,
  ) async {
    if (!recordSaleProceeds || allHashes.isEmpty) return;
    final key = allHashes.first;
    final pending = swaps.isEmpty ? allHashes : swaps;
    try {
      final settlement = out.settlement;
      var native = BigInt.zero;
      if (settlement == null && swaps.isNotEmpty) {
        if (strictSaleReceipts) {
          for (var i = 0; i < swaps.length; i += 8) {
            final parts = await Future.wait(swaps.skip(i).take(8).map((hash) async {
              final delta = await api.linkedTradeDelta([hash], token: token, buy: false);
              final limits = out.saleLimits[hash];
              if (limits == null || delta.tokens != limits.amount || delta.native < limits.minimum) {
                throw StateError('清仓卖出扣款或 BNB 最低实收未能核实');
              }
              return delta.native;
            }));
            for (final value in parts) {
              native += value;
            }
          }
        } else {
          native = (await api.linkedTradeDelta(swaps, token: token, buy: false)).native;
        }
      }
      final rows = await _originalReceipts(allHashes);
      var fees = BigInt.zero, assetReceived = BigInt.zero;
      final receiptsByHash = <String,Map>{};
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row is! Map || hasConflictingReceiptLogs(row) ||
            row['transactionHash']?.toString().toLowerCase() !=
                allHashes[i].toLowerCase())
          throw StateError('尚无交易回执');
        final units = _chainNumber(row['gasUsed']),
            price = _chainNumber(row['effectiveGasPrice']);
        if (units == null || price == null) throw StateError('网络费凭据不全');
        fees += units * price;
        final hash = allHashes[i];
        receiptsByHash[hash] = row;
      }
      if (settlement != null) {
        for (final hash in swaps) {
          final wallet = out.swapOrders[hash]?.wallet.toLowerCase();
          final limits = out.saleLimits[hash];
          if (wallet == null || limits == null) throw StateError('清仓回执缺少订单');
          final targets = out.saleLegs[hash] ?? {hash:routerAddress!};
          var received = BigInt.zero, sold = BigInt.zero;
          String? block;
          var position = -BigInt.one;
          for (final leg in targets.entries) {
            final row = receiptsByHash[leg.key];
            if (row == null || _chainNumber(row['status']) != BigInt.one ||
                row['from']?.toString().toLowerCase() != wallet ||
                row['to']?.toString().toLowerCase() != leg.value.toLowerCase()) {
              throw StateError('清仓回执与付款钱包或交易合约不符');
            }
            if (targets.length > 1) {
              final current = row['blockHash'], index = _chainNumber(row['transactionIndex']);
              if (current is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(current) ||
                  (block != null && current != block) || index == null || index <= position) {
                throw StateError('尚未证实清仓交易各步按顺序同块完成');
              }
              block = current;
              position = index;
            }
            received += receiptTokenDelta(row, settlement.address, wallet);
            sold -= receiptTokenDelta(row, token, wallet);
          }
          if (sold != limits.amount || received < limits.minimum) {
            throw StateError('清仓卖出扣款或底池币最低实收未能核实');
          }
          assetReceived += received;
        }
      }
      _waitingSales.remove(key);
      out.unverifiedSettlement.removeAll(pending);
      out.nativeReceived += native;
      out.settlementReceived += assetReceived;
      out.networkFees += fees;
      final actual = settlement == null ? native : assetReceived;
      final decimals = settlement?.decimals ?? 18;
      _log(
        '卖出实收 ${formatUnits(actual, decimals, maxFraction: decimals)} ${settlement?.symbol ?? "BNB"} · 网络费 ${formatUnits(fees, 18, maxFraction: 18)} BNB',
      );
    } catch (_) {
      if (!_waitingSales.containsKey(key)) _log('卖单已上链，到账及网络费待核实，可查询原交易');
      _waitingSales[key] = (
        outcome: out,
        swaps: swaps,
        token: token,
        hashes: allHashes,
      );
      out.unverifiedSettlement.addAll(pending);
    }
  }
}
