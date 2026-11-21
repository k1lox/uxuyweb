// Explicit adapters for the official BSC curated factories, captured 2026-11-16.
// Source: flap.sh launch helpers 753 modules 1922/2602/70575/80181/88112/97601.
// Never apply these encodings to an arbitrary factory or accept raw user calldata.
import 'dart:convert';
import 'dart:typed_data';

import '../api/backend_client.dart';
import '../evm/abi.dart';
import '../evm/evm.dart';
import 'flap_vault.dart';

const _zero = '0x0000000000000000000000000000000000000000';
const flapComputedDividendToken = '0xC0Dec0dec0DeC0Dec0dEc0DEC0DEC0DEC0DEC0dE';
const listaFlexFactory = '0x98CADb60545CCCF60Af94C161714420C21E7CBc2';
const listaStableFactory = '0x845c25ceE4F046663756d1245739e260ca70074C';
const listaLiquidFactory = '0x4c126de52d91eF2b5B29305733Dd4d81F5aB8B05';
const listaLockFactory = '0xC7C58c0B8E884B0f8CDBe918F3aB84881b59BcaB';
const _listaStableChild = '0x4b9D1bcD1BbB85e88c01878606C2E5E132c8571e';
const _listaLiquidChild = '0x551621e9D5DEf97329F8aff40Cec0a44a0f5AF94';
const _listaLockChild = '0x6bBE8078cB250Cb583e722864262D3b977d2BB57';
const _listaLiquidDividend = '0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B';
const flapMyxFactory = '0xeaEEa9c17a5376497C44fE2a5F9c63FE3B23bf87';
const _split = '0xfab75Dc774cB9B38b91749B8833360B46a52345F';
const _omni = '0x746e4978138240523cFb764E482f38AC04EdB6d3';
const _buyback = '0xB64655dab7156c29B63C70fb3ED7f071e2658D19';
const _gift = '0x5e8604a69158FA583b0C5c16441A9b3d429E7Cbb';
const _index = '0x5418f7e8fF90354DB0eCD48c8b710219244Eb3C5';
const _reserve = '0x08E41a61C5D25420E3cb314Bc513EC99B2841003';
const _yield = '0xfB12E8B393007Bb8d925Ed1c4D3eEB4854B51Fa6';
const _fomox = '0x71Cab5A1A8904B358C24032BB653F764EFa03F14';
const _scheduled = '0xC6A0fD000988317F50215EdD4098Ed3368f52250';
const _gmgn = '0x357c50d241dF58DC730AFc1e2Bf40B001768f3e0';
const _nft = '0x88a33780e1b3150Af85fBef52f344A43EBeC5A51';
const _nftRwa = '0x4a42C8A67Ce45cf449e0D2Ff24b9a5CeaCb74B69';
const _usdt = '0x55d398326f99059fF775485246999027B3197955';
const _usdc = '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d';
bool _is(String a, String b) => a.toLowerCase() == b.toLowerCase();

FlapVaultField _field(
  String name,
  String type,
  String description, [
  int decimals = 0,
]) => FlapVaultField(
  name: name,
  type: type,
  description: description,
  decimals: decimals,
);

/// Only these exact curated identities may supply a documented legacy form.
/// The live empty/reverted schema is still checked by FlapVaultService.
FlapVaultSchema? flapCuratedSchema(String factory) {
  if (_is(factory, _split)) {
    return FlapVaultSchema(
      description: '1–10 个收款地址；比例合计 100%，创建后不可修改。',
      isArray: true,
      fields: [
        _field('recipient', 'address', '收款地址'),
        _field('bps', 'uint16', '分配比例 %', 2),
      ],
    );
  }
  if (_is(factory, _buyback)) {
    return FlapVaultSchema(description: '无需额外参数。税收逐步用于回购并销毁。', fields: []);
  }
  if (_is(factory, _omni)) {
    return FlapVaultSchema(
      description: '资产类型：0 BNB、1 本币、2 LP。固定名单比例为 0 或 1–50%。',
      fields: [
        _field('rewardAssetType', 'uint8', '空投资产：0 BNB / 1 本币 / 2 LP'),
        _field('fixedSharePercent', 'uint16', '固定名单比例 %；0 为关闭', 2),
        _field('fixedAddresses', 'address[]', '固定名单，1–300 个非零地址；关闭时留空'),
      ],
    );
  }
  if (_is(factory, listaFlexFactory)) {
    return FlapVaultSchema(
      description: '锁仓档位依次对应；最多 4 档。锁仓天数、权重递增；最低质押为整数。',
      fields: [
        if (_is(factory, listaFlexFactory)) ...[
          _field('minimumShareBalance', 'uint256', '收益最低持仓', 18),
          _field('usdtStablePercent', 'uint8', 'USDT 生息比例 %'),
          _field('liquidStakingPercent', 'uint8', '流动性质押比例 %'),
          _field('tokenLockPercent', 'uint8', '代币锁仓比例 %'),
        ],
        _field('lockDays', 'uint16[]', '锁仓天数，逗号分隔，0–365'),
        _field('lockWeightBps', 'uint16[]', '各档权重，逗号分隔，100–50000'),
        _field('minStakeAmount', 'uint256[]', '各档最低质押，逗号分隔，1000–900000000', 18),
      ],
    );
  }
  return null;
}

