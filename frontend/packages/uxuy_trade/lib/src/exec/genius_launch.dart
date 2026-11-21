import 'dart:async';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../api/backend_client.dart';
import '../evm/abi.dart';
import '../evm/evm.dart';
import '../crypto/keccak.dart';
import '../wallet/wallet.dart';
import 'executor.dart';
import 'genius_configurable.dart';
import 'launch.dart';
import 'market.dart' show zeroAddress;

part 'genius_official_bundle.dart';

/// Official deployments: UI V1/V2 map to Genius m4.1 / m4.2.
const geniusFactories = {
  geniusM52: geniusM52Factory,
  'v1': '0x78EAE9537C0ef90DFe9B7ae964682Fe8138afe31',
  'v2': '0x37eE8AeE29C5efd3C1A7edA6dF3F510779928a37',
};
const geniusAlphaRegistry = '0x9d60a14653b266f9d09e2137a5236f0c112ed42b';

const geniusOuterWalletLimit = 200;
int geniusInnerWalletLimit({required bool migrate, required BigInt tip}) =>
    !migrate && tip > BigInt.zero ? 95 : 96;

const _params =
    '(string,string,string,string,(string,string,string,string,string),address,uint16,bool,bytes32,bytes32)';
final _launchV1 = AbiFunction.parse(
  'launchToken($_params,uint256,address,bool) returns (address,address)',
);
final _launchV2 = AbiFunction.parse(
  'launchToken($_params,uint256,address,bool,address[]) returns (address,address)',
);
final _launchFee = AbiFunction.parse('launchFee() returns (uint256)');
final _launchEnabled = AbiFunction.parse('launchEnabled() returns (bool)');
final _canLaunch = AbiFunction.parse('canLaunch(address) returns (bool)');
final _approvedPair = AbiFunction.parse(
  'approvedPairTokens(address) returns (bool)',
);
final _launchConfig = AbiFunction.parse(
  'getLaunchConfig(uint256) returns ((uint256,uint256,uint256,uint256,uint24,int24,bool))',
);
final _economics = AbiFunction.parse(
  'previewLaunchEconomics(uint256,address) returns (bytes32)',
);
final _maxCreatorTax = AbiFunction.parse('maxCreatorTaxBps() returns (uint16)');
final _alphaPrice = AbiFunction.parse('priceWei() returns (uint256)');
final _alphaFactory = AbiFunction.parse(
  'approvedFactories(address) returns (bool)',
);
final _alphaPromote = AbiFunction.parse('promote(address,address)');
typedef GeniusAlphaQuote = ({String factory, BigInt priceWei});

List<(String, AbiFunction, List<Object?>)> _alphaCalls(String factory) => [
  (geniusAlphaRegistry, _alphaPrice, []),
  (geniusAlphaRegistry, _alphaFactory, [factory]),
];

GeniusAlphaQuote _alphaQuote(String factory, Map<AbiFunction, Object?> values) {
  if (values[_alphaFactory] != true) {
    throw StateError('当前 Genius 版本尚未开放 Alpha');
  }
  final price = values[_alphaPrice] as BigInt;
  if (price <= BigInt.zero) throw StateError('Alpha 费用无效，请重新读取');
  return (factory: factory, priceWei: price);
}

/// Web geniusImageMessage: the dev signs the image hash; the upload authorises nothing on chain.
String geniusImageMessage(String sha256Hex, String mime, String timestamp) =>
    'Genius Launchpad image upload\nOrigin: https://genius.fun\nChain ID: 56\nImage SHA-256: ${sha256Hex.toLowerCase()}\n'
    'Content-Type: $mime\nIssued at: $timestamp\nAuthorize one image upload. This does not authorize a transaction.';

bool validGeniusImageUri(String uri) =>
    uri.length <= 2048 &&
    (RegExp(r'^ipfs://[a-zA-Z0-9][a-zA-Z0-9/_-]*$').hasMatch(uri) ||
        RegExp(r'^https://[^\s<>"\\]+$').hasMatch(uri));

