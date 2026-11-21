import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

const quote = '0x00000000000000000000000000000000000000a1';
const router = '0x00000000000000000000000000000000000000a2';
final owner = TradeWallet.import('synthetic', '1'.padLeft(64, '0'));

class _Routes extends Fake implements BackendClient {
  _Routes(this.change);
  final String change;
  @override
  Future<TokenMeta> token(String address) async =>
      TokenMeta(quote, 'USD', 'USD', 6);
  @override
  Future<ModuleConfig> config() async => const ModuleConfig(
    router: router,
    approvalSpender: router,
    maxImpact: 15,
    routeEnabled: true,
  );
  @override
  Future<List<RouteResult>> routes(List<RouteRequestData> requests) async {
    final req = requests.single, forecast = req.forecastOnly;
    if (change == 'empty' && !forecast) return [];
    final p = RoutePlan(
      wallet: !forecast && change == 'payee' ? quote : req.wallet,
      to: router,
      data: forecast ? '0x' : '0x5103aafa0000',
      value: req.amount,
      pools: const [],
      dexes: const [],
      quoteOut: BigInt.from(1000),
      minOut: BigInt.from(change == 'less' && !forecast ? 995 : 999),
      chainId: 56,
      simulation: forecast ? 'forecast' : 'uxuy',
      executed: !forecast && change != 'noExecution',
      spender: router,
      slippagePpm: 5000,
      priceImpact: !forecast && change == 'impact' ? -1 : 0.1,
      deadline:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (change == 'expired' && !forecast ? -1 : 120),
      gasLimit: forecast ? 0 : 100000,
      quoteScope: 'wallet',
      amount: req.amount,
      token: quote,
      buy: true,
    );
    return [RouteResult.ok(p)];
  }
}

void main() {
  final budget = LaunchBuyer(owner, BigInt.from(100));
  for (final failure in [
    'less',
    'payee',
    'expired',
    'empty',
    'noExecution',
    'impact',
  ]) {
    test('reject $failure funding before adding launch calls', () async {
      final api = _Routes(failure);
      final funding = await LaunchFunding.prepare(api, quote, [
        budget,
      ], convert: true);
      expect(funding.units(budget).amount, BigInt.from(999));
      await expectLater(funding.executable(api), throwsStateError);
    });
  }
  test('an issued funding route is paired with the same wallet purchase and preserves currency units', () async {
    final api = _Routes('valid');
    final funding = await LaunchFunding.prepare(api, quote, [
      budget,
    ], convert: true);
    await funding.executable(api);
    final buy = LaunchTx(
      'first buy',
      owner,
      router,
      Uint8List(1),
      BigInt.zero,
      100000,
      kind: 'inner',
      purchasedToken: router,
    );
    expect(() => funding.include([]), throwsStateError);
    final legs = funding.include([buy]);
    expect(legs, hasLength(2));
    final payment = legs.first as LaunchFundingTx;
    expect(payment.value, budget.amount);
    expect(payment.poolSpend, BigInt.from(999));
    expect(payment.asset.decimals, 6);
    expect(legs.last, same(buy));
    expect(payment.confirmedSettlement, isNull);
    String topic(String address) =>
        '0x${address.substring(2).toLowerCase().padLeft(64, '0')}';
    Map transfer(String sender, String recipient, int amount) => {
      'address': quote,
      'topics': [
        '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
        topic(sender),
        topic(recipient),
      ],
      'data': '0x${amount.toRadixString(16).padLeft(64, '0')}',
    };
    void confirm(LaunchTx tx, int index, List<Map> logs) {
      tx.status = 'confirmed';
      tx.hash = '0x${index.toString().padLeft(64, '0')}';
      tx.receipt = {
        'transactionHash': tx.hash,
        'from': owner.address,
        'to': tx.to,
        'blockHash': '0x${'a' * 64}',
        'transactionIndex': '0x$index',
        'status': '0x1',
        'logs': logs,
      };
    }

    confirm(payment, 1, [transfer(router, owner.address, 1250)]);
    final sent = transfer(owner.address, router, 999);
    final returned = transfer(router, owner.address, 99);
    confirm(buy, 3, [sent, returned]);
    expect(payment.confirmedSettlement, (
      spent: BigInt.from(900),
      remaining: BigInt.from(350),
    ));

    buy.receipt!['blockHash'] = '0x${'b' * 64}';
    expect(payment.confirmedSettlement, isNull);
    confirm(buy, 0, [sent]);
    expect(payment.confirmedSettlement, isNull);
    confirm(buy, 3, [transfer(owner.address, router, 1001)]);
    expect(payment.confirmedSettlement, isNull);
    confirm(buy, 3, [
      sent,
      {...returned, 'data': '0x0'},
    ]);
    expect(payment.confirmedSettlement, isNull);
    confirm(buy, 3, [sent]);
    buy.receipt!['from'] = router;
    expect(payment.confirmedSettlement, isNull);
    confirm(buy, 3, [sent]);
    buy.receipt!['transactionHash'] = payment.hash;
    expect(payment.confirmedSettlement, isNull);
  });
}