Map<String, String> flapCuratedDefaults(String factory) {
  if (_is(factory, _split)) return {'recipient': '', 'bps': '100'};
  if (_is(factory, _omni))
    return {
      'rewardAssetType': '1',
      'fixedSharePercent': '0',
      'fixedAddresses': '',
    };
  if (_is(factory, listaStableFactory) || _is(factory, listaLiquidFactory))
    return {'minimumShareBalance': '10000'};
  if (_is(factory, listaLockFactory))
    return {
      for (var i = 0; i < 4; i++) ...{
        'lockDays${i + 1}': ['0', '90', '180', '365'][i],
        'lockWeightBps${i + 1}': ['10000', '15000', '22000', '30000'][i],
        'minStakeAmount${i + 1}': '1000',
      },
    };
  if (_is(factory, listaFlexFactory))
    return {
      'minimumShareBalance': '10000',
      'usdtStablePercent': '34',
      'liquidStakingPercent': '33',
      'tokenLockPercent': '33',
      'lockDays': '0,90,180,365',
      'lockWeightBps': '10000,15000,22000,30000',
      'minStakeAmount': '1000,1000,1000,1000',
    };
  if (_is(factory, _fomox))
    return {'claimUsdE18': '2', 'minTaxBalance': '10000'};
  if (_is(factory, _gmgn))
    return {
      'rewardAt50Usd': '1',
      'rewardAt200Usd': '2',
      'rewardAt500Usd': '5',
      'rewardAt1000Usd': '10',
      'rewardAt10000Usd': '100',
      'intervalHours': '2',
      'minimumHolding': '1000',
    };
  if (_is(factory, _yield))
    return {
      'minimumShareBalance': '10000',
      'marketingWallet': _zero,
      'marketingSharePercent': '0',
    };
  if (_is(factory, _index)) return {'instantDividend': 'false'};
  if (_is(factory, _scheduled))
    return {
      'buybackMode': '0',
      'triggerMode': '0',
      'startDelayMinutes': '1',
      'buybackIntervalMinutes': '1',
      'triggerAmount': '0',
      'buybackAmount': '0.001',
    };
  if (_is(factory, flapMyxFactory))
    return {
      'marketQuoteToken': _usdt,
      'gasThreshold': '0',
      'gasRefillAmount': '0',
      'maxProcessAmount': ((BigInt.one << 256) - BigInt.one).toString(),
    };
  if (_is(factory, '0x9F5bF8EB9c4cA7179E60d0B529F4910B9A7eE0Ee'))
    return {'minBurnAmount': '100'};
  if (_is(factory, '0x7c8781B21FB004308a5a2bB7F9cB1E2e6Bd1fC7E'))
    return {'decisionCooldown / 决策冷却时间': '60'};
  if (_is(factory, '0xFCe2509d232FB62dc15c9Bf2faDE69653e480a25'))
    return {'decisionCooldown': '60'};
  if (_is(factory, '0xf68eE35A4fDe7a7C3e4baf01Dac019B4A90Fa1db'))
    return {'minStakeForReward': '0'};
  if (_is(factory, '0xf3056DAa77db106f25ba8c32EE78E5d40777fbaf'))
    return {'winnersCount': '1', 'minPrizePool': '0.01'};
  return {};
}

List<String> _items(String value) {
  final s = value.trim();
  if (s.isEmpty) return [];
  if (s.startsWith('[')) {
    final j = jsonDecode(s);
    if (j is! List || j.any((x) => x is! String && x is! num))
      throw const FormatException('金库格式有误');
    return j.map((x) => '$x'.trim()).toList();
  }
  return s.split(RegExp(r'[\s,;，]+')).where((v) => v.isNotEmpty).toList();
}

BigInt _amount(Map<String, String> row, String field, [int decimals = 0]) {
  final value = row[field]?.trim() ?? '';
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value))
    throw FormatException('请填写有效的 $field');
  final parts = value.split('.');
  if (parts.length == 2 && parts[1].length > decimals)
    throw FormatException('$field 最多支持 $decimals 位小数');
  final n = parseUnits(value, decimals);
  if (n.bitLength > 256) throw FormatException('$field 数值过大');
  return n;
}

void _range(BigInt n, BigInt low, BigInt high, String label) {
  if (n < low || n > high) throw FormatException('$label 超出允许范围');
}

void _small(Map<String, String> row, String field, int low, int high) =>
    _range(_amount(row, field), BigInt.from(low), BigInt.from(high), field);

List<String> _addresses(
  String raw, {
  int max = 300,
  bool allowZero = false,
  bool allowEmpty = false,
}) {
  final a = _items(raw);
  if ((!allowEmpty && a.isEmpty) || a.length > max)
    throw FormatException('地址数量必须为 ${allowEmpty ? 0 : 1}–$max');
  final seen = <String>{};
  for (final v in a) {
    if (!isAddress(v) || (!allowZero && _is(v, _zero)))
      throw const FormatException('请输入有效的非零地址');
    if (!seen.add(v.toLowerCase())) throw const FormatException('地址不能重复');
  }
  return a.map(checksumAddress).toList();
}

Uint8List _abi(List<String> types, List<Object?> values) =>
    encodeSequence(types.map(AbiType.parse).toList(), values);

