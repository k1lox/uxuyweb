part of 'genius_launch.dart';

const geniusInfinityRouter = '0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB';
const geniusInfinityManager = '0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b';
const geniusM52Hook = '0x2c908012aba847735b6f43654265b02e3d37d74a';
const geniusPermit2 = '0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768';
const _keyType = '(address,address,address,address,uint24,bytes32)';
final _poolKeyFor = AbiFunction.parse(
  'poolKeyFor(address) returns ($_keyType)',
);
final _launchRecord = AbiFunction.parse(
  'getLaunchedToken(address) returns ((address,address,address,address,address,uint256,uint24,int24,uint16,bool,uint8,uint256,uint256,uint256,bool))',
);
final _curveBuy = AbiFunction.parse(
  'buy(uint256,uint256,address) returns (uint256)',
);
final _migratePool = AbiFunction.parse(
  'createGraduatedPool(address) returns (uint256)',
);
final _infinityExecute = AbiFunction.parse('execute(bytes,bytes[],uint256)');
final _permitAllowance = AbiFunction.parse(
  'allowance(address,address,address) returns (uint160,uint48,uint48)',
);
final _permitApprove = AbiFunction.parse(
  'approve(address,address,uint160,uint48)',
);

bool _same(Object? a, String b) =>
    a is String && a.toLowerCase() == b.toLowerCase();
Uint8List _abi(List<String> types, List<Object?> values) =>
    encodeSequence(types.map(AbiType.parse).toList(), values);

bool _matchesLaunchPool(List<Object?> key, String token, String quote) =>
    key.length == 6 &&
    ((_same(key[0], quote) && _same(key[1], token)) ||
        (_same(key[0], token) && _same(key[1], quote))) &&
    _same(key[2], geniusM52Hook) &&
    _same(key[3], geniusInfinityManager);

Uint8List geniusInfinityBuy(
  List<Object?> key,
  String token,
  String quote,
  BigInt amount,
  BigInt minimum,
  BigInt deadline,
) {
  if (!_matchesLaunchPool(key, token, quote) ||
      amount <= BigInt.zero ||
      amount.bitLength > 128 ||
      minimum <= BigInt.zero ||
      minimum.bitLength > 128)
    throw StateError('Genius 官方外盘底池、金额或最低到账不符');
  final params = [
    _abi(
      ['($_keyType,bool,uint128,uint128,bytes)'],
      [
        [key, _same(key[0], quote), amount, minimum, Uint8List(0)],
      ],
    ),
    _abi(['address', 'uint256'], [quote, amount]),
    _abi(['address', 'uint256'], [token, minimum]),
  ];
  return _infinityExecute.encode([
    hexToBytes('10'),
    [
      _abi(['bytes', 'bytes[]'], [hexToBytes('060c0f'), params]),
    ],
    deadline,
  ]);
}

Map<String, Object?> _launchCall(
  String sender,
  String? to,
  Uint8List data,
  BigInt value,
  int gas,
) => {
  'from': sender,
  'to': to,
  'data': bytesToHex(data),
  'value': '0x${value.toRadixString(16)}',
  'gas': '0x${gas.toRadixString(16)}',
  'gasPrice': '0x0',
};

extension GeniusOfficialLaunch on GeniusLauncher {
  Future<int> _outerDeadline() async {
    final block = (await api.rpc([
      ('eth_getBlockByNumber', ['latest', false]),
    ])).single;
    final at = block is Map ? int.tryParse('${block['timestamp']}') : null;
    if (at == null || at <= 0) throw StateError('Genius 无法读取 BSC 区块时间');
    return at + 300;
  }

  Future<List<Map>> _ordered(List<Map<String, Object?>> calls) async {
    final response = (await api.rpc([
      (
        'eth_simulateV1',
        [
          {
            'blockStateCalls': [
              {'calls': calls},
            ],
            'validation': false,
          },
          'latest',
        ],
      ),
    ])).single;
    if (response is! List || response.length != 1 || response.single is! Map)
      throw StateError('Genius 顺序模拟无效');
    final rows = (response.single as Map)['calls'];
    if (rows is! List ||
        rows.length != calls.length ||
        rows.any((r) => r is! Map || r['status'] != '0x1'))
      throw StateError('Genius 同块顺序模拟未通过');
    return rows.cast<Map>();
  }

