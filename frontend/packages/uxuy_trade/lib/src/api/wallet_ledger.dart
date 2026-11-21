part of 'backend_client.dart';

typedef _View = ({String wallet, String token, String spender});
const _withoutAllowance = '-';

/// A snapshot is either complete for its requested view or explicitly needs reconciliation.
class _WalletLedger {
  _WalletLedger(this.api);
  final BackendClient api;
  final _book = <_View, WalletState?>{};
  final _viewsByWallet = <String, Set<_View>>{};
  final _reads = <_View, Future<void>>{};

  void _store(_View key, WalletState? value) {
    _book[key] = value;
    (_viewsByWallet[key.wallet] ??= {}).add(key);
  }

  final _revision = <String, int>{};
  final _refreshEpoch = <String, int>{};
  final _signed = <String, _SignedChange>{};
  final _pending = <String, _SignedChange>{};
  final _swapOrigins = <String, ({String wallet, String router, List<String>? legs})>{};
  final _checking = <String, Future<TxRecord>>{};
  final _missingResults = <String, TxRecord>{};

  void register(String owner, LegacyTx tx, SignedTx signed) {
    _signed[signed.hash.toLowerCase()] = _SignedChange(
      owner.toLowerCase(),
      tx,
      _refreshEpoch[owner.toLowerCase()] ?? 0,
    );
    // Unsent simulations and cancelled previews must not accumulate calldata forever.
    if (_signed.length > 1600) _signed.remove(_signed.keys.first);
  }

  void trackInnerRoute(List<SignedTx> txs) {
    final hashes = List<String>.unmodifiable(txs.map((tx) => tx.hash.toLowerCase()));
    for (final h in hashes) {
      final change = _signed[h];
      if (change == null) throw StateError('交易签名上下文已变更');
      change.innerLegs = hashes;
    }
  }

  Future<T> submitting<T>(
    List<String> raws,
    Future<T> Function() send, {
    _BundleWindow? window,
    Object? schedule,
  }) async {
    final batch = <String, _SignedChange>{};
    final activeWallets = {
      for (final entry in _pending.values) ...entry.affected,
    };
    final reading = {for (final key in _reads.keys) key.wallet};
    final occupied = <(String, int)>{
      for (final p in _pending.values) (p.owner, p.tx.nonce),
    };
    final lastNonceInBatch = <String,int>{};
    for (final raw in raws) {
      final hash = bytesToHex(keccak256(hexToBytes(raw)));
      final change = _signed[hash];
      if (change == null) {
        // Raw public API callers may submit independently signed payloads. Once an account
        // is being tracked, an unidentifiable transaction cannot bypass its nonce lock.
        if (_book.isNotEmpty || _pending.isNotEmpty) {
          throw const BackendException(
            'UNTRACKED_TX',
            '签名上下文已过期，请重新准备',
            false,
            notSubmitted: true,
          );
        }
        continue;
      }
      final knownNonce = _knownNonce(change.owner);
      final views = _viewsByWallet[change.owner] ?? const <_View>{};
      final asset = change.tx.to?.toLowerCase();
      final inputToken = change.tx.data.length < 36
          ? null
          : bytesToHex(change.tx.data.sublist(16, 36));
      if (!reading.contains(change.owner) &&
          views.isNotEmpty &&
          (knownNonce == null ||
              views.any(
                (v) =>
                    _book.containsKey(v) &&
                    _book[v] == null &&
                    (v.token == asset || v.token == inputToken),
              ))) {
        throw const BackendException(
          'WALLET_REFRESH_REQUIRED',
          '钱包数据待核对，请点击日志中的刷新',
          false,
          notSubmitted: true,
        );
      }
      if (!reading.contains(change.owner) &&
          change.refreshEpoch != (_refreshEpoch[change.owner] ?? 0)) {
        throw const BackendException(
          'WALLET_CHANGED',
          '签名后钱包已手动刷新，请重新准备',
          false,
          notSubmitted: true,
        );
      }
      // Only consecutive swaps owned by this exact rapid run can share its
      // sender. A transfer, a different run, or a nonce gap keeps the lock.
      final shared = schedule != null && activeWallets.contains(change.owner);
      final predecessors = shared
          ? _pending.values.where((p) => p.affected.contains(change.owner)).toList()
          : const <_SignedChange>[];
      final continuesSchedule = predecessors.isNotEmpty &&
          predecessors.every((p) => identical(p.schedule, schedule) && p.owner == change.owner) &&
          (lastNonceInBatch[change.owner] ?? predecessors.last.tx.nonce) + 1 == change.tx.nonce;
      if (!occupied.add((change.owner, change.tx.nonce)) ||
          (activeWallets.contains(change.owner) && !continuesSchedule) ||
          reading.contains(change.owner) ||
          (knownNonce != null && knownNonce > change.tx.nonce)) {
        throw const BackendException(
          'WALLET_BUSY',
          '钱包交易状态已改变，请先确认原交易再准备',
          false,
          notSubmitted: true,
        );
      }
      change.schedule = schedule;
      batch[hash] = change;
      lastNonceInBatch[change.owner] = change.tx.nonce;
    }
    for (final e in batch.entries) {
      e.value.terminal = null;
      e.value.window = window;
      e.value.lastProof = null;
      _missingResults.remove(e.key);
      _pending[e.key] = e.value;
      final target = e.value.tx.to?.toLowerCase();
      if (target != null &&
          (target == api._router || e.value.innerLegs != null) &&
          e.value.tx.data.isNotEmpty) {
        _swapOrigins[e.key] = (wallet: e.value.owner, router: target, legs: e.value.innerLegs);
        if (_swapOrigins.length > 2400)
          _swapOrigins.remove(_swapOrigins.keys.first);
      }
      _touch(e.value.affected);
    }
    try {
      return await send();
    } on BackendException catch (e) {
      if (e.notSubmitted) {
        for (final h in batch.keys) {
          observe(TxRecord(h, 'not_submitted', null));
        }
      }
      rethrow;
    }
  }