List<List<Object?>> _listaTiers(Map<String, String> row) {
  final flat = row.containsKey('lockDays1');
  final days = flat
      ? [for (var i = 1; i <= 4; i++) row['lockDays$i'] ?? '']
      : _items(row['lockDays'] ?? '');
  final weights = flat
      ? [for (var i = 1; i <= 4; i++) row['lockWeightBps$i'] ?? '']
      : _items(row['lockWeightBps'] ?? '');
  final stakes = flat
      ? [for (var i = 1; i <= 4; i++) row['minStakeAmount$i'] ?? '']
      : _items(row['minStakeAmount'] ?? '');
  if (days.isEmpty ||
      days.length > 4 ||
      weights.length != days.length ||
      stakes.length != days.length)
    throw const FormatException('锁仓配置需要 1–4 个对应档位');
  final out = <List<Object?>>[];
  var lastDay = -1;
  var lastWeight = -1;
  var disabled = false;
  for (var i = 0; i < days.length; i++) {
    final day = _amount({'v': days[i]}, 'v').toInt();
    if (day > 365) throw const FormatException('锁仓天数必须为 0–365');
    if (i > 0 && day == 0) {
      disabled = true;
      out.add([0, 0, BigInt.zero]);
      continue;
    }
    if (disabled) throw const FormatException('关闭的锁仓档位后不能再启用档位');
    final weight = _amount({'v': weights[i]}, 'v').toInt();
    if (weight < 100 ||
        weight > 50000 ||
        (i > 0 && (day <= lastDay || weight <= lastWeight)))
      throw const FormatException('锁仓天数与权重必须递增；权重范围 100–50000');
    if (!RegExp(r'^\d+$').hasMatch(stakes[i]))
      throw const FormatException('最低质押必须为整数');
    final stake = _amount({'v': stakes[i]}, 'v', 18);
    _range(stake, parseUnits('1000', 18), parseUnits('900000000', 18), '最低质押');
    out.add([day, weight, stake]);
    lastDay = day;
    lastWeight = weight;
  }
  while (out.length < 4) {
    out.add([0, 0, BigInt.zero]);
  }
  return out;
}

/// An immutable curated selection. Exact bytes are derived from typed form values;
/// no raw vaultData can enter this class from user input.
class CuratedFlapVaultSelection extends FlapVaultSelection {
  CuratedFlapVaultSelection({required super.info, required super.rows})
    : super(legacySchema: flapCuratedSchema(info.factory));

  String? get dividendToken =>
      flapCuratedDividendToken(factory, info.quoteToken, rows);
  BigInt? get minimumShare => flapCuratedMinimumShare(factory, rows);

  @override
  Uint8List encode() {
    _checkCuratedShape(info);
    validateFlapCuratedRows(factory, rows, quoteToken: info.quoteToken);
    if (_is(factory, _split))
      return _abi(
        ['(address,uint16)[]'],
        [
          rows
              .map(
                (r) => [checksumAddress(r['recipient']!), _amount(r, 'bps', 2)],
              )
              .toList(),
        ],
      );
    if (_is(factory, _reserve))
      return _abi(
        ['address[]'],
        [rows.map((r) => checksumAddress(r['selectedAsset']!)).toList()],
      );
    if (_is(factory, _buyback)) return Uint8List(0);
    final row = rows.isEmpty ? const <String, String>{} : rows.single;
    if (_is(factory, _omni)) {
      final share = _amount(row, 'fixedSharePercent', 2);
      final addresses = _addresses(
        row['fixedAddresses'] ?? '',
        allowEmpty: true,
      );
      final packed = Uint8List.fromList(
        addresses.expand((a) => hexToBytes(a)).toList(),
      );
      return _abi(
        ['uint256', 'uint256', 'bytes'],
        [_amount(row, 'rewardAssetType'), share, packed],
      );
    }
    if (_is(factory, listaStableFactory) || _is(factory, listaLiquidFactory))
      return _abi(['uint256'], [_amount(row, 'minimumShareBalance', 18)]);
    if (_is(factory, listaLockFactory))
      return _abi(['(uint16,uint16,uint256)[4]'], [_listaTiers(row)]);
    if (_is(factory, listaFlexFactory)) {
      final stable = _amount(row, 'usdtStablePercent').toInt();
      final liquid = _amount(row, 'liquidStakingPercent').toInt();
      final lock = _amount(row, 'tokenLockPercent').toInt();
      final lockData = lock > 0
          ? _abi(['(uint16,uint16,uint256)[4]'], [_listaTiers(row)])
          : Uint8List(0);
      return _abi(
        ['uint256', '(address,bytes)[]', '(address,uint16,uint8,bytes)[]'],
        [
          _amount(row, 'minimumShareBalance', 18),
          [
            if (liquid > 0) [_listaLiquidChild, Uint8List(0)],
          ],
          [
            if (stable > 0) [_listaStableChild, stable * 100, 0, Uint8List(0)],
            if (liquid > 0) [_listaLiquidChild, liquid * 100, 0, Uint8List(0)],
            if (lock > 0) [_listaLockChild, lock * 100, 1, lockData],
          ],
        ],
      );
    }
    // These factories deliberately use flat values, unlike the standard schema tuple.
    if (_is(factory, _index))
      return _abi(
        ['address[]', 'string', 'bool'],
        [
          _addresses(row['selectedAssets'] ?? '', max: 10),
          row['symbol']!.trim(),
          row['instantDividend'] == 'true',
        ],
      );
    return super.encode();
  }
}

typedef FlapCuratedVaultSelection = CuratedFlapVaultSelection;

