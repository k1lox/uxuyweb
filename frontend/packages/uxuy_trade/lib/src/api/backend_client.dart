import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../crypto/keccak.dart';
import '../evm/evm.dart';
import '../exec/market.dart';
import '../wallet/wallet.dart';

part 'wallet_ledger.dart';

/// Client for the UXUY trade backend. Uses only this module's own endpoint and never forwards host credentials.
class BackendClient {
  BackendClient(this.endpoint, this.http_, {this.requireFeeFreeService = false});

  final bool requireFeeFreeService;
  static const _unverifiedService = BackendException(
    'UNVERIFIED_SERVICE', '尚未核实本站收费配置，请重试。', true, notSubmitted: true,
  );
  static const _legacyFeeService = BackendException(
    'LEGACY_SERVICE_FEE', '当前服务仍配置了本站收费，资金操作已暂停。请切换到免收费的新版服务。', false,
    notSubmitted: true,
  );
  BackendException? _financialConfigError = _unverifiedService;
  BackendException? get financialConfigError =>
      requireFeeFreeService ? _financialConfigError : null;

  /// Private relay window for ordinary groups and linked funding, in BSC blocks.
  static const groupWindowBlocks = 40;

  late final _ledger = _WalletLedger(this);
  String? _router;
  String? _spender;
  bool? _fastPreflight;
  final Uri endpoint;
  final http.Client http_;

  Uri _u(String path) => endpoint.resolve('api/v1/$path');

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await http_.get(_u(path)).timeout(const Duration(seconds: 20));
    return _decode(r);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Object body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final r = await http_
        .post(
          _u(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    return _decode(r);
  }

  /// Only these read endpoints have an older, strictly decoded request schema.
  Future<Map<String, dynamic>> _readWithPreflight(
    String path,
    Map<String, Object?> Function(bool fast) encode, {
    Duration timeout = const Duration(seconds: 30),
    required bool extended,
  }) async {
    if (!extended || _fastPreflight == false)
      return _post(path, encode(false), timeout: timeout);
    final r = await http_
        .post(
          _u(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(encode(true)),
        )
        .timeout(timeout);
    if (_fastPreflight == null &&
        r.statusCode == 422 &&
        RegExp(
          'unknown field [^a-z]*(forecastOnly|skipAllowance)',
          caseSensitive: false,
        ).hasMatch(utf8.decode(r.bodyBytes, allowMalformed: true))) {
      _fastPreflight = false;
      return _post(path, encode(false), timeout: timeout);
    }
    return _decode(r);
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw BackendException(
        'BAD_RESPONSE',
        '服务返回格式异常（HTTP ${r.statusCode}）',
        true,
      );
    }
    if (body['ok'] != true) {
      throw BackendException(
        '${body['code'] ?? 'ERROR'}',
        '${body['message'] ?? '请求失败'}',
        body['retryable'] == true,
        notSubmitted: body['notSubmitted'] == true,
        data: body['data'] is Map
            ? (body['data'] as Map).cast<String, dynamic>()
            : null,
      );
    }
    return body;
  }

  Future<({int? ms, bool limited})> nodeLatency() async {
    final row = await _get('rpc-latency');
    return (ms: row['ms'] as int?, limited: row['limited'] == true);
  }

  Future<ModuleConfig>? _readingConfig;
  Future<ModuleConfig> config() => _readingConfig ??= _readConfig()
      .whenComplete(() => _readingConfig = null);

  Future<ModuleConfig> _readConfig() async {
    late final Map<String, dynamic> response;
    try {
      response = await _get('config');
    } on Object {
      _financialConfigError = _unverifiedService;
      rethrow;
    }
    if (requireFeeFreeService) {
      _financialConfigError = _unverifiedService;
      for (final field in ['feeRate', 'launchServiceFeeWei']) {
        if (!response.containsKey(field)) continue;
        final fee = BigInt.tryParse('${response[field]}');
        if (fee == null || fee.isNegative) throw _unverifiedService;
        if (fee > BigInt.zero) {
          _financialConfigError = _legacyFeeService;
          throw _legacyFeeService;
        }
      }
      if (response['routeSource'] != 'uxuy') throw _unverifiedService;
    }
    _fastPreflight = ((response['fastPreflightVersion'] as num?) ?? 0) >= 1;
    final c = ModuleConfig.fromJson(response);
    _router = c.router.toLowerCase();
    _spender = c.approvalSpender?.toLowerCase();
    _financialConfigError = null;
    return c;
  }

  // ---------------------------------------------------------------- launchpad official integrations
  // Paths outside /api/v1 keep the original site's proxy routes (/api/fourmeme, /api/flap, /api/genius/image).

  Uri _root(String path, [Map<String, String>? query]) =>
      endpoint.resolve(path).replace(queryParameters: query);

  /// Four.meme proxy: config / nonce / login / create / predictTokenAddress. Returns the official payload.
  Future<Object?> four(
    String action, [
    Map<String, Object?> payload = const {},
  ]) async {
    final r = await http_
        .post(
          _root('api/fourmeme'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'action': action, ...payload}),
        )
        .timeout(const Duration(seconds: 45));
    return _decode(r)['payload'];
  }

