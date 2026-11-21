import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/market.dart';

import 'support/inner_quote.dart';
import 'support/fake_backend.dart' as fixture;

const wallet = '0x2222222222222222222222222222222222222222';
const intermediate = '0x3333333333333333333333333333333333333333';
const target = '0x4444444444444444444444444444444444444444';
final first = '0x${'01' * 32}', second = '0x${'02' * 32}';
String word(String address) =>
    '0x${address.substring(2).toLowerCase().padLeft(64, '0')}';
String topic(String event) => bytesToHex(keccak256(event.codeUnits));
Map transfer(String from, String to, int amount) => {
  'address': intermediate,
  'topics': [topic('Transfer(address,address,uint256)'), word(from), word(to)],
  'data': '0x${amount.toRadixString(16).padLeft(64, '0')}',
};
Map leg(
  String kind,
  String input,
  String output,
  int n, {
  String to = target,
}) => {
  'kind': kind,
  'to': to,
  'tokenIn': input,
  'tokenOut': output,
  'recipient': wallet,
  'amountIn': '$n',
  'minOut': '1',
  'value': '0',
  'data': '0x',
  'gasLimit': 21000,
};

class _Node extends Fake implements BackendClient {
  bool good = false;
  final nativeTraces = <String>[];
  @override
  Future<BigInt> nativeReceiptPrincipal(
    String hash,
    String wallet,
    Map receipt,
  ) async {
    nativeTraces.add(hash);
    return BigInt.from(hash == first ? 103 : -97);
  }

  @override
  Future<TokenMeta> token(String address) async =>
      TokenMeta(address, 'COL', 'COL', 2);
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async => [
    for (final (_, args) in calls)
      {
        'status': '0x1',
        'transactionHash': args.first,
        'from': wallet,
        'to': good || args.first == first ? target : intermediate,
        'blockHash': '0x${'ab' * 32}',
        'transactionIndex': args.first == first ? '0x1' : '0x2',
        'logs': args.first == first
            ? [transfer(target, wallet, 103), transfer(wallet, target, 2)]
            : [transfer(wallet, target, 97)],
      },
  ];
}

void main() {
  test('each wallet retains only actual net conversion surplus; a mismatched original receipt retries without recounting', () async {
    final base = innerQuote(innerMarket('four'), {
      'wallet': wallet,
      'side': 'sell',
      'amount': '100',
    });
    base['legs'] = [
      leg('official', fixture.token, intermediate, 100),
      leg('conversion', intermediate, zeroAddress, 97),
    ];
    final route = RoutePlan.fromJson({
      ...base,
      'chainId': 56,
      'fee': '0',
      'slippagePpm': 5000,
      'executed': true,
      'deadline': 2000000000,
      'amount': '100',
      'value': '0',
      'side': 'sell',
      'quoteScope': 'wallet',
      'token': fixture.token,
      'wallet': wallet,
      'adversePriceImpactPercent': 0.1,
    });
    final out = TradeOutcome()
      ..trackIntermediates(route, [
        SignedTx('', first, 1),
        SignedTx('', second, 2),
      ]);
    final api = _Node(), trader = BatchTrader(api, ExecutionLog());
    await trader.reconcileIntermediateReceipt(second, out);
    expect(trader.hasPendingSaleTotals, isTrue);
    expect(out.remainingAssets, isEmpty);
    api.good = true;
    await trader.query();
    expect(trader.hasPendingSaleTotals, isFalse);
    final text = out.remainingAssets[second]!.single;
    expect(text, contains(wallet));
    expect(text, contains('0.04 COL'));
    expect(text, contains(intermediate));
    final before = trader.log.entries
        .where((e) => e.text.contains('0.04 COL'))
        .length;
    await trader.reconcileIntermediateReceipt(second, out);
    expect(
      trader.log.entries.where((e) => e.text.contains('0.04 COL')).length,
      before,
    );
  });
  test('native conversion change uses each transaction principal, independently of network costs', () async {
    final order = RoutePlan.fromJson({
      ...innerQuote(innerMarket('four'), {
        'wallet': wallet,
        'amount': '100',
        'side': 'sell',
      }),
      'chainId': 56,
      'fee': '0',
      'slippagePpm': 5000,
      'executed': true,
      'deadline': 2000000000,
      'amount': '100',
      'value': '0',
      'side': 'sell',
      'quoteScope': 'wallet',
      'token': fixture.token,
      'wallet': wallet,
      'adversePriceImpactPercent': 0.1,
      'legs': [
        leg('official', fixture.token, zeroAddress, 100),
        leg('conversion', zeroAddress, intermediate, 97),
      ],
    });
    final out = TradeOutcome()
      ..trackIntermediates(order, [
        SignedTx('', first, 1),
        SignedTx('', second, 2),
      ]);
    final api = _Node()..good = true;
    final trader = BatchTrader(api, ExecutionLog());
    await trader.reconcileIntermediateReceipt(second, out);
    expect(api.nativeTraces, [first, second]);
    expect(
      out.remainingAssets[second]!.single,
      contains('0.000000000000000006 BNB'),
    );
  });
  test(
    'WBNB wrap and unwrap use wallet-specific events on the canonical contract',
    () {
      for (final entry in [
        ('wrap', 'Deposit', 1),
        ('unwrap', 'Withdrawal', -1),
      ]) {
        final step = RouteLeg.fromJson(
          leg(
            entry.$1,
            entry.$3 == 1 ? zeroAddress : wbnb,
            entry.$3 == 1 ? wbnb : zeroAddress,
            97,
            to: wbnb,
          ),
        );
        final log = {
          'address': wbnb,
          'topics': [topic('${entry.$2}(address,uint256)'), word(wallet)],
          'data': '0x${'61'.padLeft(64, '0')}',
        };
        expect(
          intermediateTokenDelta(
            {
              'logs': [log],
            },
            step,
            wbnb,
            wallet,
          ),
          BigInt.from(97 * entry.$3),
        );
        expect(
          () => intermediateTokenDelta({'logs': []}, step, wbnb, wallet),
          throwsStateError,
        );
      }
    },
  );
}