  int? _knownNonce(String owner) {
    for (final key in _viewsByWallet[owner] ?? const <_View>{}) {
      final state = _book[key];
      if (state != null) return state.nonce;
    }
    return null;
  }

  void _touch(Iterable<String> wallets) {
    for (final wallet in wallets.toSet()) {
      _revision[wallet] = (_revision[wallet] ?? 0) + 1;
    }
  }

  Future<void> _settled(Set<String> wallets, {bool manual = false}) async {
    // A transfer through a relay can spend a receipt from another sender in the
    // same bundle. Include earlier dependencies even when statuses arrive reversed.
    final upstream = {...wallets};
    final hashes = <String>[];
    for (final e in _pending.entries.toList().reversed) {
      if (!e.value.affected.any(upstream.contains)) continue;
      upstream.addAll(e.value.affected);
      if (e.value.terminal == null) hashes.add(e.key);
    }
    for (var i = 0; i < hashes.length; i += 16) {
      await Future.wait(
        hashes
            .skip(i)
            .take(16)
            .map(
              (h) => _checking[h] ??= api
                  ._transactionStatus(h, tracked: !manual)
                  .whenComplete(() {
                    _checking.remove(h);
                  }),
            ),
      );
    }
    if (_pending.values.any((p) => p.affected.any(wallets.contains))) {
      throw const BackendException(
        'WALLET_PENDING',
        '原交易尚未确认，暂不能使用该钱包余额，请查询原交易',
        true,
      );
    }
  }