  Future<Object?> _multipart(
    Uri uri,
    LaunchImage image,
    Map<String, String> fields,
  ) async {
    final req = http.MultipartRequest('POST', uri)
      ..fields.addAll(fields)
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          image.bytes,
          filename: image.filename,
          contentType: _mediaType(image.mime),
        ),
      );
    final res = await http.Response.fromStream(
      await http_.send(req).timeout(const Duration(seconds: 90)),
    );
    return _decode(res)['payload'];
  }

  static MediaType _mediaType(String mime) =>
      MediaType.parse(mime.isEmpty ? 'application/octet-stream' : mime);

  Future<Object?> fourUpload(String accessToken, LaunchImage image) =>
      _multipart(_root('api/fourmeme'), image, {'accessToken': accessToken});

  /// Flap: payment catalog (no action), customCatalog, curveSignature, creationCurve.
  Future<Object?> flap([Map<String, String>? query]) async => _decode(
    await http_
        .get(_root('api/flap', query))
        .timeout(const Duration(seconds: 30)),
  )['payload'];

  Future<Object?> flapUpload(LaunchImage image, Map<String, String> fields) =>
      _multipart(_root('api/flap'), image, fields);

  /// Genius image upload, authorised by a personal_sign of the image hash (web geniusImage.ts).
  Future<Map<String, dynamic>> geniusUpload(
    LaunchImage image, {
    required String address,
    required String signature,
    required String timestamp,
  }) async {
    final r = await http_
        .post(
          _root('api/genius/image'),
          headers: {
            'content-type': image.mime,
            'x-upload-address': address,
            'x-upload-signature': signature,
            'x-upload-timestamp': timestamp,
          },
          body: image.bytes,
        )
        .timeout(const Duration(seconds: 90));
    return _plain(r);
  }

  Future<Map<String, dynamic>> geniusUploadStatus(
    String uploadId,
    String capability,
  ) async => _plain(
    await http_
        .get(
          _root('api/genius/image', {'uploadId': uploadId}),
          headers: {'x-upload-capability': capability},
        )
        .timeout(const Duration(seconds: 30)),
  );

  Map<String, dynamic> _plain(http.Response r) {
    final body = jsonDecode(utf8.decode(r.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw BackendException('BAD_RESPONSE', '服务返回格式异常', true);
    }
    if (r.statusCode >= 400 || body['ok'] == false) {
      throw BackendException(
        '${body['code'] ?? 'UPLOAD'}',
        '${body['message'] ?? body['error'] ?? 'Genius 图片请求失败（HTTP ${r.statusCode}）'}',
        false,
      );
    }
    return body;
  }

  Future<TokenMeta> token(String address) async => TokenMeta.fromJson(
    (await _get('tokens/$address'))['token'] as Map<String, dynamic>,
  );

  Future<GasInfo> gas() async {
    final j = await _get('gas');
    return GasInfo(BigInt.parse('${j['gasPrice']}'), j['blockNumber'] as int);
  }

  /// Balances, nonces and token allowance to [spender] (our router when omitted).
  Future<List<WalletState>> walletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) => _ledger.states(wallets, token: token, spender: spender);

  /// Local-only ownership lookup for outstanding operations in other groups.
  Iterable<String> pendingWalletsFor(Iterable<String> hashes) sync* {
    for (final hash in hashes) {
      final change = _ledger._pending[hash.toLowerCase()];
      if (change != null) yield* change.affected;
    }
  }

  /// Transfers do not spend an ERC-20 allowance. An explicit refresh reconciles the wallet on-chain.
  Future<List<WalletState>> transferWalletStates(
    List<String> wallets, {
    String? token,
    bool refresh = false,
  }) => _ledger.states(
    wallets,
    token: token,
    skipAllowance: true,
    refresh: refresh,
  );

  /// Background transfer previews read chain state without reconciling the signing ledger.
  Future<List<WalletState>> transferPreviewStates(List<String> wallets, {String? token}) =>
      _fetchWalletStates(wallets, token: token, skipAllowance: true);

  /// A user-requested chain reconciliation also refreshes previously used spenders.
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) => _ledger.states(wallets, token: token, spender: spender, refresh: true);
  Future<void> refreshKnownWallets() => _ledger.refreshKnown();

  /// Retain public accounting metadata only for this session's signed operations.
  SignedTx sign(TradeWallet wallet, LegacyTx tx) {
    final signed = wallet.sign(tx);
    _ledger.register(wallet.address, tx, signed);
    return signed;
  }

  Future<BigInt> nativeReceiptPrincipal(String hash, String wallet, Map receipt) =>
      _ledger._nativePrincipalChange(hash, wallet.toLowerCase(), receipt);

  /// Link the hashes of one ABI-verified inner-market order for later receipt reconciliation.
  void trackInnerRoute(List<SignedTx> transactions) => _ledger.trackInnerRoute(transactions);

  Future<List<WalletState>> _fetchWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
    bool skipAllowance = false,
  }) async {
    final j = await _readWithPreflight(
      'wallets/state',
      (fast) => {
        'wallets': wallets,
        'token': ?token,
        'spender': ?spender,
        if (fast && skipAllowance && token != null) 'skipAllowance': true,
      },
      extended: skipAllowance && token != null,
    );
    return [
      for (final w in j['wallets'] as List)
        WalletState.fromJson(w as Map<String, dynamic>),
    ];
  }

  /// A read-only chain snapshot for rapid-group monitoring. It does not mutate
  /// the signing ledger or invalidate other orders as manual refresh does.
  Future<List<WalletState>> rapidWalletStates(List<String> wallets, String token, String spender) =>
      _fetchWalletStates(wallets, token: token, spender: spender);

  Future<RoutePlan> route(RouteRequestData req) async => RoutePlan.fromJson(
    (await _readWithPreflight(
          'routes',
          (fast) => req.toJson(fast: fast),
          extended: req.forecastOnly,
        ))['plan']
        as Map<String, dynamic>,
  );

  /// Verify a finite, approval-only batch against the configured BSC spender.
  /// Fresh swap quotes are obtained separately after the allowance is on chain.
  Future<int> checkSellApprovals(String token, String spender, List<({String wallet, BigInt amount, bool reset})> rows) =>
    _checkApprovals(token, spender, rows, launchPayment: false);

  Future<int> checkInnerApprovals(String token, String spender, List<({String wallet, BigInt amount, bool reset})> rows,
      {required String innerPlatform, required String innerToken,Map<String,int> orderCounts=const {}}) =>
    _checkApprovals(token, spender, rows, launchPayment: false, innerPlatform: innerPlatform, innerToken: innerToken,orderCounts:orderCounts);

  Future<int> checkLaunchPayments(String token, String spender, List<({String wallet, BigInt amount, bool reset})> rows, {Map<String,Object?>? launchContext}) =>
    _checkApprovals(token, spender, rows, launchPayment: true, launchContext: launchContext);

  Future<int> checkLaunchPayment(String token, String spender, String wallet, BigInt amount, {required bool reset, Map<String,Object?>? launchContext, int? permitExpiration}) =>
    _checkApprovals(token, spender, [(wallet:wallet, amount:amount, reset:reset)], launchPayment: true, launchContext: launchContext, permitExpiration: permitExpiration);

  Future<int> _checkApprovals(String token, String spender, List<({String wallet, BigInt amount, bool reset})> rows, {required bool launchPayment, Map<String,Object?>? launchContext, int? permitExpiration, String? innerPlatform, String? innerToken,Map<String,int> orderCounts=const {}}) async {
    final response = await _post('approvals/check', {
      'token': token,
      if (launchPayment) 'launchSpender': spender,
      'innerPlatform': ?innerPlatform,
      'innerToken': ?innerToken,
      if (innerPlatform != null) 'spender': spender,
      if (launchContext != null) 'launchContext': launchContext,
      if (permitExpiration != null) 'permitExpiration': permitExpiration,
      'wallets': [for (final row in rows) {'wallet':row.wallet, 'amount':row.amount.toString(), 'reset':row.reset, if(innerPlatform!=null) 'orders':orderCounts[row.wallet.toLowerCase()]??1}],
    });
    final result = response['wallets'];
    final deadline = response['deadline'];
    if (response['permitExpiration'] != permitExpiration || response['chainId'] != 56 || '${response['token']}'.toLowerCase() != token.toLowerCase() ||
        '${response['spender']}'.toLowerCase() != spender.toLowerCase() || result is! List || result.length != rows.length || deadline is! int) {
      throw const BackendException('BAD_APPROVAL', '服务器返回的授权目标与本次检查不符', false);
    }
    for (var i = 0; i < rows.length; i++) {
      final row = result[i];
      if (row is! Map || '${row['wallet']}'.toLowerCase() != rows[i].wallet.toLowerCase() || row['amount'] != rows[i].amount.toString()) {
        throw const BackendException('BAD_APPROVAL', '服务器返回的授权钱包或额度不符', false);
      }
    }
    return deadline;
  }

  /// Maximum number of pairs in a UXUY batch request.
  static const routeChunk = 20;

  /// One UXUY route per wallet amount, in request order; failures are returned per item.
  Future<List<RouteResult>> routes(List<RouteRequestData> reqs) async {
    final out = <RouteResult>[];
    for (var i = 0; i < reqs.length; i += routeChunk) {
      final part = reqs.sublist(i, min(i + routeChunk, reqs.length));
      final j = await _readWithPreflight(
        'routes/batch',
        (fast) => {
          'requests': [for (final r in part) r.toJson(fast: fast)],
        },
        extended: part.any((r) => r.forecastOnly),
        timeout: Duration(seconds: 30 + part.length * 3),
      );
      out.addAll(_routeResults(j, part.length));
    }
    return out;
  }

  /// Aggregate impact preview plus independently quoted executable wallet calls.
  Future<({RoutePlan group, List<RoutePlan> wallets})> bundleRoute(
    List<RouteRequestData> requests,
  ) async {
    final response = await _post('routes/bundle', {
      'requests': [for (final request in requests) request.toJson()],
    });
    final group = response['groupPlan'];
    if (group is! Map<String, dynamic>) {
      throw const BackendException('BAD_RESPONSE', '缺少整组报价', false);
    }
    final rows = _routeResults(
      response,
      requests.first.forecastOnly ? 0 : requests.length,
    );
    final wallets = <RoutePlan>[];
    for (final row in rows) {
      if (row.error != null) throw row.error!;
      wallets.add(row.plan!);
    }
    return (group: RoutePlan.fromJson(group), wallets: wallets);
  }

  static List<RouteResult> _routeResults(Map<String, dynamic> body, int count) {
    final rows = body['results'];
    if (rows is! List || rows.length != count) {
      throw const BackendException('BAD_RESPONSE', '路径返回数量不一致', true);
    }
    return [
      for (final row in rows.cast<Map<String, dynamic>>())
        if (row['ok'] == true)
          RouteResult.ok(
            RoutePlan.fromJson(row['plan'] as Map<String, dynamic>),
          )
        else
          RouteResult.failed(
            BackendException(
              '${row['code']}',
              '${row['message']}',
              row['retryable'] == true,
            ),
          ),
    ];
  }

  /// Submit signed transactions in order (same-sender nonces must be consecutive).
  /// Hashes are registered before broadcast; an unclear network result stays "ambiguous", never resent.
  Future<List<TxRecord>> submitAll(List<String> raws) async {
    final blocked = financialConfigError;
    if (blocked != null) throw blocked;
    final j = await _ledger.submitting(
      raws,
      () => _post('transactions/bsc', {
        'transactions': raws,
      }, timeout: const Duration(seconds: 60)),
    );
    final rows = [
      for (final r in j['result'] as List)
        TxRecord.fromJson(r as Map<String, dynamic>),
    ];
    for (final row in rows) {
      _ledger.observe(row);
    }
    return rows;
  }

  Future<TxRecord> submit(String raw) async => (await submitAll([raw])).single;

  /// Receipt-based status. Unknown hashes return a pending record.
  Future<TxRecord> status(String hash) =>
      _transactionStatus(hash, tracked: true);

  /// User-requested reconciliation of an original hash against the chain.
  Future<TxRecord> reconcileStatus(String hash) =>
      _transactionStatus(hash, tracked: false);

  /// Actual trade principal from the original swap receipts, independent of later wallet activity.
  Future<({BigInt native, BigInt tokens})> linkedTradeDelta(
    List<String> hashes, {
    required String token,
    required bool buy,
  }) => _ledger.linkedTradeDelta(hashes, token.toLowerCase(), buy);

  Future<TxRecord> _transactionStatus(
    String hash, {
    required bool tracked,
  }) async {
    final j = await _get('transactions/bsc/$hash?tracked=$tracked');
    if (!j.containsKey('result')) {
      throw const BackendException('BAD_RESPONSE', '交易查询结果不完整', true);
    }
    final r = j['result'];
    final result = r == null
        ? TxRecord(hash, 'ambiguous', null, recorded: false)
        : TxRecord.fromJson(r as Map<String, dynamic>);
    if (result.hash.toLowerCase() != hash.toLowerCase()) {
      throw const BackendException('BAD_RESPONSE', '交易回执哈希不符', true);
    }
    if (result.receipt case final Map receipt) {
      final expectedStatus = switch (result.status) {
        'confirmed' => '0x1', 'reverted' => '0x0', _ => null,
      };
      if (hasConflictingReceiptLogs(receipt) ||
          (expectedStatus != null &&
              (receipt['status'] != expectedStatus ||
               receipt['transactionHash']?.toString().toLowerCase() != hash.toLowerCase()))) {
        // A service may have cached the old receipt before the chain reorganized.
        // Keep the original nonce reserved until the chain supplies coherent evidence.
        return _ledger.resolveMissing(
          TxRecord(hash, 'ambiguous', null, recorded: false), manual: !tracked,
        );
      }
    }
    if (!result.recorded)
      return _ledger.resolveMissing(result, manual: !tracked);
    final window = _ledger._pending[hash.toLowerCase()]?.window;
    if (window != null &&
        window.group &&
        {'not_included', 'rejected', 'not_submitted'}.contains(result.status) &&
        (window.submitting ||
            r['maxBlockNumber'] is int &&
                r['maxBlockNumber'] < window.maxBlock)) {
      // A GET started before resubmission can finish with the previous window's expiry.
      return _ledger.resolveMissing(
        TxRecord(hash, 'ambiguous', null, recorded: false),
        manual: !tracked,
      );
    }
    _ledger.observe(result);
    return result;
  }

  /// BSC private bundle; returns the relay response (bundle hash when accepted).
  Future<Map<String, dynamic>> bundle(
    List<String> raws,
    int maxBlockNumber,
  ) => _bundle(raws, maxBlockNumber);

  /// Rapid fixed orders can pipeline consecutive nonces within one private
  /// schedule. All other operations retain the ordinary exclusive wallet lock.
  Future<Map<String, dynamic>> rapidBundle(String raw, int maxBlockNumber, Object schedule) =>
      _bundle([raw], maxBlockNumber, schedule: schedule);

  Future<
    ({
      BigInt before,
      BigInt received,
      BigInt sellAmount,
      int buyGas,
      int sellGas,
      List<Map<String, dynamic>> buyApprovals,
      List<Map<String, dynamic>> sellApprovals,
    })
  >
  checkRapidRoundTrip(
    RouteRequestData buy,
    BigInt sellValue,
    bool percentSell, {required int buyOrders,required int sellOrders}
  ) async {
    final proof = await _post('routes/rapid-check', {
      'buy': buy.toJson(),
      'sellValue': sellValue.toString(),
      'percentSell': percentSell,'buyOrders':buyOrders,'sellOrders':sellOrders,
    });
    final before = BigInt.tryParse('${proof['before']}'),
        received = BigInt.tryParse('${proof['received']}'),
        sell = BigInt.tryParse('${proof['sellAmount']}');
    final buyGas = proof['buyGas'], sellGas = proof['sellGas'];
    final units = percentSell
        ? ((before ?? BigInt.zero) + (received ?? BigInt.zero)) *
              sellValue ~/
              BigInt.from(10000)
        : sellValue;
    if (proof['ok'] != true ||
        '${proof['wallet']}'.toLowerCase() != buy.wallet.toLowerCase() ||
        '${proof['token']}'.toLowerCase() != buy.token.toLowerCase() ||
        before == null ||
        before < BigInt.zero ||
        received == null ||
        received <= BigInt.zero ||
        sell == null ||
        sell <= BigInt.zero ||
        sell > before + received ||
        sell != (buy.market?.sellUnits(units) ?? units) ||
        buyGas is! int ||
        buyGas < 21000 ||
        buyGas > 30000000 ||
        sellGas is! int ||
        sellGas < 21000 ||
        sellGas > 30000000) {
      throw StateError('快速组首买首卖模拟结果与订单不符');
    }
    return (
      before: before,
      received: received,
      sellAmount: sell,
      buyGas: buyGas,
      sellGas: sellGas,
      buyApprovals: (proof['buyApprovals'] as List)
          .cast<Map<String, dynamic>>(),
      sellApprovals: (proof['sellApprovals'] as List)
          .cast<Map<String, dynamic>>(),
    );
  }

  Future<void> requireIdleRapidWallets(List<String> owners) async {
    for (var start = 0; start < owners.length; start += 100) {
      final chunk = owners.skip(start).take(100).toList();
      final results = await rpc([
        for (final owner in chunk)
          for (final tag in ['latest', 'pending'])
            ('eth_getTransactionCount', [owner, tag]),
      ]);
      for (var i = 0; i < chunk.length; i++) {
        int? nonce(Object? value) =>
            value is String && RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(value)
            ? int.tryParse(value.substring(2), radix: 16)
            : null;
        final mined = nonce(results[2 * i]),
            pending = nonce(results[2 * i + 1]);
        if (mined == null || pending == null) throw StateError('钱包 nonce 回查失败');
        if (mined != pending) throw StateError('${chunk[i]} 有待确认交易，请核实后再开始快速组');
      }
    }
  }

  Future<Map<String, dynamic>> groupBundle(
    List<String> raws,
    int maxBlock, {
    required bool Function() active,
    Object? schedule,
  }) => _bundle(raws, maxBlock, schedule: schedule, retryWhile: active);

  Future<Map<String, dynamic>> _bundle(
    List<String> raws,
    int maxBlockNumber, {
    Object? schedule,
    bool Function()? retryWhile,
  }) async {
    final blocked = financialConfigError;
    if (blocked != null) throw blocked;
    final bytes = List<String>.unmodifiable(raws);
    final window = _BundleWindow(maxBlockNumber, group: retryWhile != null);
    final timer = Stopwatch()..start();
    const budget = Duration(seconds: 90);
    const unknown = BackendException(
      'SUBMISSION_UNKNOWN',
      '提交回执未知，请查询原交易',
      true,
    );

    bool live() => (retryWhile?.call() ?? true) && timer.elapsed < budget;
    Future<Map<String, dynamic>> send() async {
      final remaining = budget - timer.elapsed;
      const limit = Duration(seconds: 60);
      final j = await _post('bundles', {
        'transactions': bytes,
        'maxBlockNumber': window.maxBlock,
      }, timeout: remaining < limit ? remaining : limit);
      final result = j['result'];
      if (result is! Map ||
          !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch('${result['bundleHash']}')) {
        throw const BackendException('BAD_RESPONSE', '捆绑接收回执不完整', true);
      }
      return result.cast<String, dynamic>();
    }

    Future<Map<String, dynamic>> submit() async {
      var mayReplay = false;
      if (!live()) {
        throw const BackendException(
          'GROUP_STOPPED',
          '已停止未提交的交易',
          false,
          notSubmitted: true,
        );
      }
      try {
        return await send();
      } catch (first) {
        if (retryWhile == null ||
            first is BackendException && first.notSubmitted)
          rethrow;
        mayReplay = _retryableBundleFailure(first);
      }

      final hashes = [
        for (final raw in bytes) bytesToHex(keccak256(hexToBytes(raw))),
      ];
      // BotAI allows three attempts in 90 seconds. The first POST can still
      // arrive after a timeout; every subsequent POST retains its exact bytes.
      for (var retry = 1; retry <= 2 && live(); retry++) {
        final wait = Duration(seconds: retry),
            remaining = budget - timer.elapsed;
        await Future<void>.delayed(wait < remaining ? wait : remaining);
        if (!live()) break;
        try {
          final proof = await _bundleProof(
            hashes,
            live,
            () => mayReplay = false,
          ).timeout(budget - timer.elapsed);
          if (proof.acknowledged) {
            return {'recovered': true, 'transactionHashes': hashes};
          }
          if (!mayReplay || !live()) break;
          final height = await _replayHead(
            hashes,
            live,
          ).timeout(budget - timer.elapsed);
          if (height == null ||
              height < proof.minimumHead ||
              !live() ||
              hashes.any(
                (h) =>
                    !_ledger._pending.containsKey(h) ||
                    _ledger._pending[h]!.terminal != null,
              ))
            break;
          window.maxBlock = max(window.maxBlock, height + groupWindowBlocks);
          return await send();
        } catch (error) {
          // A rejection of a later attempt cannot resolve an earlier lost reply.
          if (!_retryableBundleFailure(error)) break;
        }
      }
      throw unknown;
    }

    try {
      return await _ledger.submitting(
        bytes,
        submit,
        window: window,
        schedule: schedule,
      );
    } finally {
      window.submitting = false;
    }
  }

  bool _retryableBundleFailure(Object e) =>
      e is TimeoutException ||
      e is http.ClientException ||
      e is BackendException && e.retryable && !e.notSubmitted;

  // An independent transaction can consume the nonce even when the original
  // hash is absent. Pipelined private groups may legitimately have earlier nonces.
  Future<int?> _replayHead(List<String> hashes, bool Function() live) async {
    final firstNonce = <String, int>{};
    for (final h in hashes) {
      final change = _ledger._pending[h];
      if (change == null || change.terminal != null) return null;
      firstNonce.update(
        change.owner,
        (n) => min(n, change.tx.nonce),
        ifAbsent: () => change.tx.nonce,
      );
    }
    final owners = firstNonce.keys.toList();
    int? quantity(Object? value) =>
        value is String && RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(value)
        ? int.tryParse(value.substring(2), radix: 16)
        : null;
    for (var i = 0; i < owners.length; i += 80) {
      if (!live()) return null;
      final chunk = owners.skip(i).take(80).toList();
      final values = await rpc([
        for (final owner in chunk)
          for (final tag in ['latest', 'pending'])
            ('eth_getTransactionCount', [owner, tag]),
      ]);
      for (var j = 0; j < chunk.length; j++) {
        final mined = quantity(values[2 * j]);
        final pending = quantity(values[2 * j + 1]);
        if (mined == null ||
            pending == null ||
            pending < mined ||
            pending > firstNonce[chunk[j]]!) {
          return null;
        }
      }
    }
    if (!live()) return null;
    return quantity((await rpc([('eth_blockNumber', [])])).single);
  }

  /// Pending node transactions, incomplete receipts and ambiguous service
  /// claims prevent replay. Only a complete, hash-bound group can resume polling.
  Future<({bool acknowledged, int minimumHead})> _bundleProof(
    List<String> hashes,
    bool Function() live,
    void Function() preventReplay,
  ) async {
    var minimumHead = 0;
    final acknowledged = <String>{};
    for (var i = 0; i < hashes.length; i += 80) {
      if (!live()) return (acknowledged: false, minimumHead: 0);
      final chunk = hashes.skip(i).take(80).toList();
      final evidence = await rpc([
        for (final h in chunk) ...[
          ('eth_getTransactionReceipt', [h]),
          ('eth_getTransactionByHash', [h]),
        ],
      ]);
      for (var j = 0; j < chunk.length; j++) {
        final receipt = evidence[2 * j];
        if (receipt != null || evidence[2 * j + 1] != null) preventReplay();
        if (receipt is Map && !hasConflictingReceiptLogs(receipt) &&
            receipt['transactionHash']?.toString().toLowerCase() == chunk[j] &&
            {'0x0', '0x1'}.contains(receipt['status']) &&
            RegExp(r'^0x[0-9a-fA-F]+$').hasMatch('${receipt['blockNumber']}')) {
          acknowledged.add(chunk[j]);
        }
      }
    }
    final missing = hashes.where((h) => !acknowledged.contains(h)).toList();
    for (var i = 0; i < missing.length; i += 12) {
      if (!live()) return (acknowledged: false, minimumHead: 0);
      final chunk = missing.skip(i).take(12).toList();
      await Future.wait(
        chunk.map((hash) async {
          final response = await _bundleClaim(hash, live);
          final record = response['result'];
          if (record is Map &&
              record['transactionHash']?.toString().toLowerCase() == hash) {
            if (record['status'] == 'not_included' &&
                record['maxBlockNumber'] is int &&
                record['maxBlockNumber'] > 0) {
              minimumHead = max(
                minimumHead,
                (record['maxBlockNumber'] as int) + 4,
              );
              return;
            }
            if ({
              'accepted',
              'confirmed',
              'reverted',
            }.contains(record['status'])) {
              acknowledged.add(hash);
            }
          }
          // Retain positive evidence even if a different service read fails
          // or a lagging node later momentarily loses sight of this hash.
          if (!response.containsKey('result') || record != null)
            preventReplay();
        }),
      );
    }
    return (
      acknowledged: hashes.isNotEmpty && acknowledged.length == hashes.length,
      minimumHead: minimumHead,
    );
  }

  Future<Map<String, dynamic>> _bundleClaim(
    String hash,
    bool Function() live,
  ) async {
    final tracked = await _get('transactions/bsc/$hash?tracked=true');
    final record = tracked['result'];
    if (record is! Map ||
        record['transactionHash']?.toString().toLowerCase() != hash ||
        record['status'] != 'ambiguous' ||
        record['maxBlockNumber'] is! int ||
        !live())
      return tracked;
    // Refresh an unresolved relay claim. Only a terminal not_included proof
    // releases this hash and nonce. A disappearing record remains inconclusive.
    final refreshed = await _get('transactions/bsc/$hash?tracked=false');
    return refreshed['result'] == null ? tracked : refreshed;
  }

  /// Read-only JSON-RPC batch through the backend (no keys, no sends).
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    final body = [
      for (var i = 0; i < calls.length; i++)
        {
          'jsonrpc': '2.0',
          'id': i,
          'method': calls[i].$1,
          'params': calls[i].$2,
        },
    ];
    final r = await http_
        .post(
          _u('rpc/bsc'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      _decode(
        r,
      ); // Preserve the backend's structured error, including a plain HTTP 503.
      throw BackendException(
        'RPC_HTTP',
        '回执或节点数据读取失败（HTTP ${r.statusCode}）',
        true,
      );
    }
    final decoded = jsonDecode(utf8.decode(r.bodyBytes));
    if (decoded is! List) {
      final m = decoded as Map<String, dynamic>;
      throw BackendException(
        '${m['code'] ?? 'RPC'}',
        '${m['message'] ?? '读取失败'}',
        m['retryable'] == true,
      );
    }
    final byId = {
      for (final row in decoded.cast<Map<String, dynamic>>()) row['id']: row,
    };
    if (byId.length != calls.length ||
        decoded.length != calls.length ||
        !List.generate(calls.length, (i) => i).every(
          (i) =>
              byId[i]?.containsKey('result') == true ||
              byId[i]?['error'] != null,
        )) {
      throw const BackendException('BAD_RESPONSE', '节点返回的批量数据不完整', true);
    }
    return [
      for (var i = 0; i < calls.length; i++)
        if (byId[i]?['error'] != null)
          throw BackendException(
            'RPC_ERROR',
            '${(byId[i]!['error'] as Map)['message']}',
            false,
          )
        else
          byId[i]?['result'],
    ];
  }

  /// eth_call returning raw hex.
  Future<String> call(
    String to,
    String data, {
    String block = 'latest',
  }) async =>
      '${(await rpc([
        ('eth_call', [
          {'to': to, 'data': data},
          block,
        ]),
      ])).single}';

  /// Launchpad / market identification (Four, Flap, Genius, external), as in the web version.
  Future<Map<String, dynamic>> platform(
    String token, {
    int? blockNumber,
  }) async =>
      ((await _post('platforms/bsc', {
                'token': token,
                'blockNumber': ?blockNumber,
              }))['result']
              as Map)
          .cast<String, dynamic>();
}