void validateGeniusImage(List<int> b, String mime) {
  if (b.isEmpty || b.length > 2 * 1024 * 1024) {
    throw const FormatException('图片须大于 0 且不超过 2 MB');
  }
  bool at(int o, List<int> v) =>
      b.length >= o + v.length &&
      [for (var i = 0; i < v.length; i++) b[o + i] == v[i]].every((x) => x);
  final ok = switch (mime) {
    'image/png' => at(0, [137, 80, 78, 71, 13, 10, 26, 10]),
    'image/jpeg' => at(0, [255, 216, 255]),
    'image/webp' => at(0, [82, 73, 70, 70]) && at(8, [87, 69, 66, 80]),
    'image/gif' =>
      at(0, [71, 73, 70, 56, 55, 97]) || at(0, [71, 73, 70, 56, 57, 97]),
    _ => false,
  };
  if (!ok) throw const FormatException('请选择有效的 PNG、JPG、WEBP 或 GIF 图片');
}

class GeniusLaunchForm {
  GeniusLaunchForm({
    this.version = geniusM52,
    this.policy = const GeniusConfigurablePolicy(),
    required this.name,
    required this.symbol,
    required this.logo,
    this.description = '',
    this.socials = const {},
    this.quote = zeroAddress,
    this.configId = 0,
    required this.creatorFeeRecipient,
    this.creatorTaxBps = 0,
    this.toFoundation = false,
    this.external = false,
    this.payWithBnb = false,
    this.snipeTaxExemptions = const [],
    this.exemptInternal = false,
    this.alpha = false,
    this.confirmedAlpha,
    BigInt? tip,
  }) : tip = tip ?? BigInt.zero;
  final String version;
  final GeniusConfigurablePolicy policy;
  final String name;
  final String symbol;

  /// ipfs:// or https:// URI returned by the signed image upload.
  final String logo;
  final String description;

  /// twitter / telegram / discord / website / farcaster (HTTPS only).
  final Map<String, String> socials;
  final String quote;
  final int configId;
  final String creatorFeeRecipient;
  final int creatorTaxBps;
  final bool toFoundation;
  final bool external;
  final bool payWithBnb;

  /// V2 only: extra addresses exempt from the opening snipe tax (max 32); [exemptInternal] adds internal buyers.
  final List<String> snipeTaxExemptions;
  final bool exemptInternal;
  final bool alpha;
  final GeniusAlphaQuote? confirmedAlpha;
  final BigInt tip;
}

/// Official Genius token creation, optional Alpha registration and builder tip.
class GeniusLauncher extends Launcher {
  GeniusLauncher(
    super.api,
    super.log, {
    super.sleep,
    super.pollEvery,
    this.random,
  }) : super(label: 'Genius');
  final Random? random;

  Future<Map<AbiFunction, Object?>> _readConfig(
    List<(String, AbiFunction, List<Object?>)> calls,
  ) async {
    final raw = await api.rpc([
      for (final (to, fn, args) in calls)
        (
          'eth_call',
          [
            {'to': to, 'data': bytesToHex(fn.encode(args))},
            'latest',
          ],
        ),
    ]);
    return {
      for (var i = 0; i < calls.length; i++)
        calls[i].$2: calls[i].$2.decodeOutput(raw[i] as String).single,
    };
  }