  // No relay record is inconclusive. For locally submitted private bundles only,
  // a mined receipt or a null receipt after the expiry window resolves the original
  // hash for BOTH the executor and the ledger. Bound proof traffic while polling.
  Future<TxRecord> resolveMissing(TxRecord row, {required bool manual}) async {
    final hash = row.hash.toLowerCase();
    final prior = _missingResults[hash];
    if (prior != null) return prior;
    final change = _pending[hash];
    final window = change?.window;
    if (change == null || window == null) return row;
    final end = window.maxBlock;
    final now = DateTime.now();
    if (!manual &&
        change.lastProof != null &&
        now.difference(change.lastProof!) < const Duration(seconds: 4))
      return row;
    change.lastProof = now;
    final proof = await api.rpc([
      ('eth_blockNumber', []),
      ('eth_getTransactionReceipt', [hash]),
      if (window.group) ('eth_getTransactionByHash', [hash]),
    ]);
    final height = _number(proof[0]);
    final receipt = proof[1];
    if (receipt == null &&
        (height <= BigInt.from(end + 3) ||
            window.group && (window.submitting || proof[2] != null)))
      return row;
    if (receipt != null &&
        (receipt is! Map || hasConflictingReceiptLogs(receipt) ||
            receipt['transactionHash']?.toString().toLowerCase() != hash ||
            !{'0x0', '0x1'}.contains(receipt['status']) ||
            receipt['blockNumber'] == null ||
            _number(receipt['blockNumber']) > height))
      return row;
    if (!identical(_pending[hash], change) ||
        !identical(change.window, window) ||
        window.maxBlock != end)
      return _missingResults[hash] ?? row;
    final closed = receipt == null
        ? TxRecord(hash, 'not_included', null)
        : TxRecord(
            hash,
            (receipt as Map)['status'] == '0x1' ? 'confirmed' : 'reverted',
            null,
            receipt: receipt.cast<String, dynamic>(),
          );
    _missingResults[hash] = closed;
    if (_missingResults.length > 1200)
      _missingResults.remove(_missingResults.keys.first);
    observe(closed);
    return closed;
  }

  Future<List<WalletState>> states(
    List<String> wallets, {
    String? token,
    String? spender,
    bool skipAllowance = false,
    bool refresh = false,
  }) async {
    final t = token?.toLowerCase() ?? '';
    final s = t.isEmpty
        ? ''
        : skipAllowance
        ? _withoutAllowance
        : (spender ??
                  api._spender ??
                  (await api.config()).approvalSpender ??
                  _withoutAllowance)
              .toLowerCase();
    final keys = [
      for (final w in wallets) (wallet: w.toLowerCase(), token: t, spender: s),
    ];
    final owners = keys.map((k) => k.wallet).toSet();
    if (refresh) {
      await _refresh({
        ...keys,
        for (final wallet in owners) ...?_viewsByWallet[wallet],
      });
    } else {
      await _settled(owners);
    }
    final missing = <_View>[];
    final waiting = <Future<void>>{};
    for (final k in keys.toSet()) {
      final read = _reads[k];
      if (read != null) {
        waiting.add(read);
        continue;
      }
      if (!_book.containsKey(k) && (t.isEmpty || skipAllowance)) {
        WalletState? reusable;
        for (final v in _viewsByWallet[k.wallet] ?? const <_View>{}) {
          if (_book[v] != null && (t.isEmpty || v.token == t)) {
            reusable = _book[v];
            break;
          }
        }
        if (reusable != null) {
          final w = reusable;
          _store(
            k,
            WalletState(
              w.wallet,
              w.native,
              w.nonce,
              t.isEmpty ? null : w.tokenBalance,
              null,
            ),
          );
        }
      }
      if (!_book.containsKey(k)) missing.add(k);
    }
    for (var i = 0; i < missing.length; i += 500) {
      waiting.add(_read(missing.skip(i).take(500).toList()));
    }
    if (waiting.isNotEmpty) await Future.wait(waiting);
    if (_pending.values.any((p) => p.affected.any(owners.contains))) {
      throw const BackendException('WALLET_PENDING', '钱包已有待确认交易，请查询原交易', true);
    }
    return [
      for (final key in keys)
        _book[key] ??
            (throw const BackendException(
              'WALLET_REFRESH_REQUIRED',
              '无法从回执核对钱包余额，请点击日志中的刷新',
              false,
            )),
    ];
  }

  Future<void> refreshKnown() => _refresh(_book.keys.toSet());

  Future<void> _refresh(Set<_View> keys) async {
    if (keys.isEmpty) return;
    final owners = keys.map((k) => k.wallet).toSet();
    await _settled(owners, manual: true);
    _touch(owners);
    for (final w in owners) {
      _refreshEpoch[w] = (_refreshEpoch[w] ?? 0) + 1;
    }
    final groups = <(String, String), List<_View>>{};
    for (final k in keys) {
      _store(k, null);
      (groups[(k.token, k.spender)] ??= []).add(k);
    }
    final batches = [
      for (final rows in groups.values)
        for (var i = 0; i < rows.length; i += 500)
          rows.skip(i).take(500).toList(),
    ];
    for (var i = 0; i < batches.length; i += 6) {
      await Future.wait(batches.skip(i).take(6).map(_read));
    }
  }

