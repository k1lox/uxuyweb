// Catalog snapshot of flap.sh/launch (BSC), verified 2026-11-16.
// Discovery is not approval: live registry, quote support, policies and full creation simulation remain mandatory.
import 'flap_vault.dart';
import 'flap_vault_adapters.dart';

class FlapVaultMode {
  const FlapVaultMode(this.name, this.factory);
  final String name;
  final String factory;
}

class FlapCuratedVault {
  const FlapCuratedVault({
    required this.factory,
    required this.name,
    required this.officialName,
    this.summary = '',
    this.constraints = const {},
  });
  final String factory;
  final String name;
  final String officialName;
  final String summary;
  final Map<String, Object?> constraints;
  FlapVaultSchema? get legacySchema => flapCuratedSchema(factory);
  Map<String, String> get defaults => flapCuratedDefaults(factory);
  List<FlapVaultMode> get modes =>
      factory.toLowerCase() == listaFlexFactory.toLowerCase()
      ? const [
          FlapVaultMode('组合策略', listaFlexFactory),
          FlapVaultMode('USDT 生息', listaStableFactory),
          FlapVaultMode('流动性质押', listaLiquidFactory),
          FlapVaultMode('代币锁仓', listaLockFactory),
        ]
      : const [];
}

const flapCuratedVaults = <FlapCuratedVault>[
  FlapCuratedVault(
    factory: "0x98CADb60545CCCF60Af94C161714420C21E7CBc2",
    name: "Lista 收益组合",
    officialName: "ListaVaultSuite",
    summary: "收益分配给生息、流动性质押或代币锁仓策略。",
    constraints: {'minDividendBps': 0, 'maxDividendBps': 0},
  ),
  FlapCuratedVault(
    factory: "0x5e8604a69158FA583b0C5c16441A9b3d429E7Cbb",
    name: "礼物金库",
    officialName: "gift",
    summary: "通过 X 账号设置礼物接收人。",
    constraints: {'supportsErc20QuoteTokens': true},
  ),
  FlapCuratedVault(
    factory: "0x4a42C8A67Ce45cf449e0D2Ff24b9a5CeaCb74B69",
    name: "资产经纪人",
    officialName: "flapixelRwaV1",
    summary: "",
    constraints: {
      'requiresErc20QuoteToken': true,
      'excludedQuoteTokenSymbols': ['BTCB', 'SOL', 'USDT', 'USD1', 'U'],
    },
  ),
  FlapCuratedVault(
    factory: "0x9F5bF8EB9c4cA7179E60d0B529F4910B9A7eE0Ee",
    name: "排行榜燃烧分红",
    officialName: "Rank burn Dividend vault",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x7c8781B21FB004308a5a2bB7F9cB1E2e6Bd1fC7E",
    name: "AI 智能回购",
    officialName: "AI Smart Buyback",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x5418f7e8fF90354DB0eCD48c8b710219244Eb3C5",
    name: "指数资产篮子",
    officialName: "IndexVault",
    summary: "",
    constraints: {'minDividendBps': 0, 'maxDividendBps': 0},
  ),
  FlapCuratedVault(
    factory: "0x08E41a61C5D25420E3cb314Bc513EC99B2841003",
    name: "战略储备",
    officialName: "StrategyReserveV2",
    summary: "",
    constraints: {'minDividendBps': 0, 'maxDividendBps': 0},
  ),
  FlapCuratedVault(
    factory: "0xfB12E8B393007Bb8d925Ed1c4D3eEB4854B51Fa6",
    name: "股票生息",
    officialName: "TokenizedAssetYieldVault",
    summary: "",
    constraints: {
      'minDividendBps': 0,
      'maxDividendBps': 0,
      'requiresErc20QuoteToken': true,
      'requiredQuoteTokenSymbol': 'NVDAB',
    },
  ),
  FlapCuratedVault(
    factory: "0xeaEEa9c17a5376497C44fE2a5F9c63FE3B23bf87",
    name: "MYX 永续金库",
    officialName: "MyxPerpetualVault",
    summary: "ERC20 底池可能需要预存 BNB 运行费。",
    constraints: {
      'fixedVaultBps': 10000,
      'minDividendBps': 0,
      'maxDividendBps': 0,
      'minTaxBps': 100,
      'maxTaxBps': 1000,
      'supportsErc20QuoteTokens': true,
    },
  ),
  FlapCuratedVault(
    factory: "0x89a800a8fbB3538f8Ddb76C95034D23c249bF9D9",
    name: "活着的模因",
    officialName: "LivingMemeVault",
    summary: "需要已有角色 CID；使用资格以合约模拟为准。",
    constraints: {
      'fixedVaultBps': 10000,
      'minDividendBps': 0,
      'maxDividendBps': 0,
    },
  ),
  FlapCuratedVault(
    factory: "0x357c50d241dF58DC730AFc1e2Bf40B001768f3e0",
    name: "GMGN 喊单",
    officialName: "GmgnCallOutVault",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xfab75Dc774cB9B38b91749B8833360B46a52345F",
    name: "分配税收",
    officialName: "split",
    summary: "按比例分配给 1–10 个地址，创建后不可修改。",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x746e4978138240523cFb764E482f38AC04EdB6d3",
    name: "动态空投",
    officialName: "omnidrop",
    summary: "支持代币、LP 或 BNB 空投，可分配固定名单。",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xB64655dab7156c29B63C70fb3ED7f071e2658D19",
    name: "回购销毁",
    officialName: "buyback & burn",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xC6A0fD000988317F50215EdD4098Ed3368f52250",
    name: "自动回购",
    officialName: "ScheduledBuybackVaultV3",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x47A216040Dc9e0AfE2e6fc5dcC44f7bBD1B60d25",
    name: "燃烧分红",
    officialName: "Burn Dividend",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xCf83c4577D4c2E2A6BA48C0926046938802B74E6",
    name: "静默退出",
    officialName: "silent",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x59F3b82Ea3aA3BCE6156CA61c0A6613C0A632452",
    name: "LP 质押分红",
    officialName: "LP Staking Dividend",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xf68eE35A4fDe7a7C3e4baf01Dac019B4A90Fa1db",
    name: "代币质押分红",
    officialName: "Token Staking Dividend",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xf3056DAa77db106f25ba8c32EE78E5d40777fbaf",
    name: "质押抽奖",
    officialName: "Staking & LuckyDraw",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0xFCe2509d232FB62dc15c9Bf2faDE69653e480a25",
    name: "巴菲特",
    officialName: "Buffett",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x88a33780e1b3150Af85fBef52f344A43EBeC5A51",
    name: "FLAPixel NFT",
    officialName: "flapixelV2",
    summary: "",
    constraints: {},
  ),
  FlapCuratedVault(
    factory: "0x71Cab5A1A8904B358C24032BB653F764EFa03F14",
    name: "FOMOX",
    officialName: "FOMOX",
    summary: "",
    constraints: {'supportsErc20QuoteTokens': true},
  ),
];

FlapCuratedVault? flapCuratedVaultFor(String factory) {
  final key = factory.toLowerCase();
  for (final v in flapCuratedVaults) {
    if (v.factory.toLowerCase() == key ||
        v.modes.any((m) => m.factory.toLowerCase() == key))
      return v;
  }
  return null;
}
