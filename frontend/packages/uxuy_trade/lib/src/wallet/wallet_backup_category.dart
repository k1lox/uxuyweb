abstract final class WalletBackupCategory {
  static const tradeGroup = 'trade-group';
  static const linkedSeller = 'linked-seller';
  static const linkedBuyer = 'linked-buyer';
  static const linkedTransit = 'linked-transit';
  static const toolGenerated = 'tool-generated';
  static const distributionTransit = 'distribution-transit';
  static const toolDistributionSource = 'tool-distribution-source';
  static const toolCollectionSource = 'tool-collection-source';
  static const launchDev = 'launch-dev';
  static const launchInternalBuyer = 'launch-internal-buyer';
  static const launchExternalBuyer = 'launch-external-buyer';
  static bool isTransit(String category) =>
      category == linkedTransit || category == distributionTransit;

  static const labels = {
    tradeGroup: '批量交易组',
    linkedSeller: '关联交易卖方',
    linkedBuyer: '关联交易买方',
    linkedTransit: '关联交易中转',
    toolGenerated: '工具生成钱包',
    distributionTransit: '分发中转',
    toolDistributionSource: '分发来源',
    toolCollectionSource: '归集来源',
    launchDev: '发币开发者',
    launchInternalBuyer: '发币内盘买方',
    launchExternalBuyer: '发币外盘买方',
  };

  static final byLabel = {for (final e in labels.entries) e.value: e.key};

  static const values = [
    tradeGroup,
    linkedSeller,
    linkedBuyer,
    linkedTransit,
    toolGenerated,
    distributionTransit,
    toolDistributionSource,
    toolCollectionSource,
    launchDev,
    launchInternalBuyer,
    launchExternalBuyer,
  ];
}