CuratedFlapVaultSelection buildFlapCuratedSelection({
  required FlapVaultInfo info,
  required List<Map<String, String>> rows,
}) {
  final values = rows.map((r) => Map<String, String>.of(r)).toList();
  if ((_is(info.factory, _gift) || isFlapV7GiftFactory(info.factory)) &&
      values.length == 1)
    values.single['xHandle'] = (values.single['xHandle'] ?? '')
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
  if (_is(info.factory, _fomox) && values.length == 1) {
    // Official helper 88112: zero selects defaults; rewards are clamped and
    // the escrow balance is rounded down to whole tokens before confirmation.
    final row = values.single;
    for (final spec in [
      ('claimUsdE18', '2', '0.5', '10'),
      ('minTaxBalance', '10000', '10000', '1000000'),
    ]) {
      final text = (row[spec.$1] ?? '').trim();
      if (text.isNotEmpty &&
          !RegExp(r'^(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,18})?$')
              .hasMatch(text)) {
        throw FormatException('${spec.$1} 数值格式有误');
      }
      var n = _amount(
        {spec.$1: text.isEmpty ? '0' : text.replaceAll(',', '')},
        spec.$1,
        18,
      );
      if (n == BigInt.zero) n = parseUnits(spec.$2, 18);
      final low = parseUnits(spec.$3, 18), high = parseUnits(spec.$4, 18);
      if (n < low) n = low;
      if (n > high) n = high;
      if (spec.$1 == 'minTaxBalance')
        n = n ~/ parseUnits('1', 18) * parseUnits('1', 18);
      row[spec.$1] = formatUnits(n, 18, maxFraction: 18);
    }
  }
  final selection = CuratedFlapVaultSelection(info: info, rows: values);
  selection.encode();
  return selection;
}