  Future<void> _read(List<_View> keys) {
    final first = keys.first;
    final revisions = {for (final k in keys) k.wallet: _revision[k.wallet]};
    late Future<void> task;
    task = api
        ._fetchWalletStates(
          [for (final k in keys) k.wallet],
          token: first.token.isEmpty ? null : first.token,
          spender: first.spender.isEmpty || first.spender == _withoutAllowance
              ? null
              : first.spender,
          skipAllowance: first.spender == _withoutAllowance,
        )
        .then((rows) {
          final byAddress = {for (final w in rows) w.wallet.toLowerCase(): w};
          if (byAddress.length != keys.length ||
              rows.length != keys.length ||
              !keys.every((k) => byAddress.containsKey(k.wallet))) {
            throw const BackendException('BAD_RESPONSE', '钱包快照地址不匹配', true);
          }
          if (keys.any((k) => _revision[k.wallet] != revisions[k.wallet])) {
            throw const BackendException(
              'WALLET_CHANGED',
              '读取期间钱包状态已改变，请重新准备',
              true,
            );
          }
          for (final k in keys) {
            final row = byAddress[k.wallet]!;
            if (row.native.isNegative ||
                row.nonce < 0 ||
                (k.token.isNotEmpty &&
                    (row.tokenBalance == null ||
                        row.tokenBalance!.isNegative ||
                        (k.spender != _withoutAllowance &&
                            (row.routerAllowance == null ||
                                row.routerAllowance!.isNegative))))) {
              throw const BackendException(
                'WALLET_INCOMPLETE',
                '钱包余额或授权读取不完整，请刷新后重试',
                true,
              );
            }
          }
          for (final k in keys) {
            _store(k, byAddress[k.wallet]!);
          }
        })
        .whenComplete(() {
          for (final k in keys) {
            if (identical(_reads[k], task)) _reads.remove(k);
          }
        });
    for (final k in keys) {
      _reads[k] = task;
    }
    return task;
  }

  void observe(TxRecord record) {
    final p = _pending[record.hash.toLowerCase()];
    if (p == null || !record.finished) return;
    p.terminal = record;
    // Apply a bundle in submitted order for dependent wallets. Independent
    // wallets can settle immediately even when an earlier status is unknown.
    final blocked = <String>{};
    for (final e in _pending.entries.toList()) {
      final change = e.value;
      final result = change.terminal;
      if (result == null || change.affected.any(blocked.contains)) {
        blocked.addAll(change.affected);
        continue;
      }
      _pending.remove(e.key);
      if (result.status == 'confirmed' || result.status == 'reverted') {
        _signed.remove(e.key);
        _apply(change, result);
      }
      _touch(change.affected);
    }
  }