  Future<List<Object?>> _readLaunchKey(
    TradeWallet dev,
    Uint8List create,
    BigInt fee,
    String token,
    String curve,
    String quote,
  ) async {
    final rows = await _ordered([
      _launchCall(dev.address, geniusM52Factory, create, fee, 12000000),
      _launchCall(
        dev.address,
        geniusM52Factory,
        _poolKeyFor.encode([token]),
        BigInt.zero,
        300000,
      ),
    ]);
    final created = geniusCreate.decodeOutput(rows[0]['returnData'] as String);
    if (!_same(created[0], token) || !_same(created[1], curve))
      throw StateError('Genius 官方创建返回的代币或曲线与预览不一致');
    final key =
        (_poolKeyFor.decodeOutput(rows.last['returnData'] as String).single
                as List)
            .cast<Object?>();
    if (!_matchesLaunchPool(key, token, quote))
      throw StateError('Genius 外盘官方池身份无效');
    return key;
  }

  /// Verify the real registered curve and phase immediately after every relevant step, in one simulated block.
  Future<void> _verifyLaunchPhases(
    List<LaunchTx> txs,
    String token,
    String curve,
    String quote,
    bool migrate,
    bool devBuy,
  ) async {
    final calls = <Map<String, Object?>>[];
    final checks = <int, int>{};
    final inners = txs
        .where((tx) => tx.kind == 'inner' || (tx.kind == 'create' && devBuy))
        .toList();
    final lastOuter = txs.lastIndexWhere((tx) => tx.kind == 'outer');
    for (final tx in txs) {
      calls.add(
        _launchCall(tx.from.address, tx.to, tx.data, tx.value, tx.gasLimit),
      );
      if (!{'create', 'inner', 'migrate', 'outer'}.contains(tx.kind)) continue;
      // Every outer receipt is checked. Graduation is irreversible, so the
      // final outer wallet also proves the phase for this group.
      if (tx.kind == 'outer' && !identical(tx, txs[lastOuter])) continue;
      final nextPhase = tx.kind == 'outer' || tx.kind == 'migrate'
          ? 2
          : migrate && inners.isNotEmpty && identical(tx, inners.last)
          ? 1
          : 0;
      checks[calls.length] = nextPhase;
      calls.add(
        _launchCall(
          tx.from.address,
          geniusM52Factory,
          _launchRecord.encode([token]),
          BigInt.zero,
          300000,
        ),
      );
    }
    final rows = await _ordered(calls);
    for (final e in checks.entries) {
      final record =
          _launchRecord.decodeOutput(rows[e.key]['returnData'] as String).single
              as List;
      if (!_same(record[0], token) ||
          !_same(record[1], curve) ||
          !_same(record[2], txs.first.from.address) ||
          !_same(record[4], quote) ||
          record[14] != true ||
          record[10] != BigInt.from(e.value)) {
        throw StateError('Genius 模拟的曲线、底池或阶段不符（预期阶段 ${e.value}），请核对最后一笔内盘金额');
      }
    }
  }

  Future<void> _prepareOuterPermit(
    String quote,
    List<LaunchBuyer> buyers,
    Map<String, Object?> context,
    int deadline,
  ) async {
    Future<List<List<Object?>>> read(List<LaunchBuyer> batch) async {
      final values = await api.rpc([
        for (final b in batch)
          (
            'eth_call',
            [
              {
                'to': geniusPermit2,
                'data': _permitAllowance.encodeHex([
                  b.wallet.address,
                  quote,
                  geniusInfinityRouter,
                ]),
              },
              'latest',
            ],
          ),
      ]);
      return [
        for (final raw in values) _permitAllowance.decodeOutput(raw as String),
      ];
    }

    bool covered(List<Object?> row, BigInt amount) =>
        (row[0] as BigInt) >= amount &&
        (row[1] as BigInt) >= BigInt.from(deadline);
    for (var i = 0; i < buyers.length; i += 100) {
      final batch = buyers.skip(i).take(100).toList();
      final current = await read(batch);
      final needed = [
        for (var j = 0; j < batch.length; j++)
          if (!covered(current[j], batch[j].amount)) batch[j],
      ];
      if (needed.isEmpty) continue;
      final expiration = deadline + 60;
      final grants = <int>[];
      for (var j = 0; j < needed.length; j += 8) {
        grants.addAll(
          await Future.wait([
            for (final b in needed.skip(j).take(8))
              api.checkLaunchPayment(
                quote,
                geniusInfinityRouter,
                b.wallet.address,
                b.amount,
                reset: false,
                launchContext: context,
                permitExpiration: expiration,
              ),
          ]),
        );
      }
      final legs = [
        for (final b in needed)
          LaunchTx(
            '授权 Genius 外盘本次买入',
            b.wallet,
            geniusPermit2,
            _permitApprove.encode([
              quote,
              geniusInfinityRouter,
              b.amount,
              BigInt.from(expiration),
            ]),
            BigInt.zero,
            100000,
            kind: 'approve',
          ),
      ];
      await simulateBundle(legs, requireSuccess: true);
      final gas = await launchBundleGas(api);
      final nonces = await checkBalances(legs, gas.gasPrice);
      if (grants.any((d) => d <= DateTime.now().millisecondsSinceEpoch ~/ 1000))
        throw StateError('外盘授权检查已过期');
      if (!await submitBundle(
        legs,
        signAll(legs, nonces, gas.gasPrice),
        what: 'Genius 外盘授权',
      )) {
        if (legs.every((tx) => !{'unknown', 'submitted'}.contains(tx.status)))
          state = LaunchState.failed;
        throw StateError('外盘授权尚未全部确认，请查询原交易');
      }
      state = LaunchState.preparing;
      changed();
      final verified = await read(needed);
      for (var j = 0; j < needed.length; j++) {
        if (verified[j][0] != needed[j].amount ||
            verified[j][1] != BigInt.from(expiration))
          throw StateError('Genius 外盘授权回读金额或时效不符');
      }
    }
  }
}