const uxuyRouteFailed = BackendException(
  'UXUY_ROUTE_FAILED',
  'UXUY 交易路径无效',
  false,
);

class BackendException implements Exception {
  const BackendException(
    this.code,
    this.message,
    this.retryable, {
    this.data,
    this.notSubmitted = false,
  });
  final bool notSubmitted;
  final String code;
  final String message;
  final bool retryable;

  /// Structured detail of a backend error, e.g. `retryAfterSeconds` while an official API is cooling down.
  final Map<String, dynamic>? data;

  bool get isLiquidity =>
      code == 'LIQUIDITY_INSUFFICIENT' || code == 'PRICE_IMPACT_UNKNOWN';

  /// The backend's Four gate cannot use Four's official HTTP API right now (blocked, down, slow or busy).
  /// Only launching needs that API; it comes back by itself once Four answers the backend again.
  bool get isFourOfficialOutage => const {
    'FOUR_API_CHALLENGED',
    'FOUR_API_FORBIDDEN',
    'FOUR_API_UNAVAILABLE',
    'FOUR_API_TIMEOUT',
    'FOUR_API_BAD_RESPONSE',
    'FOUR_API_BUSY',
  }.contains(code);

  /// Seconds until the backend lets the next request through to the official API (null when not cooling).
  int? get retryAfterSeconds => switch (data?['retryAfterSeconds']) {
    final int s => s,
    _ => null,
  };