  void _apply(_SignedChange change, TxRecord result) {
    final receipt = result.receipt;
    final owner = change.owner;
    final tx = change.tx;
    final to = tx.to?.toLowerCase() ?? '';
    final success = result.status == 'confirmed';
    final deltas = <String, BigInt>{};
    final tokenDeltas = <(String, String), BigInt>{};
    final approvals = <(String, String, String), BigInt>{};
    final uncertain = <String>{};
    final unknownTokens = <(String, String)>{};
    try {
      if (receipt == null || hasConflictingReceiptLogs(receipt) ||
          receipt['transactionHash']?.toString().toLowerCase() !=
              result.hash.toLowerCase() ||
          receipt['from']?.toString().toLowerCase() != owner ||
          (receipt['to']?.toString().toLowerCase() ?? '') != to ||
          _number(receipt['status']) != (success ? BigInt.one : BigInt.zero)) {
        throw const FormatException();
      }
      final gasUsed = _number(receipt['gasUsed']);
      if (gasUsed > BigInt.from(tx.gasLimit) || gasUsed == BigInt.zero)
        throw const FormatException();
      final price = receipt['effectiveGasPrice'] == null
          ? tx.gasPrice
          : _number(receipt['effectiveGasPrice']);
      if (price != tx.gasPrice)
        throw const FormatException(); // legacy BSC transaction
      deltas[owner] = -gasUsed * price;
      if (success) {
        BigInt? nativeMove;
        final target = tx.data.isEmpty ? to : null;
        // A plain EOA transfer has the intrinsic gas cost. Contract recipients can return BNB.
        if (target != null &&
            target.isNotEmpty &&
            gasUsed == BigInt.from(21000)) {
          nativeMove = -tx.value;
          deltas.update(target, (v) => v + tx.value, ifAbsent: () => tx.value);
        } else if (change.isApprove || change.isTransfer) {
          if (tx.value == BigInt.zero) nativeMove = BigInt.zero;
        }
        final logs = receipt['logs'];
        if (logs is! List) throw const FormatException();
        for (final log in logs) {
          if (log is! Map || log['topics'] is! List)
            throw const FormatException();
          final topics = log['topics'] as List;
          final asset = log['address'].toString().toLowerCase();
          if (topics.isEmpty) continue;
          final sig = topics.first.toString().toLowerCase();
          if ((sig == _transfer || sig == _approval) && topics.length == 3) {
            final source = _address(topics[1]), recipient = _address(topics[2]);
            final value = _words(log['data'], 1).single;
            if (sig == _transfer) {
              for (final e in [(source, -value), (recipient, value)]) {
                tokenDeltas.update(
                  (e.$1, asset),
                  (v) => v + e.$2,
                  ifAbsent: () => e.$2,
                );
              }
            } else {
              approvals[(source, asset, recipient)] = value;
            }
          }
        }
        if (change.isTransfer) {
          for (final w in change.affected) {
            if (!tokenDeltas.containsKey((w, to))) unknownTokens.add((w, to));
          }
        }
        if (nativeMove == null) {
          uncertain.addAll(change.affected);
        } else {
          deltas.update(
            owner,
            (v) => v + nativeMove!,
            ifAbsent: () => nativeMove!,
          );
        }
      }
    } on Object {
      uncertain.addAll({
        ...change.affected,
        ...tokenDeltas.keys.map((k) => k.$1),
        ...approvals.keys.map((k) => k.$1),
      });
    }
    final changed = {
      ...change.affected,
      ...deltas.keys,
      ...tokenDeltas.keys.map((k) => k.$1),
      ...approvals.keys.map((k) => k.$1),
    };
    _touch(
      changed.where(
        (w) =>
            change.affected.contains(w) ||
            _reads.keys.any((k) => k.wallet == w) ||
            _viewsByWallet.containsKey(w),
      ),
    );
    for (final key in changed.expand(
      (w) => _viewsByWallet[w] ?? const <_View>{},
    )) {
      final old = _book[key];
      if (old == null) continue;
      final w = key.wallet;
      if (uncertain.contains(w) || unknownTokens.contains((w, key.token))) {
        if (success && _swapOrigins.containsKey(result.hash.toLowerCase())) {
          // The UXUY router has no documented net-native receipt event. Re-read
          // this owner's balance, nonce and allowance on the next snapshot.
          _book.remove(key);
        } else {
          _book[key] = null;
        }
        continue;
      }
      final native = old.native + (deltas[w] ?? BigInt.zero);
      final bal = old.tokenBalance == null
          ? null
          : old.tokenBalance! + (tokenDeltas[(w, key.token)] ?? BigInt.zero);
      if (native.isNegative || (bal?.isNegative ?? false)) {
        _book[key] = null;
        continue;
      }
      var allowance = old.routerAllowance;
      final spender = key.spender;
      // A nonstandard token may silently ignore approve(). Never infer the amount from calldata.
      if (success &&
          w == owner &&
          change.isApprove &&
          key.token == to &&
          change.recipient == spender)
        allowance = null;
      allowance = approvals[(w, key.token, spender)] ?? allowance;
      if (success &&
          change.isApprove &&
          w == owner &&
          key.token == to &&
          change.recipient == spender &&
          allowance == null) {
        _book[key] = null;
        continue;
      }
      _book[key] = WalletState(
        old.wallet,
        native,
        w == owner ? max(old.nonce, tx.nonce + 1) : old.nonce,
        bal,
        allowance,
      );
    }
  }

