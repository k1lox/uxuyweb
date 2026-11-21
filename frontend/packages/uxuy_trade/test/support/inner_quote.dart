import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/exec/market.dart';

import 'fake_backend.dart' as fixture;

Market innerMarket(String platform, {String collateral = zeroAddress}) =>
    Market({
      'address': fixture.token,
      'external': false,
      'platform': platform,
      'quote': collateral,
      'decimals': 18,
      'block': 1000,
      if (platform == 'genius')
        'genius': {'version': 'm5.2', 'phase': 0, 'curve': fixture.pool},
    });

Map<String, Object?> innerQuote(Market market, Map<String, dynamic> request) {
  final wallet = request['wallet'] as String, target = market.innerTarget!;
  final amount = BigInt.parse(request['amount'] as String);
  final estimate = BigInt.from(1000);
  final min = BigInt.from(995);
  final buy = request['side'] == 'buy',
      forecast = request['forecastOnly'] == true;
  final token = market.address,
      quote = market.quote,
      wrapped = quote.toLowerCase() == wbnb.toLowerCase();
  final legs = <Map<String, Object>>[];
  void leg(
    String kind,
    String dest,
    String data,
    String input,
    String output,
    BigInt size,
    BigInt minimum,
  ) {
    legs.add({
      'kind': kind,
      'to': dest,
      'data': data,
      'tokenIn': input,
      'tokenOut': output,
      'amountIn': '$size',
      'minOut': '$minimum',
      'value': input == zeroAddress ? '$size' : '0',
      'gasLimit': 100000,
      'recipient': wallet,
    });
  }

  if (buy && wrapped)
    leg(
      'wrap',
      wbnb,
      AbiFunction.parse('deposit()').encodeHex([]),
      zeroAddress,
      wbnb,
      amount,
      amount,
    );
  final input = buy ? quote : token, output = buy ? token : quote;
  final data = switch ((market.platform, buy)) {
    ('four', true) => AbiFunction.parse(
      'buyTokenAMAP(address,address,uint256,uint256)',
    ).encodeHex([token, wallet, amount, min]),
    ('four', false) => AbiFunction.parse(
      'sellToken(uint256,address,uint256,uint256)',
    ).encodeHex([0, token, amount, min]),
    ('flap', _) =>
      AbiFunction.parse(
        'swapExactInputV3((address,address,uint256,uint256,bytes,bytes))',
      ).encodeHex([
        [input, output, amount, min, <int>[], <int>[]],
      ]),
    _ => AbiFunction.parse(
      buy ? 'buy(uint256,uint256,address)' : 'sell(uint256,uint256,address)',
    ).encodeHex([amount, min, wallet]),
  };
  leg('official', target, data, input, output, amount, min);
  if (!buy && wrapped && request['settlementToken'] == null) {
    leg(
      'unwrap',
      wbnb,
      AbiFunction.parse('withdraw(uint256)').encodeHex([min]),
      wbnb,
      zeroAddress,
      min,
      min,
    );
  }
  return {
    'source': 'official',
    'to': target,
    'spender': target,
    'pools': [target],
    'dexes': [market.platform],
    'simulation': forecast ? 'forecast' : 'official',
    'legs': forecast ? [] : legs,
    if (forecast)
      'steps': [
        for (final l in legs)
          Map.of(l)
            ..remove('data')
            ..remove('value')
            ..remove('gasLimit'),
      ],
    'data': forecast ? '0x' : data,
    'gasLimit': forecast ? 0 : legs.length * 100000,
    'quoteOut': '$estimate',
    'minOut': '$min',
    'approvals': [
      if (input != zeroAddress)
        {'token': input, 'spender': target, 'amount': '$amount'},
    ],
  };
}