  /// What the user sees. Four official-API codes come from the backend's Four gate
  /// (backend/crates/integrations/src/four_gate.rs); none of them is retried automatically.
  String get userMessage {
    final wait = retryAfterSeconds ?? 0;
    return switch (code) {
      // The official site blocks the server's network: only launching needs it, trading is on-chain.
      'FOUR_API_CHALLENGED' ||
      'FOUR_API_FORBIDDEN' => '$message。Four 代币买卖不受影响，只有发币需要官方接口',
      'FOUR_API_TIMEOUT' ||
      'FOUR_API_UNAVAILABLE' ||
      'FOUR_API_BAD_RESPONSE' when wait > 0 => '$message，约 $wait 秒后可再试',
      _ => message,
    };
  }

  @override
  String toString() => userMessage;
}

class ModuleConfig {
  const ModuleConfig({
    required this.router,
    required this.approvalSpender,
    required this.maxImpact,
    this.routeEnabled = false,
  });

  factory ModuleConfig.fromJson(Map<String, dynamic> j) => ModuleConfig(
    router: j['router'] as String,
    approvalSpender: j['approvalSpender'] as String?,
    maxImpact: (j['maxPriceImpactPercent'] as num).toDouble(),
    routeEnabled: j['routeSource'] == 'uxuy' && j['routeEnabled'] == true,
  );