String? Function(Map) _buyerCashflow(
  String quote,
  LaunchBuyer buyer,
  bool outer,
  String? Function(Map)? phaseProof,
) {
  return (receipt) {
    if (!_same(quote, zeroAddress)) {
      final spent = -launchReceiptDelivery(
        receipt,
        quote,
        buyer.wallet.address,
      );
      if (spent <= BigInt.zero ||
          spent > buyer.amount ||
          (outer && spent != buyer.amount))
        return 'Genius 原交易的底池币实际扣款不符';
    }
    return phaseProof?.call(receipt);
  };
}

String? Function(Map) _sweepProof(String token, bool shouldGraduate) {
  final event = bytesToHex(
    keccak256('LaunchSwept(address,uint256,uint256)'.codeUnits),
  );
  final asset = '0x${token.substring(2).toLowerCase().padLeft(64, '0')}';
  return (receipt) {
    final logs = receipt['logs'];
    if (logs is! List) return 'Genius 买单缺少事件凭据';
    for (final entry in logs.whereType<Map>()) {
      final topics = entry['topics'], data = entry['data'];
      if (!_same(entry['address'], geniusM52Factory) ||
          topics is! List ||
          topics.length != 2 ||
          !_same(topics[0], event) ||
          !_same(topics[1], asset))
        continue;
      if (!shouldGraduate) return 'Genius 代币在计划的最后一笔之前已达到毕业门槛';
      if (data is String && RegExp(r'^0x[0-9a-fA-F]{128}$').hasMatch(data)) {
        final amounts = decodeSequence(
          List.filled(2, AbiType.parse('uint256')),
          hexToBytes(data),
          0,
        );
        if (amounts.every((v) => v is BigInt && v > BigInt.zero)) return null;
      }
      return 'Genius 毕业注入的两种资产无效';
    }
    return shouldGraduate ? '最后一笔内盘买单缺少官方毕业清算事件，请增加金额或核对开盘税' : null;
  };
}

String? Function(Map) _graduationProof(String token, List<Object?> key) {
  final poolId = bytesToHex(keccak256(_abi([_keyType], [key])));
  final event = bytesToHex(
    keccak256(
      'GraduatedPoolCreated(address,bytes32,uint256,uint256,uint256)'.codeUnits,
    ),
  );
  final asset = '0x${token.substring(2).toLowerCase().padLeft(64, '0')}';
  return (receipt) {
    final logs = receipt['logs'];
    if (logs is List) {
      for (final entry in logs.whereType<Map>()) {
        final topics = entry['topics'], data = entry['data'];
        if (!_same(entry['address'], geniusM52Factory) ||
            topics is! List ||
            topics.length != 3 ||
            !_same(topics[0], event) ||
            !_same(topics[1], asset) ||
            !_same(topics[2], poolId) ||
            data is! String ||
            !RegExp(r'^0x[0-9a-fA-F]{192}$').hasMatch(data))
          continue;
        final numbers = decodeSequence(
          List.filled(3, AbiType.parse('uint256')),
          hexToBytes(data),
          0,
        );
        if (numbers.every((v) => v is BigInt && v > BigInt.zero)) return null;
      }
    }
    return 'Genius 毕业事件中的代币、官方池或实际注入流动性无效';
  };
}
