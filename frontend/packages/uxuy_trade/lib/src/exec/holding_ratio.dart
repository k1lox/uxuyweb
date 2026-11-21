import 'dart:convert';
import 'dart:math' as math;

import '../api/backend_client.dart';
import '../evm/abi.dart';
import '../evm/evm.dart';
import 'genius_configurable.dart' show geniusM52Factory;

const _zero = '0x0000000000000000000000000000000000000000';
const _aggregateAddress = '0xca11bde05977b3631167028862be2a173976ca11';
const _four = '0x5c952063c7fc8610ffdb798152d69f0b9550762b';
const _flap = '0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0';
const _infinity = '0xa0ffb9c1ce1fe56963b0321b32e7a0302114058b';
const _v4 = '0x28e2ea090877bf75740558f6bfb36a5ffee9e9df';
const _genius = {
  '0x78eae9537c0ef90dfe9b7ae964682fe8138afe31': 'Genius V1',
  '0x37ee8aee29c5efd3c1a7eda6df3f510779928a37': 'Genius V2',
  geniusM52Factory: 'Genius m5.2',
};
const _factories = <String, (String, List<int>)>{
  '0xca143ce32fe78f1f7019d7d551a6402fc5350c73': ('Pancake V2', []),
  '0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865': (
    'Pancake V3',
    [100, 500, 2500, 10000],
  ),
  '0x8909dc15e40173ff4699343b6eb8132c65e18ec6': ('Uniswap V2', []),
  '0xdb1d10011ad0ff90774d0c6bb92e5c5c8b4461f7': (
    'Uniswap V3',
    [100, 500, 3000, 10000],
  ),
};
final _aggregate = AbiFunction.parse(
  'aggregate3((address,bool,bytes)[]) returns ((bool,bytes)[])',
);
final _abis = <String, AbiFunction>{};
typedef _Call = (String, String, List<Object?>);
typedef HoldingRow = ({String address, BigInt balance, String label});

List<String> holdingAddresses(String text, {int maximum = 10000}) {
  final addresses = <String>{};
  for (final part
      in text.trim().split(RegExp(r'[\s,，;；]+')).where((e) => e.isNotEmpty)) {
    if (!isAddress(part) || part.toLowerCase() == _zero)
      throw const FormatException('请输入有效的非零公开地址');
    final check = checksumAddress(part);
    final hex = part.substring(2);
    if (hex != hex.toLowerCase() && hex != hex.toUpperCase() && check != part)
      throw const FormatException('地址校验和错误');
    addresses.add(check.toLowerCase());
    if (addresses.length > maximum) throw FormatException('最多支持 $maximum 个地址');
  }
  return addresses.toList();
}

class HoldingSnapshot {
  HoldingSnapshot(
    this.block,
    this.token,
    this.symbol,
    this.decimals,
    this.totalSupply,
    this.pools,
    this.wallets,
    this.warnings,
    this.reason,
  );
  final int block, decimals;
  final String token, symbol;
  final BigInt totalSupply;
  final List<HoldingRow> pools, wallets;
  final List<String> warnings;
  final String? reason;
  BigInt get poolBalance => pools.fold(BigInt.zero, (n, r) => n + r.balance);
  BigInt get circulating => totalSupply - poolBalance;
  BigInt get held => wallets
      .where((r) => r.label.isEmpty)
      .fold(BigInt.zero, (n, r) => n + r.balance);
  String? get percent {
    if (reason != null || circulating <= BigInt.zero) return null;
    final v = held * BigInt.from(1000000) ~/ circulating;
    return v == BigInt.zero && held > BigInt.zero
        ? '<0.0001%'
        : '${formatUnits(v, 4, maxFraction: 4)}%';
  }
}

class _PinnedRead {
  _PinnedRead(this.api, this.block);
  final BackendClient api;
  final String block;
  final _cache = <(String, String), Object?>{};
  Future<List<Object?>> read(List<_Call> calls) async {
    final keys = <(String, String)>[];
    final missing = <(String, String), AbiFunction>{};
    for (final (target, signature, args) in calls) {
      final abi = _abis.putIfAbsent(
        signature,
        () => AbiFunction.parse(signature),
      );
      final key = (target.toLowerCase(), abi.encodeHex(args));
      keys.add(key);
      if (!_cache.containsKey(key)) missing[key] = abi;
    }
    final entries = missing.entries.toList();
    for (var i = 0; i < entries.length; i += 400) {
      final part = entries.sublist(i, math.min(i + 400, entries.length));
      final data = _aggregate.encodeHex([
        [
          for (final e in part) [e.key.$1, true, e.key.$2],
        ],
      ]);
      final raw = (await api.rpc([
        (
          'eth_call',
          [
            {'to': _aggregateAddress, 'data': data},
            block,
          ],
        ),
      ])).single;
      final rows = _aggregate.decodeOutput(raw!).single as List;
      if (rows.length != part.length) throw StateError('控盘率链上读取不完整');
      for (var j = 0; j < rows.length; j++) {
        final entry = part[j], row = rows[j] as List;
        Object? value;
        if (row[0] == true) {
          try {
            final values = entry.value.decodeOutput(row[1]);
            value = values.length == 1 ? values.first : values;
          } catch (_) {
            if (entry.value.name == 'symbol') {
              final bytes = row[1] as List<int>;
              if (bytes.length == 32)
                value = utf8.decode(
                  bytes.takeWhile((n) => n != 0).toList(),
                  allowMalformed: true,
                );
            }
          }
        }
        _cache[entry.key] = value;
      }
    }
    return [for (final key in keys) _cache[key]];
  }
}

