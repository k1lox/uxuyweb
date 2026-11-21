import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

class _Address extends Fake implements TradeWallet {
  _Address(int number)
    : address = '0x${number.toRadixString(16).padLeft(40, '0')}';
  @override
  final String address;
}

class _FirstCall extends Fake implements BackendClient {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('reached first backend read');
  }
}

void main() {
  final buyers = List.generate(
    297,
    (i) => LaunchBuyer(_Address(i + 1), BigInt.one),
  );
  for (final (outer, convert, devBuys, tip, alpha, count) in [
    (54, true, false, false, false, 302),
    (53, true, false, false, false, 300),
    (53, true, true, false, false, 302),
    (53, true, false, true, false, 301),
    (53, true, false, false, true, 301),
    (200, false, true, true, true, 300),
  ]) {
    test(
      'Genius $count legs before approvals: outer=$outer convert=$convert Dev=$devBuys tip=$tip Alpha=$alpha',
      () async {
        final api = _FirstCall();
        final launcher = GeniusLauncher(api, ExecutionLog());
        addTearDown(launcher.dispose);
        await launcher.launch(
          GeniusLaunchForm(
            name: 'Test',
            symbol: 'TEST',
            logo: 'ipfs://test',
            creatorFeeRecipient: buyers.first.wallet.address,
            quote: '0x4902c5ebc598265ed2212b559b042de8a5eeec3f',
            external: true,
            payWithBnb: convert,
            tip: tip ? BigInt.one : BigInt.zero,
            alpha: alpha,
            confirmedAlpha: alpha
                ? (factory: geniusM52Factory, priceWei: BigInt.one)
                : null,
          ),
          dev: LaunchBuyer(
            buyers.first.wallet,
            devBuys ? BigInt.one : BigInt.zero,
          ),
          internal: buyers.sublist(1, 97),
          external: buyers.sublist(97, 97 + outer),
        );
        if (count > 300) {
          expect(launcher.error, contains('$count 笔，超过单个捆绑上限 300，请减少购买钱包数量'));
          expect(
            api.calls,
            isEmpty,
            reason: 'no quotes, approvals, signing or submission',
          );
        } else {
          expect(launcher.error, contains('reached first backend read'));
          expect(api.calls, [convert ? #config : #rpc]);
        }
      },
    );
  }
}