  final bool routeEnabled;
  final String router;
  final String? approvalSpender;
  final double maxImpact;

  void requireUxuySwap() {
    final spender = approvalSpender;
    if (!routeEnabled ||
        !isAddress(router) ||
        BigInt.parse(router) == BigInt.zero ||
        spender == null ||
        !isAddress(spender) ||
        BigInt.parse(spender) == BigInt.zero) {
      throw const BackendException('UXUY_CONFIG', 'UXUY 路由或授权合约尚未配置', false);
    }
  }
}

class TokenMeta {
  const TokenMeta(this.address, this.name, this.symbol, this.decimals);
  factory TokenMeta.fromJson(Map<String, dynamic> j) => TokenMeta(
    '${j['token']}',
    '${j['name']}',
    '${j['symbol']}',
    j['decimals'] as int?,
  );
  final String address;
  final String name;
  final String symbol;
  final int? decimals;
}

class GasInfo {
  const GasInfo(this.gasPrice, this.blockNumber);
  final BigInt gasPrice;
  final int blockNumber;
}

class WalletState {
  const WalletState(
    this.wallet,
    this.native,
    this.nonce,
    this.tokenBalance,
    this.routerAllowance,
  );
  factory WalletState.fromJson(Map<String, dynamic> j) => WalletState(
    '${j['wallet']}',
    BigInt.parse('${j['native']}'),
    j['nonce'] as int,
    j['tokenBalance'] == null || j['tokenBalance'] == ''
        ? null
        : BigInt.parse('${j['tokenBalance']}'),
    j['routerAllowance'] == null || j['routerAllowance'] == ''
        ? null
        : BigInt.parse('${j['routerAllowance']}'),
  );
  final String wallet;
  final BigInt native;
  final int nonce;
  final BigInt? tokenBalance;
  final BigInt? routerAllowance;
}