void validateFlapCuratedRows(
  String factory,
  List<Map<String, String>> rows, {
  required String quoteToken,
}) {
  if (_is(factory, _split)) {
    if (rows.isEmpty || rows.length > 10)
      throw const FormatException('税收分配需要 1–10 个收款地址');
    _addresses(rows.map((r) => r['recipient'] ?? '').join(','), max: 10);
    var total = BigInt.zero;
    for (final row in rows) {
      final n = _amount(row, 'bps', 2);
      _range(n, BigInt.one, BigInt.from(10000), '收款比例');
      total += n;
    }
    if (total != BigInt.from(10000))
      throw const FormatException('税收分配合计必须为 100%');
    return;
  }
  if (_is(factory, _reserve)) {
    final addresses = _addresses(
      rows.map((r) => r['selectedAsset'] ?? '').join(','),
      max: 10,
      allowZero: true,
    );
    if (addresses.every(
      (a) => _is(a, '0x0000000000000000000000000000000000000001'),
    ))
      throw const FormatException('请至少选择一个储备资产');
    return;
  }
  if (rows.length > 1) throw const FormatException('金库格式有误');
  if (_is(factory, _buyback)) return;
  final row = rows.isEmpty ? const <String, String>{} : rows.single;
  if (_is(factory, _omni)) {
    _small(row, 'rewardAssetType', 0, 2);
    final bps = _amount(row, 'fixedSharePercent', 2);
    final addresses = _addresses(row['fixedAddresses'] ?? '', allowEmpty: true);
    if (bps == BigInt.zero) {
      if (addresses.isNotEmpty) throw const FormatException('固定名单关闭时，请清空名单');
    } else {
      _range(bps, BigInt.from(100), BigInt.from(5000), '固定名单比例');
      if (addresses.isEmpty) throw const FormatException('请填写固定名单');
    }
  }
  if (_is(factory, listaStableFactory) ||
      _is(factory, listaLiquidFactory) ||
      _is(factory, listaFlexFactory)) {
    if (_amount(row, 'minimumShareBalance', 18) < parseUnits('10000', 18))
      throw const FormatException('收益最低持仓不能低于 10,000');
  }
  if (_is(factory, listaLockFactory)) _listaTiers(row);
  if (_is(factory, listaFlexFactory)) {
    for (final field in [
      'usdtStablePercent',
      'liquidStakingPercent',
      'tokenLockPercent',
    ]) {
      _small(row, field, 0, 100);
    }
    final sum =
        _amount(row, 'usdtStablePercent') +
        _amount(row, 'liquidStakingPercent') +
        _amount(row, 'tokenLockPercent');
    if (sum != BigInt.from(100))
      throw const FormatException('Lista 策略比例合计必须为 100%');
    if (_amount(row, 'tokenLockPercent') > BigInt.zero) _listaTiers(row);
  }
  if ((_is(factory, _gift) || isFlapV7GiftFactory(factory)) &&
      !RegExp(r'^[a-z0-9_]{1,15}$').hasMatch(row['xHandle'] ?? ''))
    throw const FormatException('请输入有效的 X 账号，不含链接');
  if (_is(factory, _index)) {
    _addresses(row['selectedAssets'] ?? '', max: 10);
    if ((row['symbol'] ?? '').trim().isEmpty)
      throw const FormatException('请输入资产篮子简写');
    if (!['true', 'false'].contains(row['instantDividend']))
      throw const FormatException('请选择分红模式');
  }
  if (_is(factory, _yield)) {
    if (_amount(row, 'minimumShareBalance', 18) < parseUnits('10000', 18))
      throw const FormatException('收益最低持仓不能低于 10,000');
    _small(row, 'marketingSharePercent', 0, 50);
    final wallet = row['marketingWallet'] ?? '';
    if (!isAddress(wallet) ||
        (_amount(row, 'marketingSharePercent') > BigInt.zero &&
            _is(wallet, _zero)))
      throw const FormatException('启用营销分配时，请填写非零营销地址');
  }
  if (_is(factory, flapMyxFactory)) {
    if (![_usdt, _usdc].any((a) => _is(row['marketQuoteToken'] ?? '', a)))
      throw const FormatException('MYX 市场报价币仅支持 USDT 或 USDC');
    final min = _amount(row, 'minProcessAmount'),
        max = _amount(row, 'maxProcessAmount');
    if (min <= BigInt.zero || max < min)
      throw const FormatException('MYX 单次上限必须不少于最低处理金额');
    final threshold = _amount(row, 'gasThreshold', 18),
        refill = _amount(row, 'gasRefillAmount', 18);
    if (_is(quoteToken, _zero)) {
      if (threshold != BigInt.zero || refill != BigInt.zero)
        throw const FormatException('BNB 底池的 Gas 阈值和补充值必须为 0');
    } else if (refill <= threshold) {
      throw const FormatException('MYX Gas 补充目标必须大于阈值');
    }
  }
  if (_is(factory, '0x9F5bF8EB9c4cA7179E60d0B529F4910B9A7eE0Ee'))
    _range(
      _amount(row, 'minBurnAmount', 18),
      parseUnits('100', 18),
      parseUnits('100000', 18),
      '最低燃烧量',
    );
  if (_is(factory, '0x7c8781B21FB004308a5a2bB7F9cB1E2e6Bd1fC7E'))
    _small(row, 'decisionCooldown / 决策冷却时间', 60, 7200);
  if (_is(factory, '0xFCe2509d232FB62dc15c9Bf2faDE69653e480a25'))
    _small(row, 'decisionCooldown', 60, 7200);
  if (_is(factory, '0xf3056DAa77db106f25ba8c32EE78E5d40777fbaf')) {
    _small(row, 'winnersCount', 1, 10);
    if (_amount(row, 'minPrizePool', 18) < parseUnits('0.01', 18))
      throw const FormatException('开奖最低奖池不得低于 0.01 BNB');
  }
  if (_is(factory, _scheduled)) {
    _small(row, 'buybackMode', 0, 1);
    _small(row, 'triggerMode', 0, 2);
    final mode = _amount(row, 'triggerMode').toInt();
    _small(row, 'startDelayMinutes', mode == 1 ? 0 : 1, mode == 1 ? 0 : 525600);
    _small(row, 'buybackIntervalMinutes', 1, 525600);
    final trigger = _amount(row, 'triggerAmount', 18);
    if (mode == 0) {
      if (trigger != BigInt.zero)
        throw const FormatException('按时间触发时，金额阈值必须为 0');
    } else {
      _range(trigger, parseUnits('1', 18), parseUnits('1000', 18), '触发金额');
      if (trigger % parseUnits('1', 18) != BigInt.zero)
        throw const FormatException('触发金额必须为整数 BNB');
    }
    final amount = _amount(row, 'buybackAmount', 18);
    _range(amount, parseUnits('0.001', 18), parseUnits('10', 18), '单次回购金额');
    if (amount % parseUnits('0.001', 18) != BigInt.zero)
      throw const FormatException('单次回购金额最多支持三位小数');
  }
  if (_is(factory, _gmgn)) {
    for (final spec in [
      ('rewardAt50Usd', 1, 5),
      ('rewardAt200Usd', 2, 10),
      ('rewardAt500Usd', 5, 20),
      ('rewardAt1000Usd', 10, 50),
      ('rewardAt10000Usd', 100, 200),
    ]) {
      final n = _amount(row, spec.$1, 18);
      if (n != BigInt.zero)
        _range(
          n,
          parseUnits('${spec.$2}', 18),
          parseUnits('${spec.$3}', 18),
          spec.$1,
        );
    }
    _small(row, 'intervalHours', 0, 24);
    if (_amount(row, 'minimumHolding', 18) < parseUnits('1000', 18))
      throw const FormatException('最低持币不能低于 1,000');
  }
  if (_is(factory, _fomox)) {
    _range(
      _amount(row, 'claimUsdE18', 18),
      parseUnits('0.5', 18),
      parseUnits('10', 18),
      '每次奖励',
    );
    final min = _amount(row, 'minTaxBalance', 18);
    _range(min, parseUnits('10000', 18), parseUnits('1000000', 18), '托管税币');
    if (min % parseUnits('1', 18) != BigInt.zero)
      throw const FormatException('托管税币必须为整数');
  }
  if (_is(factory, _nft) || _is(factory, _nftRwa)) {
    if ((row['NFTName'] ?? '').trim().isEmpty ||
        (row['NFTSymbol'] ?? '').trim().isEmpty)
      throw const FormatException('请填写 NFT 名称和简写');
    final supply = _amount(row, 'maxNFTSupply'),
        floor = _amount(row, 'initialFloorNFTs');
    if (supply <= BigInt.zero ||
        floor > supply ||
        _amount(row, 'tokenCostPerNFT', 18) <= BigInt.zero)
      throw const FormatException('NFT 数量、托底数量或兑换金额无效');
    _small(row, 'dividendSharePercent', 0, 100);
    _small(row, 'floorSharePercent', 0, 100);
    if (_amount(row, 'dividendSharePercent') +
            _amount(row, 'floorSharePercent') >
        BigInt.from(100))
      throw const FormatException('NFT 分红与地板份额合计不能超过 100%');
  }
  if (_is(factory, '0x89a800a8fbB3538f8Ddb76C95034D23c249bF9D9') &&
      ((row['characterCid'] ?? '').trim().isEmpty ||
          (row['openingPrompt'] ?? '').trim().isEmpty))
    throw const FormatException('请填写角色 CID 和开场内容');
}

