part of 'launch.dart';

final _flapBuy = AbiFunction.parse(
  'swapExactInputV3((address,address,uint256,uint256,bytes,bytes))',
);
final _flapState = AbiFunction.parse(
  'getTokenV8Safe(address) returns ((uint8,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,address,bool,bytes32,uint256,uint256,address,uint256,uint8,uint8))',
);
final _flapDexEvent = bytesToHex(
  eventTopic('LaunchedToDEX(address,address,uint256,uint256)'),
);

/// Official Portal event data contains four ABI words; the token and pool are not indexed.
String? _flapMigratedPool(Map result, String token) {
  final logs = result['logs'];
  if (logs is! List) return null;
  for (final event in logs.whereType<Map>()) {
    final topics = event['topics'], data = event['data'];
    if (event['removed'] == true ||
        '${event['address']}'.toLowerCase() != flapPortal ||
        topics is! List ||
        topics.length != 1 ||
        '${topics.first}'.toLowerCase() != _flapDexEvent ||
        data is! String ||
        !RegExp(r'^0x[0-9a-fA-F]{256}$').hasMatch(data))
      continue;
    final words = data.substring(2).toLowerCase();
    if (words.substring(0, 64) !=
            token.substring(2).toLowerCase().padLeft(64, '0') ||
        words.substring(64, 88) != '0' * 24)
      continue;
    final pool = '0x${words.substring(88, 128)}';
    if (pool != zeroAddress) return pool;
  }
  return null;
}

const _flapInfinityManager = '0xa0ffb9c1ce1fe56963b0321b32e7a0302114058b';
const _infinityInitialize =
    '0x426cc62fe6a33a40ba2788c2c87a9c34ee4582b95bc9fa5a7bb7ae70b750b99c';

bool _flapPoolMatches(
  Map receipt,
  String token,
  String quote,
  String statePool,
) {
  final reported = _flapMigratedPool(receipt, token);
  if (reported == null || statePool == zeroAddress) return false;
  if (statePool != _flapInfinityManager) return statePool == reported;
  // On Infinity the Portal records the shared CL manager in token state.
  // Bind that manager's initialization in the same migration to both currencies.
  String topic(String a) =>
      '0x${a.substring(2).toLowerCase().padLeft(64, '0')}';
  final tokenWord = topic(token),
      quoteWord = topic(quote.toLowerCase() == zeroAddress ? wbnb : quote);
  final logs = receipt['logs'];
  return logs is List &&
      logs.whereType<Map>().any((log) {
        final topics = log['topics'];
        if (log['removed'] == true ||
            '${log['address']}'.toLowerCase() != statePool ||
            topics is! List ||
            topics.length != 4 ||
            '${topics[0]}'.toLowerCase() != _infinityInitialize ||
            !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch('${topics[1]}'))
          return false;
        final first = '${topics[2]}'.toLowerCase(),
            second = '${topics[3]}'.toLowerCase();
        return first == tokenWord && second == quoteWord ||
            first == quoteWord && second == tokenWord;
      });
}

String? _flapMigrationProblem(
  Map receipt,
  String token, {
  required bool expected,
}) {
  final migrated = _flapMigratedPool(receipt, token) != null;
  if (migrated == expected) return null;
  return expected ? '最后一笔内盘首买未触发本币的 Flap 迁移' : 'Flap 迁移出现在计划外的交易中';
}

class _FlapBuy {
  const _FlapBuy(this.buyer, this.label, this.gas, {this.migration = false});
  final LaunchBuyer buyer;
  final String label;
  final int gas;
  final bool migration;
  _FlapBuyTx tx(
    FlapPayment payment,
    String token,
    BigInt floor,
    int version, {
    bool nativeInput = false,
  }) => _FlapBuyTx(this, payment, token, floor, version, nativeInput);
}

class _FlapBuyTx extends LaunchTx {
  _FlapBuyTx(
    _FlapBuy buy,
    FlapPayment payment,
    String token,
    BigInt floor,
    this.version,
    bool nativeInput,
  ) : migration = buy.migration,
      quote = payment.address,
      super(
        buy.label,
        buy.buyer.wallet,
        flapPortal,
        _flapBuy.encode([
          [
            nativeInput ? zeroAddress : payment.address,
            token,
            buy.buyer.amount,
            floor,
            Uint8List(0),
            Uint8List(0),
          ],
        ]),
        (nativeInput || payment.native) ? buy.buyer.amount : BigInt.zero,
        buy.gas,
        purchasedToken: token,
        minimumDelivery: floor,
        protocolCheck: (result) =>
            _flapMigrationProblem(result, token, expected: buy.migration),
      );
  final bool migration;
  final String quote;
  final int version;
}