  Future<({BigInt native, BigInt tokens})> linkedTradeDelta(
    List<String> hashes,
    String token,
    bool buy,
  ) async {
    var native = BigInt.zero;
    var tokens = BigInt.zero;
    final unique = hashes.map((h) => h.toLowerCase()).toSet().toList();
    if (unique.isNotEmpty && api._router == null) await api.config();
    final hashesToRead = <String>{for (final h in unique) ...(_swapOrigins[h]?.legs ?? [h])}.toList();
    final groups = <String, List<({String hash, Map? receipt, BigInt native, BigInt tokens})>>{};
    for (var start = 0; start < hashesToRead.length; start += 100) {
      final batch = hashesToRead.skip(start).take(100).toList();
      final receipts = await api.rpc([
        for (final hash in batch) ('eth_getTransactionReceipt', [hash]),
      ]);
      // Bound concurrent transaction traces used to verify the native legs.
      for (var i = 0; i < batch.length; i += 8) {
        final parts = await Future.wait([
          for (var j = i; j < min(i + 8, batch.length); j++)
            _tradePrincipal(batch[j], receipts[j], token, buy),
        ]);
        for (final (offset, part) in parts.indexed) {
          final hash = batch[i + offset];
          final order = _swapOrigins[hash]?.legs;
          if (order != null && order.length > 1) {
            final receipt = receipts[i + offset];
            (groups[order.last] ??= []).add((hash: hash, receipt: receipt as Map?, native: part.native, tokens: part.tokens));
          }
          native += part.native;
          tokens += part.tokens;
        }
      }
    }
    for (final entries in groups.values) {
      final expected = _swapOrigins[entries.first.hash]!.legs!;
      if (entries.every((e) => e.receipt == null)) continue;
      var position = -BigInt.one;
      final block = entries.first.receipt?['blockHash'];
      if (block is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(block) ||
          entries.length != expected.length) throw _incompleteTrade;
      for (final (i, e) in entries.indexed) {
        if (e.hash != expected[i] || e.receipt?['blockHash'] != block ||
            _number(e.receipt?['status']) != BigInt.one ||
            _number(e.receipt?['transactionIndex']) <= position) throw _incompleteTrade;
        position = _number(e.receipt?['transactionIndex']);
      }
      if (entries.fold(BigInt.zero,(v,e) => v + e.native) <= BigInt.zero ||
          entries.fold(BigInt.zero,(v,e) => v + e.tokens) <= BigInt.zero) throw _incompleteTrade;
    }
    return (native: native, tokens: tokens);
  }

  static const _incompleteTrade = BackendException(
    'INCOMPLETE_RECEIPT',
    '原交易的成交凭据暂不完整',
    true,
  );

  Future<({BigInt native, BigInt tokens})> _tradePrincipal(
    String hash,
    Object? raw,
    String token,
    bool buy,
  ) async {
    final zero = (native: BigInt.zero, tokens: BigInt.zero);
    if (raw == null) {
      final proof = await api.reconcileStatus(hash);
      if (proof.refused || proof.status == 'not_included') return zero;
      throw _incompleteTrade;
    }
    if (raw is! Map || hasConflictingReceiptLogs(raw) ||
        raw['transactionHash']?.toString().toLowerCase() != hash) {
      throw _incompleteTrade;
    }
    final status = _number(raw['status']);
    if (status == BigInt.zero) return zero;
    final owner = raw['from']?.toString().toLowerCase() ?? '';
    final router = raw['to']?.toString().toLowerCase() ?? '';
    final logs = raw['logs'];
    if (status != BigInt.one ||
        !isAddress(owner) ||
        !isAddress(router) ||
        logs is! List) {
      throw _incompleteTrade;
    }
    final origin = _swapOrigins[hash];
    if (router != (origin?.router ?? api._router) ||
        (origin != null && owner != origin.wallet)) {
      throw _incompleteTrade;
    }
    var tokenNet = BigInt.zero;
    var hasTransfer = false;
    for (final log in logs) {
      if (log is! Map || log['topics'] is! List) throw _incompleteTrade;
      final topics = log['topics'] as List;
      if (topics.isEmpty) continue;
      final emitter = log['address']?.toString().toLowerCase();
      final topic = topics.first.toString().toLowerCase();
      if (emitter == token && topic == _transfer && topics.length == 3) {
        final from = _address(topics[1]), to = _address(topics[2]);
        if (from == owner || to == owner) {
          final value = _words(log['data'], 1).single;
          hasTransfer = true;
          if (to == owner) tokenNet += value;
          if (from == owner) tokenNet -= value;
        }
      }
    }
    final multi = (origin?.legs?.length ?? 0) > 1;
    if (!hasTransfer && !multi) throw _incompleteTrade;
    final nativeChange = await _nativePrincipalChange(hash, owner, raw);
    final principal = buy ? -nativeChange : nativeChange;
    final quantity = buy ? tokenNet : -tokenNet;
    if (!multi && (principal <= BigInt.zero || quantity <= BigInt.zero))
      throw _incompleteTrade;
    return (native: principal, tokens: quantity);
  }