  Future<
    ({
      BigInt fee,
      BigInt threshold,
      BigInt curveFeeBps,
      int decimals,
      String symbol,
    })
  >
  previewPool(String address) async {
    final quote = checksumAddress(address);
    final native = quote.toLowerCase() == zeroAddress;
    final factory = geniusFactories[geniusM52]!;
    final values = await _readConfig([
      (factory, _launchEnabled, []),
      (factory, _launchFee, []),
      (factory, _launchConfig, [BigInt.zero]),
      if (!native) (factory, _approvedPair, [quote]),
    ]);
    final config = values[_launchConfig] as List<Object?>;
    if (values[_launchEnabled] != true || config[6] != true)
      throw StateError('当前发币配置已关闭');
    if (!native && values[_approvedPair] != true)
      throw StateError('Genius 尚未支持所选底池币');
    var threshold = config[3] as BigInt;
    var decimals = 18;
    var symbol = 'BNB';
    if (!native) {
      final terms = AbiFunction.parse(
        'pairTokenEconomics(address) returns (uint256,uint256,uint8)',
      );
      final raw = await api.rpc([
        (
          'eth_call',
          [
            {
              'to': factory,
              'data': bytesToHex(terms.encode([quote])),
            },
            'latest',
          ],
        ),
      ]);
      final pair = terms.decodeOutput(raw.single as String);
      final meta = await api.token(quote);
      decimals = (pair[2] as BigInt).toInt();
      if (meta.decimals != decimals || decimals > 36)
        throw StateError('Genius 底池精度与当前代币不一致');
      threshold = pair[1] as BigInt;
      symbol = meta.symbol;
    }
    return (
      fee: values[_launchFee] as BigInt,
      threshold: threshold,
      curveFeeBps: config[1] as BigInt,
      decimals: decimals,
      symbol: symbol,
    );
  }

  Future<GeniusAlphaQuote> quoteAlpha(String version) async {
    final factory =
        geniusFactories[version] ?? (throw StateError('Genius 版本无效'));
    return _alphaQuote(factory, await _readConfig(_alphaCalls(factory)));
  }

  ({String key, String id, String capability})? _pendingImage;

