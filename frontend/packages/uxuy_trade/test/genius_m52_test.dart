import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';

void main() {
  const first = '0x0000000000000000000000000000000000000011';
  const second = '0x0000000000000000000000000000000000000022';
  final platform = List<Object?>.filled(23, BigInt.zero)
    ..[1] = BigInt.from(1000)
    ..[4] = BigInt.from(10)
    ..[5] = BigInt.from(32)
    ..[6] = BigInt.from(10)
    ..[7] = BigInt.from(31536000)
    ..[8] = BigInt.from(3153600000)
    ..[13] = BigInt.from(3000);
  List<Object?> encode(GeniusConfigurablePolicy policy) => policy.encode(
    defaultRecipient: first,
    exemptions: const [second],
    platform: platform,
    supply: BigInt.from(10).pow(27),
  );
  test(
    'new launches use the registered m5.2 factory and official selectors',
    () {
      final form = GeniusLaunchForm(
        name: 'Test',
        symbol: 'T',
        logo: 'ipfs://a',
        creatorFeeRecipient: first,
      );
      expect(geniusFactories[form.version], geniusM52Factory);
      expect(bytesToHex(geniusPreview.selector), '0x59e4d12e');
      expect(bytesToHex(geniusCreate.selector), '0xe7917195');
      expect(
        geniusPreview.inputs.first.signature,
        geniusCreate.inputs.first.signature,
      );
    },
  );
  test(
    'directional tax, allocations and empty revenue template are independent',
    () {
      final args = encode(
        const GeniusConfigurablePolicy(
          buyBps: 150,
          sellBps: 250,
          burnBps: 1000,
          rewardsBps: 2000,
          liquidityBps: 3000,
          recipients: [(first, 7000), (second, 3000)],
          feeYears: 2,
          lpRewards: true,
        ),
      );
      expect(args.take(2), [150, 250]);
      expect(args[2], [4000, 1000, 2000, 3000]);
      expect(args[3], [
        [first, 7000],
        [second, 3000],
      ]);
      expect(args[5], 63072000);
      expect(args[6], 3000);
      expect(args[7], zeroAddress);
      expect(args[8], [zeroAddress, isEmpty, 0, zeroAddress]);
      expect(args[9], [second]);
      expect(
        encode(const GeniusConfigurablePolicy(burnBps: 10000))[3],
        isEmpty,
      );
    },
  );
  test('factory limits, duplicate recipients and invalid reward selection stop preparation', () {
    expect(
      () => encode(const GeniusConfigurablePolicy(buyBps: 1001)),
      throwsStateError,
    );
    expect(
      () => encode(
        const GeniusConfigurablePolicy(
          recipients: [(first, 5000), (first, 5000)],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => encode(const GeniusConfigurablePolicy(rewardMode: 2)),
      throwsFormatException,
    );
    expect(
      () => encode(const GeniusConfigurablePolicy(feeYears: 101)),
      throwsFormatException,
    );
  });
}