class RouteRequestData {
  const RouteRequestData({
    required this.buy,
    required this.token,
    required this.amount,
    required this.wallet,
    this.maxImpactPercent,
    this.forecastOnly = false,
    this.market,
    this.slippageBps = 50,
    this.settlementToken,
    this.settlementDecimals,
  });

  final String? settlementToken;
  final int? settlementDecimals;
  final int slippageBps;
  final bool buy;
  final bool forecastOnly;
  final Market? market;

  /// The user's price-impact limit; the backend refuses routes above it.
  final double? maxImpactPercent;
  final String token;
  final BigInt amount;
  final String wallet;

  Map<String, Object?> toJson({bool fast = true}) => {
    'side': buy ? 'buy' : 'sell',
    'innerPlatform': ?market?.innerPlatform,
    'token': token,
    'settlementToken': ?settlementToken,
    'amount': amount.toString(),
    'wallet': wallet,
    'maxImpactPercent': ?maxImpactPercent,
    'slippageBps': slippageBps,
    if (fast && forecastOnly) 'forecastOnly': true,
  };
}

List<T> _parseRouteItems<T>(Object? rows, T Function(Map) decode) {
  if (rows == null) return [];
  if (rows is! List || rows.length > 4 || rows.any((row) => row is! Map)) throw uxuyRouteFailed;
  return List.unmodifiable(rows.cast<Map>().map(decode));
}