const _balance = 'balanceOf(address) returns (uint256)';
const _pair = 'getPair(address,address) returns (address)';
const _pool = 'getPool(address,address,uint24) returns (address)';
const _record =
    'getLaunchedToken(address) returns ((address,address,address,address,address,uint256,uint24,int24,uint16,bool,uint8,uint256,uint256,uint256,bool))';
const _flapInfo =
    'getTokenV8Safe(address) returns ((uint8,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,address,bool,bytes32,uint256,uint256,address,uint256,uint8,uint8))';
const _fourInfo =
    '_tokenInfos(address) returns (address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)';
String? _address(Object? value) =>
    value is String && isAddress(value) && value.toLowerCase() != _zero
    ? value.toLowerCase()
    : null;

Future<HoldingSnapshot> readHoldingRatio(
  BackendClient api,
  String contract,
  String owners,
  String manualPools,
) async {
  final targets = holdingAddresses(contract, maximum: 1);
  final wallets = holdingAddresses(owners);
  if (targets.length != 1 || wallets.isEmpty)
    throw const FormatException('请输入代币合约地址和地址组');
  final token = targets.single,
      manual = holdingAddresses(manualPools, maximum: 128).toSet();
  if (manual.contains(token)) throw const FormatException('代币合约自身不能作为流动性池');
  final block = (await api.rpc([('eth_blockNumber', [])])).single;
  if (block is! String || !RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(block))
    throw StateError('未取得查询区块');
  final chain = _PinnedRead(api, block);
  final probes = await chain.read([
    (token, 'mainPool() returns (address)', []),
    (token, 'pair() returns (address)', []),
    (_flap, _flapInfo, [token]),
    (_four, _fourInfo, [token]),
    (_infinity, 'vault() returns (address)', []),
    (token, 'totalSupply() returns (uint256)', []),
    (token, 'decimals() returns (uint8)', []),
    (token, 'symbol() returns (string)', []),
    for (final factory in _genius.keys) (factory, _record, [token]),
  ]);
  final [mainPool, pair, flap, four, vault, supply, decimals, symbol, ...registrations] = probes;
  if (supply is! BigInt || decimals is! BigInt || decimals > BigInt.from(36))
    throw StateError('无法确认代币供应量或精度');
  final candidates = {
    ...manual,
    for (final raw in [mainPool, pair]) ?_address(raw),
  };
  final bases = {
    '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c',
    '0x55d398326f99059ff775485246999027b3197955',
    '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',
  };
  final curves = <String, (String, String)>{},
      verified = <String, String>{},
      warnings = <String>{};
  var v4 = false;
  String? reason;
  for (var i = 0; i < _genius.length; i++) {
    final row = registrations[i];
    if (row is! List) {
      warnings.add('部分 Genius 登记未确认');
      continue;
    }
    if (row[14] != true) continue;
    if (_address(row[0]) != token || _address(row[1]) == null)
      throw StateError('Genius 代币登记不一致');
    final base = _address(row[4]);
    if (base != null) bases.add(base);
    final phase = (row[10] as BigInt).toInt();
    if (phase == 2) {
      v4 = true;
    } else if (phase == 0 || phase == 1) {
      curves[_address(row[1])!] = (
        '${_genius.values.elementAt(i)} 内盘',
        '${row[4]}'.toLowerCase(),
      );
    } else {
      reason = '代币处于特殊迁移状态，暂无法确认库存';
    }
  }
  if (flap is! List) {
    warnings.add('Flap 平台登记未确认');
  } else if ((flap[4] as BigInt) > BigInt.zero &&
      (flap[0] as BigInt) > BigInt.zero) {
    final base = _address(flap[9]);
    if (base != null) bases.add(base);
    if (flap[0] != BigInt.from(4)) {
      reason = '共享内盘无法准确区分流动性库存';
    } else if (flap[4] == BigInt.from(7)) {
      v4 = true;
    } else {
      final pool = _address(flap[14]);
      if (pool != null) candidates.add(pool);
    }
  }
  final fourToken = four is List ? _address(four[0]) : null;
  if (four is! List) {
    warnings.add('Four 平台登记未确认');
  } else if (fourToken != null) {
    if (fourToken != token) throw StateError('Four 代币登记不一致');
    final base = _address(four[1]);
    if (base != null) bases.add(base);
  }
  final custody = {_v4, ?_address(vault)};
  if (_address(vault) == null) warnings.add('Infinity 托管地址未确认');
  final excluded = {...custody, _infinity};
  final stocks = await chain.read([
    for (final a in custody) (token, _balance, [a]),
    if (fourToken != null) (token, _balance, [_four]),
  ]);
  for (final stock in stocks.take(custody.length)) {
    if (stock == null) warnings.add('V4 托管库存读取不完整');
    if (stock is BigInt && stock > BigInt.zero) v4 = true;
  }
  if (fourToken != null && stocks.last != BigInt.zero)
    reason = stocks.last == null ? 'Four 内盘库存未能确认' : '共享内盘无法准确区分流动性库存';
  final curveList = curves.entries.toList();
  final bindings = await chain.read([
    for (final c in curveList) (c.key, 'pairToken() returns (address)', []),
  ]);
  for (var i = 0; i < curveList.length; i++) {
    final c = curveList[i];
    if ('${bindings[i]}'.toLowerCase() != c.value.$2)
      throw StateError('独立内盘底池登记不一致');
    verified[c.key] = c.value.$1;
  }
  final searches = <_Call>[];
  bases.remove(token);
  for (final factory in _factories.entries) {
    for (final base in bases) {
      final pair = [token, base]..sort();
      if (factory.value.$2.isEmpty) {
        searches.add((factory.key, _pair, pair));
      } else {
        for (final fee in factory.value.$2)
          searches.add((factory.key, _pool, [...pair, fee]));
      }
    }
  }
  final found = await chain.read(searches);
  if (found.contains(null)) warnings.add('部分工厂读取失败，自动识别可能不完整');
  candidates.addAll(found.map(_address).whereType<String>());
  if (candidates.any(excluded.contains)) v4 = true;
  candidates.removeAll({...excluded, ...curves.keys});
  final pending = candidates.toList();
  final metadata = await chain.read([
    for (final address in pending)
      for (final f in [
        'token0() returns (address)',
        'token1() returns (address)',
        'factory() returns (address)',
        'fee() returns (uint24)',
      ])
        (address, f, []),
  ]);
  final checks = <_Call>[], checked = <String>[], labels = <String>[];
  void invalid(String p) {
    if (manual.contains(p))
      throw FormatException('补充地址 ${checksumAddress(p)} 不是已核实的当前代币池');
    reason ??= '有候选流动性池未通过核验，暂不计算控盘率';
  }

  for (var i = 0; i < pending.length; i++) {
    final a = _address(metadata[i * 4]),
        b = _address(metadata[i * 4 + 1]),
        factory = _address(metadata[i * 4 + 2]),
        fee = metadata[i * 4 + 3];
    final def = _factories[factory];
    if (a == null ||
        b == null ||
        a == b ||
        (a != token && b != token) ||
        def == null ||
        (def.$2.isNotEmpty &&
            (fee is! BigInt ||
                fee <= BigInt.zero ||
                fee >= BigInt.from(1000000)))) {
      invalid(pending[i]);
      continue;
    }
    checks.add(
      def.$2.isEmpty
          ? (factory!, _pair, [a, b])
          : (factory!, _pool, [a, b, fee]),
    );
    checked.add(pending[i]);
    labels.add(def.$1);
  }
  final proofs = await chain.read(checks);
  for (var i = 0; i < checked.length; i++) {
    if (_address(proofs[i]) != checked[i]) {
      invalid(checked[i]);
    } else {
      verified[checked[i]] = labels[i];
    }
  }
  if (v4) warnings.add('已排除共享 V4/Infinity 托管地址，未从流通量扣除此类库存');
  if (verified.isEmpty && !v4) reason ??= '未识别到流动性池，请补充池地址';
  final addresses = {...verified.keys, ...wallets}.toList();
  final values = await chain.read([
    for (final a in addresses) (token, _balance, [a]),
  ]);
  if (values.any((v) => v is! BigInt)) throw StateError('持仓余额读取不完整');
  final balances = {
    for (var i = 0; i < addresses.length; i++)
      addresses[i]: values[i] as BigInt,
  };
  final result = HoldingSnapshot(
    int.parse(block.substring(2), radix: 16),
    checksumAddress(token),
    symbol is String
        ? symbol
              .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '')
              .split('')
              .take(128)
              .join()
        : 'TOKEN',
    decimals.toInt(),
    supply,
    [
      for (final e in verified.entries)
        (
          address: checksumAddress(e.key),
          balance: balances[e.key]!,
          label: e.value,
        ),
    ],
    [
      for (final a in wallets)
        (
          address: checksumAddress(a),
          balance: balances[a]!,
          label: verified.containsKey(a) || excluded.contains(a) ? '不计入持仓' : '',
        ),
    ],
    warnings.toList(),
    reason,
  );
  if (result.circulating < BigInt.zero || result.held > result.circulating)
    throw StateError('供应量与持仓余额不一致');
  return result;
}
