/// Launchpad contracts on BSC (same addresses as the web version).
const fourManager = '0x5c952063c7fc8610FFDB798152D69F0B9550762b';
const fourHelper = '0xF251F83e40a78868FcfA3FA4599Dad6494E46034';
const flapPortal = '0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0';
const zeroAddress = '0x0000000000000000000000000000000000000000';
const wbnb = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';

/// Chain-verified venue and settlement used to select the executable route.
enum Venue {
  /// External market.
  router,
  fourCurve,
  flapCurve,

  /// Launchpad curve settled in a pool token.
  fourConvert,
  flapConvert,

  genius,

  /// Unrecognized settlement venue.
  unsupported,
}

class Market {
  Market(this.raw);
  final Map<String, dynamic> raw;

  bool get geniusM52 => platform == 'genius' && genius['version'] == 'm5.2';

  String get address => '${raw['address']}';
  String get symbol => '${raw['symbol']}';
  int get decimals => raw['decimals'] as int;
  String get platform => '${raw['platform']}';
  bool get external => raw['external'] == true;
  String get quote => '${raw['quote']}';
  bool get nativeToQuoteSwapEnabled => platform == 'flap' && raw['nativeToQuoteSwapEnabled'] == true;
  bool get bnbQuoted => quote.toLowerCase() == zeroAddress;
  BigInt get buyTaxBps => BigInt.parse('${raw['buyTaxBps'] ?? 0}');
  BigInt get sellTaxBps => BigInt.parse('${raw['sellTaxBps'] ?? 0}');
  String? get pool => raw['pool'] as String?;
  int get block => raw['block'] as int;

  String? get innerPlatform => !external && const {'four', 'flap', 'genius'}.contains(platform) ? platform : null;

  BigInt sellUnits(BigInt amount) {
    if (innerPlatform != 'four') return amount;
    final lot = BigInt.from(1000000000);
    return amount ~/ lot * lot;
  }

  String? get innerTarget => switch (innerPlatform) {
    'four' => fourManager,
    'flap' => flapPortal,
    'genius' => genius['curve'] as String?,
    _ => null,
  };

  Venue get venue {
    if (external) return Venue.router;
    if (platform == 'genius') return Venue.genius;
    if (platform == 'flap')
      return bnbQuoted ? Venue.flapCurve : Venue.flapConvert;
    if (platform == 'external' || external) return Venue.router;
    if (platform == 'four')
      return bnbQuoted ? Venue.fourCurve : Venue.fourConvert;
    return Venue.unsupported;
  }

  Map<String, dynamic> get genius =>
      (raw['genius'] as Map? ?? const {}).cast<String, dynamic>();
  int get geniusPhase => (genius['phase'] as num? ?? 0).toInt();

  /// "Four · 内盘 · BNB 结算" style label (as in the web sidebar).
  String get label {
    final name = switch (platform) {
      'four' => 'Four.meme',
      'flap' => 'Flap',
      'genius' => geniusM52 ? 'Genius m5.2' : 'Genius',
      _ => 'UXUY',
    };
    final side = platform == 'external' ? '外盘' : (external ? '外盘' : '内盘');
    final settle = bnbQuoted ? 'BNB 结算' : '底池币结算';
    return '$name · $side · $settle';
  }
}