String _routeAddress(Map row, String key) {
  final a = row[key];
  if (a is! String || !isAddress(a)) throw uxuyRouteFailed;
  return a.toLowerCase();
}

BigInt _routeUnits(Map row, String key) {
  final value = row[key];
  if (value is! String || !RegExp(r'^(?:0|[1-9][0-9]{0,77})$').hasMatch(value)) throw uxuyRouteFailed;
  final amount = BigInt.parse(value);
  if (amount.bitLength > 256) throw uxuyRouteFailed;
  return amount;
}

class RouteApproval {
  RouteApproval.fromJson(Map row)
      : token = _routeAddress(row, 'token'), spender = _routeAddress(row, 'spender'),
        amount = _routeUnits(row, 'amount');
  final String token, spender;
  final BigInt amount;
}

class RouteStep {
  RouteStep.fromJson(Map row)
      : to = _routeAddress(row, 'to'), recipient = _routeAddress(row, 'recipient'),
        tokenIn = _routeAddress(row, 'tokenIn'), tokenOut = _routeAddress(row, 'tokenOut'),
        amountIn = _routeUnits(row, 'amountIn'), minOut = _routeUnits(row, 'minOut'),
        kind = row['kind'] as String;
  final String to, recipient, tokenIn, tokenOut, kind;
  final BigInt amountIn, minOut;
}

class RouteLeg extends RouteStep {
  RouteLeg.fromJson(Map row)
      : value = _routeUnits(row, 'value'), data = row['data'] as String,
        gasLimit = row['gasLimit'] as int, super.fromJson(row);
  final String data;
  final BigInt value;
  final int gasLimit;
}

class RoutePlan {
  const RoutePlan({
    required this.wallet,
    required this.to,
    required this.data,
    required this.value,
    required this.pools,
    required this.dexes,
    required this.quoteOut,
    required this.minOut,
    required this.chainId,
    required this.simulation,
    required this.executed,
    required this.spender,
    required this.slippagePpm,
    required this.priceImpact,
    required this.deadline,
    this.source = 'uxuy',
    this.legs = const [],
    this.steps = const [],
    this.approvals = const [],
    this.gasLimit = 0,
    this.quoteScope,
    this.amount,
    this.token,
    this.settlementToken,
    this.settlementDecimals,
    this.buy,
  });