  /// Resume the same review after a timeout or an unreadable status response.
  Future<String> uploadImage(LaunchImage image, TradeWallet dev) async {
    validateGeniusImage(image.bytes, image.mime);
    final hash = sha256.convert(image.bytes).toString();
    final key = '${dev.address.toLowerCase()}/${image.mime}/$hash';
    String? uri(Map<String, dynamic> response) =>
        ['approved', 'needs_review'].contains(response['status']) &&
            validGeniusImageUri('${response['uri']}')
        ? '${response['uri']}'
        : null;
    var job = _pendingImage;
    if (job == null || job.key != key) {
      _pendingImage = null;
      final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final body = await api.geniusUpload(
        image,
        address: dev.address,
        signature: dev.signMessage(geniusImageMessage(hash, image.mime, ts)),
        timestamp: ts,
      );
      final direct = uri(body);
      if (direct != null) return direct;
      if (body['status'] == 'rejected') throw StateError('Genius 拒绝了这张图片，请更换');
      final id = '${body['uploadId'] ?? ''}';
      final capability = '${body['capability'] ?? ''}';
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
          !RegExp(r'^[A-Za-z0-9._~-]{16,256}$').hasMatch(capability)) {
        throw StateError('Genius 未返回图片上传凭据');
      }
      job = _pendingImage = (key: key, id: id, capability: capability);
    }
    for (var i = 0; i < 60; i++) {
      await waitForNextPoll();
      final status = await api.geniusUploadStatus(job.id, job.capability);
      final ready = uri(status);
      if (ready != null || status['status'] == 'rejected') {
        if (_pendingImage == job) _pendingImage = null;
        if (ready != null) return ready;
        throw StateError('Genius 拒绝了这张图片，请更换');
      }
      if (!['pending', 'approved', 'needs_review'].contains(status['status'])) {
        throw StateError('Genius 图片尚未处理成功，请重试查询');
      }
    }
    throw StateError('Genius 图片仍在处理中，请稍后继续查询');
  }

  List<String> _exemptions(
    GeniusLaunchForm f,
    TradeWallet dev,
    List<LaunchBuyer> internal,
  ) {
    if (f.version == 'v1') return const [];
    final automatic = <String>{
      dev.address.toLowerCase(),
      if (f.version != geniusM52 ||
          f.policy.recipients.isEmpty &&
              f.policy.burnBps + f.policy.rewardsBps + f.policy.liquidityBps <
                  10000)
        f.creatorFeeRecipient.toLowerCase(),
      if (f.version == geniusM52)
        ...f.policy.recipients.map((r) => r.$1.toLowerCase()),
    };
    final list = <String>[];
    for (final a in [
      ...f.snipeTaxExemptions,
      if (f.exemptInternal) ...internal.map((b) => b.wallet.address),
    ]) {
      final t = a.trim();
      if (t.isEmpty) continue;
      if (!isAddress(t) ||
          BigInt.parse(t.substring(2), radix: 16) == BigInt.zero) {
        throw const FormatException('免税地址无效');
      }
      final c = checksumAddress(t);
      if (!automatic.contains(c.toLowerCase()) && !list.contains(c)) {
        list.add(c);
      }
    }
    if (f.version != geniusM52 && list.length > 32)
      throw StateError('开盘免税名单最多 32 个额外地址，请减少地址或取消内盘免税');
    return list;
  }

  void _validate(
    GeniusLaunchForm f,
    LaunchBuyer dev,
    List<LaunchBuyer> internal,
    List<LaunchBuyer> external,
  ) {
    if (f.version == geniusM52 && (f.toFoundation || f.creatorTaxBps != 0)) {
      throw const FormatException('Genius m5.2 请使用可配置税收策略');
    }
    if (!geniusFactories.containsKey(f.version)) {
      throw StateError('Genius 版本无效');
    }
    int bytes(String s) => utf8Encode(s).length;
    if (f.name.trim().isEmpty || f.symbol.trim().isEmpty) {
      throw const FormatException('请填写代币名称和简写');
    }
    if (bytes(f.name) > 64 ||
        bytes(f.symbol) > 16 ||
        bytes(f.description) > 2048 ||
        bytes(f.logo) > 512) {
      throw const FormatException('代币名称、简写、图片链接或描述超出官方字节限制');
    }
    if (!validGeniusImageUri(f.logo)) throw const FormatException('请先完成代币图片上传');
    if (!isAddress(f.creatorFeeRecipient) ||
        BigInt.parse(f.creatorFeeRecipient.substring(2), radix: 16) ==
            BigInt.zero) {
      throw const FormatException('收益地址无效');
    }
    if (f.creatorTaxBps < 0 || f.configId < 0) {
      throw const FormatException('发币配置无效');
    }
    for (final v in f.socials.values) {
      if (v.isNotEmpty &&
          (!v.toLowerCase().startsWith('https://') || bytes(v) > 256)) {
        throw const FormatException('社交链接须为 HTTPS，且不超过 256 字节');
      }
    }
    validateLaunchPurchases(dev, internal, external, migrate: f.external);
    final innerLimit = geniusInnerWalletLimit(migrate: f.external, tip: f.tip);
    if (internal.length > innerLimit || external.length > geniusOuterWalletLimit)
      throw StateError('本次 Genius 内盘最多 $innerLimit 个额外钱包，外盘最多 $geniusOuterWalletLimit 个');
    if ((internal.isNotEmpty || f.external || external.isNotEmpty) &&
        f.version != geniusM52)
      throw StateError('此同块发币方案需要 Genius m5.2');
    if (f.external && internal.isEmpty && dev.amount == BigInt.zero)
      throw StateError('同块毕业需要有实际金额的内盘购买');
  }

  Future<void> launch(
    GeniusLaunchForm f, {
    required LaunchBuyer dev,
    List<LaunchBuyer> internal = const [],
    List<LaunchBuyer> external = const [],
  }) => guard(() async {
    step('1/7 校验参数');
    _validate(f, dev, internal, external);
    final factory = geniusFactories[f.version]!;
    final confirmedAlpha = f.confirmedAlpha;
    if (f.alpha &&
        (confirmedAlpha == null ||
            confirmedAlpha.factory != factory ||
            confirmedAlpha.priceWei <= BigInt.zero)) {
      throw StateError('请重新确认开通 Alpha 的费用');
    }
    final configurable = f.version == geniusM52;
    if (!configurable && dev.amount > BigInt.zero)
      throw StateError('原子首买需要 Genius m5.2');
    final quote = checksumAddress(f.quote);
    final convert = f.payWithBnb && quote.toLowerCase() != zeroAddress;
    // A direct Dev purchase is embedded in creation. A converted Dev needs
    // both its own funding swap and an official curve buy, like every buyer.
    final separateBuys = internal.length + external.length +
        (convert && dev.amount > BigInt.zero ? 1 : 0);
    final plannedTransactions = 1 + separateBuys + (convert ? separateBuys : 0) +
        (f.external ? 1 : 0) + (f.alpha ? 1 : 0) + (f.tip > BigInt.zero ? 1 : 0);
    if (plannedTransactions > launchBundleTransactionLimit) {
      throw StateError('Genius 发币共 $plannedTransactions 笔，超过单个捆绑上限 $launchBundleTransactionLimit，请减少购买钱包数量');
    }
    final funding = await LaunchFunding.prepare(
      api, quote, [dev, ...internal, ...external], convert: convert,
    );
    // A converted Dev payment is an official curve order directly after creation.
    final userInternal = internal;
    if (funding.converted) {
      internal = [if (dev.amount > BigInt.zero) funding.units(dev), ...internal.map(funding.units)];
      external = external.map(funding.units).toList();
      dev = LaunchBuyer(dev.wallet, BigInt.zero);
    }
    if (external.any((b) => b.amount.bitLength > 128))
      throw StateError('Genius 官方外盘输入超过 uint128 上限');
    final withBuy = dev.amount > BigInt.zero;
    step('2/7 读取 Genius ${f.version} 发币配置');
    final configId = BigInt.from(f.configId);
    final calls = <(String, AbiFunction, List<Object?>)>[
      (factory, _launchFee, []),
      if (configurable) ...[
        (factory, _launchEnabled, []),
        (factory, geniusPlatformPolicy, []),
      ] else ...[
        (factory, _canLaunch, [dev.wallet.address]),
        (factory, _maxCreatorTax, []),
        (factory, _economics, [configId, quote]),
      ],
      (factory, _launchConfig, [configId]),
      if (quote.toLowerCase() != zeroAddress) (factory, _approvedPair, [quote]),
      if (f.alpha) ..._alphaCalls(factory),
    ];
    final values = await _readConfig(calls);
    final fee = values[_launchFee]! as BigInt;
    final canLaunch =
        values[configurable ? _launchEnabled : _canLaunch] == true;
    final approved =
        quote.toLowerCase() == zeroAddress || values[_approvedPair] == true;
    final config = values[_launchConfig]! as List<Object?>;
    final alphaQuote = f.alpha ? _alphaQuote(factory, values) : null;
    if (alphaQuote != null && alphaQuote != confirmedAlpha) {
      throw StateError(
        'Alpha 费用已变为 ${formatUnits(alphaQuote.priceWei, 18, maxFraction: 18)} BNB，请重新准备并确认',
      );
    }
    if (!canLaunch) throw StateError('Genius 当前不允许此地址发币');
    if (!approved) throw StateError('Genius 尚未支持所选底池币');
    if (config[6] != true) throw StateError('Genius 所选发币配置已关闭');
    if (!configurable) {
      final maxTax = (values[_maxCreatorTax]! as BigInt).toInt();
      if (f.creatorTaxBps > maxTax) {
        throw StateError('Genius 当前最高创作者税为 ${maxTax / 100}%');
      }
    }

    final rnd = random ?? Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(32, (_) => rnd.nextInt(256)),
    );
    final s = f.socials;
    final metadata = <Object?>[
      f.name.trim(),
      f.symbol.trim(),
      f.logo,
      f.description,
      [
        s['twitter'] ?? '',
        s['telegram'] ?? '',
        s['discord'] ?? '',
        s['website'] ?? '',
        s['farcaster'] ?? '',
      ],
    ];
    final exemptions = _exemptions(f, dev.wallet, userInternal);
    step('3/7 计算官方创建地址');
    late final Uint8List createData;
    late final String token;
    late final String curve;
    late final Uint8List plainCreate;
    late final Map<String, Object?> launchContext;
    Uint8List Function(BigInt)? encodePurchase;
    if (configurable) {
      final policy = f.policy.encode(
        defaultRecipient: f.creatorFeeRecipient,
        exemptions: exemptions,
        platform: values[geniusPlatformPolicy]! as List<Object?>,
        supply: config.first! as BigInt,
      );
      final params = [
        ...metadata,
        salt,
        configId,
        quote,
        dev.wallet.address,
        policy,
      ];
      final response = await api.rpc([
        (
          'eth_call',
          [
            {
              'from': dev.wallet.address,
              'to': factory,
              'data': bytesToHex(
                geniusPreview.encode([params, dev.wallet.address]),
              ),
            },
            'latest',
          ],
        ),
      ]);
      final result = geniusPreview.decodeOutput(response.single as String);
      token = checksumAddress(result[0] as String);
      curve = checksumAddress(result[1] as String);
      launchContext = {
        'dev': dev.wallet.address,
        'to': factory,
        'data': geniusPreview.encodeHex([params, dev.wallet.address]),
        'value': '0',
      };
      final commitment = result[2] as Uint8List;
      if (token.toLowerCase() == zeroAddress ||
          (result[1] as String).toLowerCase() == zeroAddress ||
          commitment.every((byte) => byte == 0)) {
        throw StateError('Genius m5.2 创建预览无效');
      }
      plainCreate = geniusCreate.encode([params, commitment]);
      if (withBuy) {
        final deadline = BigInt.from(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        );
        encodePurchase = (minimum) => geniusCreateAndBuy.encode([
          params,
          commitment,
          dev.amount,
          minimum,
          deadline,
        ]);
        createData = encodePurchase(BigInt.one);
      } else {
        createData = plainCreate;
      }
    } else {
      final params = [
        ...metadata,
        checksumAddress(f.creatorFeeRecipient),
        f.creatorTaxBps,
        true,
        values[_economics],
        salt,
      ];
      final fn = f.version == 'v2' ? _launchV2 : _launchV1;
      createData = fn.encode([
        params,
        configId,
        quote,
        f.toFoundation,
        if (f.version == 'v2') exemptions,
      ]);
      final response = await api.rpc([
        (
          'eth_call',
          [
            {
              'from': dev.wallet.address,
              'to': factory,
              'data': bytesToHex(createData),
              'value': '0x${fee.toRadixString(16)}',
              'gas': '0xb71b00',
            },
            'latest',
          ],
        ),
      ]);
      token = checksumAddress(
        fn.decodeOutput(response.single as String).first as String,
      );
    }

    final extended = internal.isNotEmpty || f.external;
    final key = f.external
        ? await _readLaunchKey(
            dev.wallet,
            plainCreate,
            fee,
            token,
            curve,
            quote,
          )
        : null;
    final deadline = f.external ? await _outerDeadline() : 0;
    final native = quote.toLowerCase() == zeroAddress;
    if (withBuy && quote.toLowerCase() != zeroAddress) {
      await authorizeLaunchPayment(
        quote,
        geniusM52LaunchAndBuy,
        dev.wallet,
        dev.amount,
      );
    }
    if (extended && !native) {
      await authorizeLaunchPayments(
        quote,
        curve,
        internal,
        launchContext: launchContext,
        fundedInBundle: funding.converted,
      );
      await authorizeLaunchPayments(
        quote,
        geniusPermit2,
        external,
        launchContext: launchContext,
        fundedInBundle: funding.converted,
      );
      await _prepareOuterPermit(quote, external, launchContext, deadline);
    }
    await funding.executable(api);
    final txs = <LaunchTx>[];
    txs.add(
      LaunchTx(
        configurable ? '创建代币 · Genius m5.2' : '创建代币',
        dev.wallet,
        withBuy ? geniusM52LaunchAndBuy : factory,
        createData,
        fee +
            (withBuy && quote.toLowerCase() == zeroAddress
                ? dev.amount
                : BigInt.zero),
        12000000,
        kind: 'create',
        creationFee: fee,
        purchasedToken: withBuy ? token : null,
        protocolCheck: withBuy
            ? _sweepProof(token, f.external && internal.isEmpty)
            : null,
      ),
    );
    final orders = <int, LaunchTx Function(BigInt)>{};
    void addBuy(LaunchBuyer buyer, bool outer) {
      LaunchTx create(BigInt floor) => LaunchTx(
        outer ? 'Genius 外盘首买' : 'Genius 内盘首买',
        buyer.wallet,
        outer ? geniusInfinityRouter : curve,
        outer
            ? geniusInfinityBuy(
                key!,
                token,
                quote,
                buyer.amount,
                floor,
                BigInt.from(deadline),
              )
            : _curveBuy.encode([buyer.amount, floor, buyer.wallet.address]),
        native ? buyer.amount : BigInt.zero,
        5000000,
        kind: outer ? 'outer' : 'inner',
        purchasedToken: token,
        minimumDelivery: floor,
        protocolCheck: _buyerCashflow(
          quote,
          buyer,
          outer,
          outer
              ? null
              : _sweepProof(
                  token,
                  f.external && identical(buyer, internal.last),
                ),
        ),
      );
      orders[txs.length] = create;
      txs.add(create(BigInt.one));
    }

    for (final buyer in internal) {
      addBuy(buyer, false);
    }
    if (f.external) {
      txs.add(
        LaunchTx(
          'Genius 建立毕业池',
          dev.wallet,
          factory,
          _migratePool.encode([token]),
          BigInt.zero,
          12000000,
          kind: 'migrate',
          protocolCheck: _graduationProof(token, key!),
        ),
      );
      for (final buyer in external) {
        addBuy(buyer, true);
      }
    }
    if (alphaQuote != null) {
      txs.add(
        LaunchTx(
          '开通 Alpha',
          dev.wallet,
          geniusAlphaRegistry,
          _alphaPromote.encode([factory, token]),
          alphaQuote.priceWei,
          300000,
          kind: 'alpha',
          alphaToken: token,
        ),
      );
    }
    if (f.tip > BigInt.zero) {
      txs.add(
        LaunchTx(
          '贿赂费',
          dev.wallet,
          bscBundleTipRecipient,
          Uint8List(0),
          f.tip,
          100000,
          kind: 'tip',
        ),
      );
    }

    step('4/7 核对创建交易');
    final gas = await launchBundleGas(api);
    await simulateBundle(funding.include(txs), requireSuccess: true);
    if (encodePurchase != null) {
      final creation = txs.first;
      final measured = creation.simulatedDelivery!;
      final minimum =
          (measured * BigInt.from(9950) + BigInt.from(9999)) ~/
          BigInt.from(10000);
      txs[0] = LaunchTx(
        creation.label,
        dev.wallet,
        creation.to,
        encodePurchase(minimum),
        creation.value,
        12000000,
        kind: 'create',
        creationFee: fee,
        purchasedToken: token,
        minimumDelivery: minimum,
        protocolCheck: creation.protocolCheck,
      );
    }
    for (final order in orders.entries) {
      final delivered = txs[order.key].simulatedDelivery!;
      final floor =
          (delivered * BigInt.from(9950) + BigInt.from(9999)) ~/
          BigInt.from(10000);
      txs[order.key] = order.value(floor);
    }
    if (encodePurchase != null || extended) {
      await simulateBundle(
        funding.include(txs),
        requireSuccess: true,
        expectedCreatedToken: withBuy ? token : null,
      );
    }
    final signedOrder = funding.include(txs);
    if (extended) {
      await _verifyLaunchPhases(signedOrder, token, curve, quote, f.external, withBuy);
      await verifyGeniusBlockCapacity(signedOrder);
    }
    step('5/7 检查钱包余额');
    final devReserve = f.tip == BigInt.zero ? BigInt.zero :
        f.tip + gas.gasPrice * BigInt.from(txs.firstWhere((tx) => tx.kind == 'tip').gasLimit);
    final nonceMap = await checkBalances(
      signedOrder,
      gas.gasPrice,
      extra: {dev.wallet.address.toLowerCase(): devReserve},
    );
    step('6/7 本地签名并提交');
    await launchBundle(
      signedOrder,
      nonceMap,
      gas.gasPrice,
      LaunchSession(
        platform: 'genius',
        poolToken: quote,
        token: token,
        symbol: f.symbol.trim(),
        dev: dev.wallet,
        wallets: [
          dev.wallet,
          ...userInternal.map((b) => b.wallet),
          ...external.map((b) => b.wallet),
        ],
        tip: f.tip,
        reserved: devReserve,
      ),
    );
  });
}