  // Attribute only this mined transaction's net BNB movement, excluding paid gas.
  Future<BigInt> _nativePrincipalChange(
    String hash,
    String owner,
    Map receipt,
  ) async {
    final gas = _number(receipt['gasUsed']);
    final price = _number(receipt['effectiveGasPrice']);
    if (gas == BigInt.zero) throw _incompleteTrade;
    final trace = (await api.rpc([
      (
        'debug_traceTransaction',
        [
          hash,
          {
            'tracer': 'prestateTracer',
            'tracerConfig': {
              'diffMode': true,
              'disableCode': true,
              'disableStorage': true,
            },
          },
        ],
      ),
    ])).single;
    if (trace is! Map) throw _incompleteTrade;
    BigInt balance(Object? accounts) {
      if (accounts is! Map) throw _incompleteTrade;
      for (final e in accounts.entries) {
        if (e.key.toString().toLowerCase() == owner && e.value is Map) {
          return _number(e.value['balance']);
        }
      }
      throw _incompleteTrade;
    }

    return balance(trace['post']) - balance(trace['pre']) + gas * price;
  }

  static final _approval = _topic('Approval(address,address,uint256)');
  static final _transfer = _topic('Transfer(address,address,uint256)');
  static String _topic(String s) => bytesToHex(keccak256(s.codeUnits));
  static BigInt _number(dynamic s) {
    if (s is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(s))
      throw const FormatException();
    return BigInt.parse(s.substring(2), radix: 16);
  }

  static String _address(dynamic topic) {
    if (topic is! String ||
        !RegExp(r'^0x0{24}[0-9a-fA-F]{40}$').hasMatch(topic))
      throw const FormatException();
    return '0x${topic.substring(26).toLowerCase()}';
  }

  static List<BigInt> _words(dynamic data, int n) {
    if (data is! String || !data.startsWith('0x') || data.length != 2 + 64 * n)
      throw const FormatException();
    return [
      for (var i = 2; i < data.length; i += 64)
        BigInt.parse(data.substring(i, i + 64), radix: 16),
    ];
  }
}

class _BundleWindow {
  _BundleWindow(this.maxBlock, {required this.group});
  int maxBlock;
  final bool group;
  bool submitting = true;
}

class _SignedChange {
  _SignedChange(this.owner, this.tx, this.refreshEpoch);
  final int refreshEpoch;
  final String owner;
  final LegacyTx tx;
  List<String>? innerLegs;
  TxRecord? terminal;
  Object? schedule;
  _BundleWindow? window;
  DateTime? lastProof;
  late final selector = tx.data.length != 68
      ? ''
      : bytesToHex(tx.data.sublist(0, 4));
  bool get isApprove => selector == '0x095ea7b3';
  bool get isTransfer => selector == '0xa9059cbb';
  String get recipient => bytesToHex(tx.data.sublist(16, 36));
  late final affected = {
    owner,
    if (tx.data.isEmpty && tx.to != null) tx.to!.toLowerCase(),
    if (isTransfer) recipient,
  };
}