  factory RoutePlan.fromJson(Map<String, dynamic> j) {
    if (!const {'official','uxuy'}.contains(j['source']) ||
        j['chainId'] != bscChainId ||
        j['pools'] is! List ||
        j['dexes'] is! List ||
        j['spender'] is! String ||
        j['simulation'] is! String ||
        j['executed'] is! bool ||
        j['slippagePpm'] is! int ||
        j['deadline'] is! int ||
        j['gasLimit'] is! int ||
        (j['settlementToken'] == null
            ? j['settlementDecimals'] != null
            : j['settlementToken'] is! String ||
                !isAddress(j['settlementToken'] as String) ||
                j['settlementDecimals'] is! int ||
                (j['settlementDecimals'] as int) < 0 ||
                (j['settlementDecimals'] as int) > 36) ||
        j['fee']?.toString() != '0') {
      throw uxuyRouteFailed;
    }
    if (!['amount', 'quoteOut', 'minOut', 'value'].every(
          (key) =>
              j[key] is String &&
              RegExp(r'^(?:0|[1-9][0-9]{0,77})$').hasMatch(j[key] as String),
        ) ||
        ![
          'wallet',
          'to',
          'token',
          'spender',
        ].every((key) => j[key] is String && isAddress(j[key] as String)) ||
        j['data'] is! String ||
        (j['side'] != 'buy' && j['side'] != 'sell') ||
        (j['quoteScope'] != 'wallet' && j['quoteScope'] != 'bundle')) {
      throw uxuyRouteFailed;
    }
    return RoutePlan(
      source: j['source'] as String,
      legs: _parseRouteItems(j['legs'], RouteLeg.fromJson),
      steps: _parseRouteItems(j['steps'], RouteStep.fromJson),
      approvals: _parseRouteItems(j['approvals'], RouteApproval.fromJson),
      wallet: '${j['wallet']}',
      quoteScope: j['quoteScope'] as String?,
      amount: j['amount'] == null ? null : BigInt.parse('${j['amount']}'),
      token: j['token'] as String?,
      settlementToken: j['settlementToken'] as String?,
      settlementDecimals: j['settlementDecimals'] as int?,
      buy: switch (j['side']) {
        'buy' => true,
        'sell' => false,
        null => null,
        _ => throw const BackendException('BAD_RESPONSE', '交易方向无效', false),
      },
      to: '${j['to']}',
      data: '${j['data']}',
      value: BigInt.parse('${j['value']}'),
      pools: [for (final p in j['pools'] as List) '$p'],
      dexes: [for (final d in j['dexes'] as List) '$d'],
      quoteOut: BigInt.parse('${j['quoteOut']}'),
      minOut: BigInt.parse('${j['minOut']}'),
      chainId: j['chainId'] as int,
      executed: j['executed'] as bool,
      simulation: j['simulation'] as String,
      spender: j['spender'] as String,
      slippagePpm: j['slippagePpm'] as int,
      priceImpact: _adverseImpact(j),
      deadline: j['deadline'] as int,
      gasLimit: (j['gasLimit'] as num?)?.toInt() ?? 0,
    );
  }

  static double _adverseImpact(Map<String, dynamic> j) {
    final value = j['adversePriceImpactPercent'];
    if (value is! num || !value.isFinite || value < 0 || value > 100) {
      throw const BackendException('PRICE_IMPACT_UNKNOWN', '无法评估价格冲击', false);
    }
    return value.toDouble();
  }

  final String? settlementToken;
  final int? settlementDecimals;
  final String? quoteScope;
  final BigInt? amount;
  final String? token;
  final bool? buy;
  final String wallet;
  final String to;
  final String data;
  final BigInt value;
  final List<String> pools;
  final List<String> dexes;
  final BigInt quoteOut;
  final BigInt minOut;
  final int chainId;
  final String simulation, source;
  final List<RouteLeg> legs;
  final List<RouteStep> steps;
  final List<RouteApproval> approvals;
  final bool executed;
  final String spender;
  final int slippagePpm;
  final double priceImpact;
  final int deadline;

  /// From the backend: estimated gas +20%, or a measured per-hop ceiling when the call cannot be simulated yet.
  final int gasLimit;
}

class RouteResult {
  RouteResult.ok(RoutePlan this.plan) : error = null;
  RouteResult.failed(BackendException this.error) : plan = null;
  final RoutePlan? plan;
  final BackendException? error;
}

/// A removed event or an event attached to another inclusion cannot prove a payment.
bool hasConflictingReceiptLogs(Map receipt) {
  final logs = receipt['logs'];
  if (logs == null) return false;
  if (logs is! List) return true;
  for (final log in logs) {
    if (log is! Map || (log['removed'] != null && log['removed'] != false)) return true;
    for (final field in ['transactionHash', 'blockHash']) {
      final eventHash = log[field], receiptHash = receipt[field];
      // Simulation responses may contain only logs; compare inclusion when available.
      if (eventHash != null && receiptHash != null &&
          (eventHash is! String || receiptHash is! String ||
           eventHash.toLowerCase() != receiptHash.toLowerCase())) return true;
    }
  }
  return false;
}

class TxRecord {
  const TxRecord(
    this.hash,
    this.status,
    this.message, {
    this.receipt,
    this.recorded = true,
  });
  final bool recorded;
  final Map<String, dynamic>? receipt;
  factory TxRecord.fromJson(Map<String, dynamic> j) => TxRecord(
    '${j['transactionHash'] ?? j['hash']}',
    '${j['status']}',
    j['message'] as String?,
    receipt: (j['receipt'] as Map?)?.cast<String, dynamic>(),
  );
  final String hash;

  /// ambiguous | accepted | confirmed | reverted | rejected | not_submitted | not_included
  final String status;
  final String? message;

  bool get finished => const {
    'confirmed',
    'reverted',
    'rejected',
    'not_submitted',
    'not_included',
  }.contains(status);
  bool get refused => status == 'rejected' || status == 'not_submitted';
}

/// A token image chosen by the user (bytes stay in memory; uploaded only through the backend proxy).
class LaunchImage {
  const LaunchImage(this.bytes, this.filename, this.mime);
  final List<int> bytes;
  final String filename;
  final String mime;
}