String? flapCuratedDividendToken(
  String factory,
  String quoteToken,
  List<Map<String, String>> rows,
) {
  if (_is(factory, _gift)) return quoteToken;
  if ([
    listaFlexFactory,
    listaStableFactory,
    _yield,
    flapMyxFactory,
    _index,
  ].any((f) => _is(factory, f)))
    return flapComputedDividendToken;
  if (_is(factory, listaLiquidFactory)) return _listaLiquidDividend;
  if (_is(factory, listaLockFactory)) return _zero;
  // VaultPortal rejects zero dividendToken for an ERC20 quote even when the
  // direct-dividend allocation is zero. Native quote deliberately keeps zero.
  return !_is(quoteToken, _zero) ? quoteToken : null;
}

BigInt? flapCuratedMinimumShare(
  String factory,
  List<Map<String, String>> rows,
) {
  if (_is(factory, listaLockFactory)) return BigInt.zero;
  if ([
    listaFlexFactory,
    listaStableFactory,
    listaLiquidFactory,
    _yield,
  ].any((f) => _is(factory, f)))
    return _amount(rows.single, 'minimumShareBalance', 18);
  return null;
}

bool flapVaultNeedsGasPrepayment(String factory, String quoteToken) =>
    _is(factory, flapMyxFactory) && !_is(quoteToken, _zero);

Future<BigInt> flapVaultGasDeficit(
  BackendClient api, {
  required String factory,
  required String creator,
  required String quoteToken,
}) async {
  if (!flapVaultNeedsGasPrepayment(factory, quoteToken)) return BigInt.zero;
  if (!isAddress(creator) || _is(creator, _zero))
    throw const FormatException('请先填写有效的 Dev 钱包');
  final config = AbiFunction.parse(
    'config() returns (address,address,address,uint16,uint256,uint256)',
  );
  final credit = AbiFunction.parse('prepaidGas(address) returns (uint256)');
  final result = await Future.wait([
    api.call(factory, bytesToHex(config.encode([]))),
    api.call(factory, bytesToHex(credit.encode([creator]))),
  ]);
  final needed = config.decodeOutput(result[0])[4] as BigInt;
  final existing = credit.decodeOutput(result[1]).single as BigInt;
  return needed > existing ? needed - existing : BigInt.zero;
}

/// Rechecked by the execution path, not only by the form. Custom-standard
/// selections use their live policies and never inherit a curated override.
void validateFlapCuratedLaunch(
  FlapVaultSelection selection,
  FlapVaultLaunchContext context, {
  required String quoteSymbol,
}) {
  if (context.tokenVersion == 7) {
    if (!isFlapV7GiftFactory(selection.factory) ||
        !_is(context.quoteToken, _zero)) {
      throw const FormatException('Flap V7 金库仅支持 BNB 底池与指定的礼物金库');
    }
    if (context.vaultBps != 10000 ||
        context.migratorType != 3 ||
        context.buyTaxBps != 0 ||
        context.sellTaxBps != 0 ||
        context.burnBps != 0 ||
        context.dividendBps != 0 ||
        context.liquidityBps != 0 ||
        context.minimumShare != BigInt.zero ||
        !_is(context.dividendToken, _zero)) {
      throw const FormatException('Flap V7 金库必须接收 100% 的 LP 手续费收益');
    }
    selection.encode();
    return;
  }
  if (selection is! CuratedFlapVaultSelection) return;
  final factory = selection.factory;
  selection.encode();
  if (context.tokenVersion != 6) throw const FormatException('所选精选金库仅支持当前税币发行');
  if (context.vaultBps <= 0) throw const FormatException('金库收益比例必须大于 0');
  final noDividend = [
    listaFlexFactory,
    listaStableFactory,
    listaLiquidFactory,
    listaLockFactory,
    _index,
    _reserve,
    _yield,
    flapMyxFactory,
    '0x89a800a8fbB3538f8Ddb76C95034D23c249bF9D9',
  ];
  if (noDividend.any((f) => _is(factory, f)) && context.dividendBps != 0)
    throw const FormatException('此金库自行发放收益，请将直接分红比例设为 0');
  final fullVault = [
    listaFlexFactory,
    _index,
    flapMyxFactory,
    '0x89a800a8fbB3538f8Ddb76C95034D23c249bF9D9',
  ];
  if (fullVault.any((f) => _is(factory, f)) &&
      (context.vaultBps != 10000 ||
          context.burnBps != 0 ||
          context.dividendBps != 0 ||
          context.liquidityBps != 0))
    throw const FormatException('此金库要求金库收益 100%，其余税收分配为 0');
  final dividend = selection.dividendToken;
  if (dividend != null && !_is(context.dividendToken, dividend))
    throw const FormatException('分红币与所选金库配置不一致，请重新确认金库');
  final minimum = selection.minimumShare;
  if (minimum != null && context.minimumShare != minimum)
    throw const FormatException('收益最低持仓与金库配置不一致，请重新确认金库');
  if (_is(factory, _nftRwa)) {
    if (_is(context.quoteToken, _zero) ||
        [
          'BTCB',
          'SOL',
          'USDT',
          'USD1',
          'U',
        ].contains(quoteSymbol.toUpperCase()))
      throw const FormatException('资产经纪人金库不支持当前底池代币');
  }
  if (_is(factory, _yield) &&
      !_is(context.quoteToken, '0x02fca66c1d1afb4e2a7884261eb00f63598a7436'))
    throw const FormatException('股票生息金库要求 NVDAB 底池');
  if (_is(factory, flapMyxFactory) &&
      (context.buyTaxBps < 100 ||
          context.buyTaxBps > 1000 ||
          context.sellTaxBps < 100 ||
          context.sellTaxBps > 1000))
    throw const FormatException('MYX 金库的买卖税均须为 1%–10%');
}

