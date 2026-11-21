import 'dart:typed_data';

import '../evm/abi.dart';
import '../evm/evm.dart';
import 'market.dart' show zeroAddress;

/// ABI 5.2.0 from genius.fun/contracts/abi/5.2.0/GeniusConfigurableFactory.json.
const geniusM52 = 'm5.2';
const geniusM52LaunchAndBuy = '0x070e71483e07b219b0509193a885e514fe4aa33e';
const geniusM52Factory = '0x52609D5dc0f34B4D077dc6F568B17BEb0878AB67';

/// Verified configurable-stack recipient forwarding to the Foundation vault.
const geniusM52Foundation = '0xc2BAA8F402FC1BB1929aaE3B0982fB33F8833487';
const _params =
    '(string,string,string,string,(string,string,string,string,string),bytes32,uint256,address,address,'
    '(uint16,uint16,(uint16,uint16,uint16,uint16),(address,uint16)[],(uint8,address,uint256),'
    'uint48,uint24,address,(address,bytes,uint16,address),address[]))';
final geniusPreview = AbiFunction.parse(
  'previewConfigurableLaunch($_params,address) returns (address,address,bytes32)',
);
final geniusCreate = AbiFunction.parse(
  'launchConfigurable($_params,bytes32) returns (address,address)',
);
final geniusCreateAndBuy = AbiFunction.parse(
  'launchConfigurableAndBuy($_params,bytes32,uint256,uint256,uint256) returns (address)',
);
final geniusPlatformPolicy = AbiFunction.parse(
  'currentPlatformPolicy() returns ((uint16,uint16,uint16,uint16,uint8,uint8,uint16,uint48,uint48,uint16,uint16,uint32,uint24,uint24,uint8,uint8,uint32,uint16,uint32,uint16,address,uint256,bytes32))',
);

/// Direct revenue covers a single recipient or a weighted list. The standard
/// policy uses the normal LP fee and has no external revenue template.
class GeniusConfigurablePolicy {
  const GeniusConfigurablePolicy({
    this.buyBps = 0,
    this.sellBps = 0,
    this.burnBps = 0,
    this.rewardsBps = 0,
    this.liquidityBps = 0,
    this.recipients = const [],
    this.rewardMode = 0,
    this.rewardAsset = zeroAddress,
    this.minimumHolding,
    this.feeYears = 0,
    this.lpRewards = false,
    this.integrator = zeroAddress,
  });

  final int buyBps, sellBps, burnBps, rewardsBps, liquidityBps;
  final List<(String, int)> recipients;
  final int rewardMode, feeYears;
  final String rewardAsset, integrator;
  final BigInt? minimumHolding;
  final bool lpRewards;

  List<Object?> encode({
    required String defaultRecipient,
    required List<String> exemptions,
    required List<Object?> platform,
    required BigInt supply,
  }) {
    int setting(int index) => (platform[index]! as BigInt).toInt();
    final maxFee = setting(1);
    if ([buyBps, sellBps].any((fee) => fee < 0 || fee > maxFee)) {
      throw StateError('Genius 创作者买税和卖税须在 0%–${maxFee / 100}% 之间');
    }
    final recipientBps = 10000 - burnBps - rewardsBps - liquidityBps;
    final allocation = [recipientBps, burnBps, rewardsBps, liquidityBps];
    if (allocation.any((share) => share < 0 || share > 10000)) {
      throw const FormatException('创作者税的各项分配合计须为 100%');
    }
    final accounts = recipients.isEmpty && recipientBps > 0
        ? [(defaultRecipient, 10000)]
        : recipients;
    if ((recipientBps == 0 && accounts.isNotEmpty) ||
        accounts.length > setting(4) ||
        (accounts.isNotEmpty &&
            accounts.fold(0, (int sum, x) => sum + x.$2) != 10000)) {
      throw const FormatException('请检查收益地址数量和分配，地址权重合计须为 100%');
    }
    final seen = <String>{};
    for (final (address, weight) in accounts) {
      if (!isAddress(address) ||
          address.toLowerCase() == zeroAddress ||
          !seen.add(address.toLowerCase()) ||
          weight <= 0 ||
          weight > 10000) {
        throw const FormatException('收益地址无效、重复或权重无效');
      }
    }
    if (exemptions.length > setting(5)) {
      throw StateError('本版最多支持 ${setting(5)} 个开盘免税地址');
    }
    final holding = minimumHolding ?? BigInt.zero;
    if (holding < BigInt.zero ||
        holding > supply * BigInt.from(setting(6)) ~/ BigInt.from(10000)) {
      throw const FormatException('最低持仓超出 Genius 当前范围');
    }
    if (!isAddress(rewardAsset) ||
        rewardMode < 0 ||
        rewardMode > 2 ||
        (rewardMode == 2) != (rewardAsset.toLowerCase() != zeroAddress)) {
      throw const FormatException('奖励代币类型或合约地址无效');
    }
    final duration = feeYears * 365 * 86400;
    if (duration != 0 && (duration < setting(7) || duration > setting(8))) {
      throw const FormatException('创作者税期限超出 Genius 当前范围');
    }
    if (!isAddress(integrator)) throw const FormatException('集成方地址无效');
    return [
      buyBps,
      sellBps,
      allocation,
      [
        for (final (address, weight) in accounts)
          [checksumAddress(address), weight],
      ],
      [rewardMode, checksumAddress(rewardAsset), holding],
      duration,
      setting(lpRewards ? 13 : 12),
      checksumAddress(integrator),
      [zeroAddress, Uint8List(0), 0, zeroAddress],
      exemptions,
    ];
  }
}