class FlapVaultAsset {
  const FlapVaultAsset(this.address, this.name);
  final String address;
  final String name;
}

/// The Index asset list is published by the Factory, never scraped from labels.
Future<List<FlapVaultAsset>> readFlapIndexAssets(BackendClient api) async {
  final fn = AbiFunction.parse(
    'getSupportedAssetsWithNames() returns (address[],string[])',
  );
  final data = fn.decodeOutput(
    await api.call(_index, bytesToHex(fn.encode([]))),
  );
  final addresses = data[0] as List;
  final names = data[1] as List;
  if (addresses.length != names.length || addresses.length > 256)
    throw const FormatException('金库格式有误');
  return [
    for (var i = 0; i < addresses.length; i++)
      FlapVaultAsset('${addresses[i]}', '${names[i]}'),
  ];
}

Future<List<Object?>> _read(
  BackendClient api,
  String factory,
  String signature,
  List<Object?> args,
) async {
  final fn = AbiFunction.parse(signature);
  return fn.decodeOutput(await api.call(factory, bytesToHex(fn.encode(args))));
}

/// Only public reads. A complete creation simulation remains the final gate.
/// Independent reads are concurrent; input sizes are bounded before RPC calls.
Future<void> validateFlapCuratedReadiness(
  BackendClient api,
  FlapVaultSelection selection,
  FlapVaultLaunchContext context,
) async {
  if (selection is! CuratedFlapVaultSelection) return;
  selection.encode();
  final factory = selection.factory;
  if (_is(factory, _index)) {
    final results = await Future.wait<Object>([
      readFlapIndexAssets(api),
      _read(api, factory, 'MAX_SYMBOL_LENGTH() returns (uint256)', []),
    ]);
    final assets = (results[0] as List<FlapVaultAsset>)
        .map((a) => a.address.toLowerCase())
        .toSet();
    final selected = _addresses(
      selection.rows.single['selectedAssets'] ?? '',
      max: 10,
    );
    if (selected.any((a) => !assets.contains(a.toLowerCase())))
      throw const FormatException('资产篮子包含金库不支持的资产');
    final max = ((results[1] as List).single as BigInt).toInt();
    if (max < 1 ||
        max > 1024 ||
        utf8.encode(selection.rows.single['symbol']!.trim()).length > max)
      throw FormatException('资产篮子简写不能超过 $max 字节');
  }
  if (_is(factory, _reserve)) {
    final config =
        (await _read(
              api,
              factory,
              'factoryConfig() returns ((address,address,address,address,address,address,bool,uint256,uint256))',
              [],
            )).single
            as List;
    final registry = '${config[0]}', viewHelper = '${config[1]}';
    final maxAssets = config[7] as BigInt, maxTokens = config[8] as BigInt;
    final addresses = selection.rows
        .map((r) => r['selectedAsset']!)
        .where((a) => !_is(a, '0x0000000000000000000000000000000000000001'))
        .toList();
    if (BigInt.from(addresses.length) > maxAssets)
      throw const FormatException('储备资产数量超过当前金库上限');
    final kinds = await Future.wait(
      addresses.map((address) async {
        final asset =
            (await _read(
                  api,
                  registry,
                  'getAsset(address) returns ((address,address,uint8,uint8,bool,uint8,uint8,uint256,address,uint256,uint256,address,address,address,address,address,uint8))',
                  [address],
                )).single
                as List;
        if (asset[4] == true && _is('${asset[0]}', address))
          return (asset[2] as BigInt).toInt();
        final token =
            (await _read(
                  api,
                  viewHelper,
                  'getTokenV8Safe(address) returns ((uint8,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,address))',
                  [address],
                )).single
                as List;
        final status = (token[0] as BigInt).toInt(),
            version = (token[4] as BigInt).toInt();
        if (![1, 4].contains(status) ||
            version > 7 ||
            !_is('${token[9]}', _zero))
          throw const FormatException('储备资产未启用，或不属于可用的 BNB 底池 Flap 代币');
        return 1;
      }),
    );
    if (BigInt.from(kinds.where((k) => k != 0).length) > maxTokens)
      throw const FormatException('储备中的普通代币数量超过当前金库上限');
  }
  if (flapVaultNeedsGasPrepayment(factory, context.quoteToken)) {
    final config = await _read(
      api,
      factory,
      'config() returns (address,address,address,uint16,uint256,uint256)',
      [],
    );
    if (_amount(selection.rows.single, 'gasRefillAmount', 18) >
        (config[5] as BigInt))
      throw const FormatException('Gas 补充目标超过 MYX 金库上限');
  }
}

// Nonempty on-chain schemas which the dedicated semantics below were verified against.
const _curatedShapes = <String, List<(String, String, int)>>{
  "0x6909ad1822ece349cddab98e6f62eeed9faa2e10": [("xHandle", "string", 0)],
  "0x5e8604a69158fa583b0c5c16441a9b3d429e7cbb": [("xHandle", "string", 0)],
  "0x4a42c8a67ce45cf449e0d2ff24b9a5ceacb74b69": [
    ("NFTName", "string", 0),
    ("NFTSymbol", "string", 0),
    ("maxNFTSupply", "uint256", 0),
    ("initialFloorNFTs", "uint256", 0),
    ("tokenCostPerNFT", "uint256", 18),
    ("dividendSharePercent", "uint16", 0),
    ("floorSharePercent", "uint16", 0),
    ("artSource", "string", 0),
  ],
  "0x9f5bf8eb9c4ca7179e60d0b529f4910b9a7ee0ee": [
    ("minBurnAmount", "uint256", 18),
  ],
  "0x7c8781b21fb004308a5a2bb7f9cb1e2e6bd1fc7e": [
    ("decisionCooldown / 决策冷却时间", "uint16", 0),
  ],
  "0x5418f7e8ff90354db0ecd48c8b710219244eb3c5": [
    ("selectedAssets", "address[]", 0),
    ("symbol", "string", 0),
    ("instantDividend", "bool", 0),
  ],
  "0x08e41a61c5d25420e3cb314bc513ec99b2841003": [
    ("selectedAsset", "address", 0),
  ],
  "0xfb12e8b393007bb8d925ed1c4d3eeb4854b51fa6": [
    ("minimumShareBalance", "uint256", 18),
    ("marketingWallet", "address", 0),
    ("marketingSharePercent", "uint16", 0),
  ],
  "0xeaeea9c17a5376497c44fe2a5f9c63fe3b23bf87": [
    ("marketQuoteToken", "address", 0),
    ("minProcessAmount", "uint256", 0),
    ("gasThreshold", "uint256", 18),
    ("gasRefillAmount", "uint256", 18),
    ("maxProcessAmount", "uint256", 0),
  ],
  "0x89a800a8fbb3538f8ddb76c95034d23c249bf9d9": [
    ("characterCid", "string", 0),
    ("openingPrompt", "string", 0),
  ],
  "0x357c50d241df58dc730afc1e2bf40b001768f3e0": [
    ("rewardAt50Usd", "uint256", 18),
    ("rewardAt200Usd", "uint256", 18),
    ("rewardAt500Usd", "uint256", 18),
    ("rewardAt1000Usd", "uint256", 18),
    ("rewardAt10000Usd", "uint256", 18),
    ("intervalHours", "uint8", 0),
    ("minimumHolding", "uint256", 18),
  ],
  "0xc6a0fd000988317f50215edd4098ed3368f52250": [
    ("buybackMode", "uint256", 0),
    ("triggerMode", "uint256", 0),
    ("startDelayMinutes", "uint256", 0),
    ("buybackIntervalMinutes", "uint256", 0),
    ("triggerAmount", "uint256", 18),
    ("buybackAmount", "uint256", 18),
  ],
  "0xcf83c4577d4c2e2a6ba48c0926046938802b74e6": [
    ("maxUserBnbOutPerSell", "uint256", 18),
  ],
  "0xf68ee35a4fde7a7c3e4baf01dac019b4a90fa1db": [
    ("minStakeForReward", "uint256", 18),
  ],
  "0xf3056daa77db106f25ba8c32ee78e5d40777fbaf": [
    ("winnersCount", "uint256", 0),
    ("minPrizePool", "uint256", 18),
  ],
  "0xfce2509d232fb62dc15c9bf2fade69653e480a25": [
    ("decisionCooldown", "uint256", 0),
  ],
  "0x88a33780e1b3150af85fbef52f344a43ebec5a51": [
    ("NFTName", "string", 0),
    ("NFTSymbol", "string", 0),
    ("maxNFTSupply", "uint256", 0),
    ("initialFloorNFTs", "uint256", 0),
    ("tokenCostPerNFT", "uint256", 18),
    ("dividendSharePercent", "uint16", 0),
    ("floorSharePercent", "uint16", 0),
    ("artSource", "string", 0),
  ],
  "0x71cab5a1a8904b358c24032bb653f764efa03f14": [
    ("claimUsdE18", "uint256", 18),
    ("minTaxBalance", "uint256", 18),
  ],
  "0x845c25cee4f046663756d1245739e260ca70074c": [
    ("minimumShareBalance", "uint256", 18),
  ],
  "0x4c126de52d91ef2b5b29305733dd4d81f5ab8b05": [
    ("minimumShareBalance", "uint256", 18),
  ],
  "0xc7c58c0b8e884b0f8cdbe918f3ab84881b59bcab": [
    ("lockDays1", "uint16", 0),
    ("lockWeightBps1", "uint16", 0),
    ("minStakeAmount1", "uint256", 18),
    ("lockDays2", "uint16", 0),
    ("lockWeightBps2", "uint16", 0),
    ("minStakeAmount2", "uint256", 18),
    ("lockDays3", "uint16", 0),
    ("lockWeightBps3", "uint16", 0),
    ("minStakeAmount3", "uint256", 18),
    ("lockDays4", "uint16", 0),
    ("lockWeightBps4", "uint16", 0),
    ("minStakeAmount4", "uint256", 18),
  ],
};

void _checkCuratedShape(FlapVaultInfo info) {
  final fields = _curatedShapes[info.factory.toLowerCase()];
  if (fields == null) return;
  if (fields.length != info.schema.fields.length)
    throw const FormatException('金库格式有误');
  for (var i = 0; i < fields.length; i++) {
    final expected = fields[i], actual = info.schema.fields[i];
    if (expected.$1 != actual.name ||
        expected.$2 != actual.type ||
        expected.$3 != actual.decimals)
      throw const FormatException('金库格式有误');
  }
  if (info.schema.isArray != _is(info.factory, _reserve))
    throw const FormatException('金库格式有误');
}
