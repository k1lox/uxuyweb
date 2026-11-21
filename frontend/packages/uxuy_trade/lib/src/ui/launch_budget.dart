import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/backend_client.dart';
import '../evm/abi.dart';
import '../evm/evm.dart';
import '../wallet/wallet.dart';
import 'widgets.dart';

typedef LaunchTarget = ({BigInt amount, int decimals, String symbol});

/// Amounts stay in the editor's denomination. Only public amounts enter previews.
List<String> launchInnerAmounts(String dev, String rows, String defaultAmount) {
  final seen = <String>{};
  return [
    dev.trim().isEmpty ? '0' : dev.trim(),
    for (final line in const LineSplitter().convert(ordinaryWalletInput(rows)))
      if (line.trim().isNotEmpty)
        for (final row in [parseWalletKeyLine(line, allowAmount: true)])
          if (seen.add(row.key.toLowerCase().replaceFirst(RegExp(r'^0x'), '')))
            row.amount ?? defaultAmount,
  ];
}

BigInt _sum(List<String> amounts, int decimals) {
  final total = amounts.fold(
    BigInt.zero,
    (n, value) => n + parseUnits(value, decimals),
  );
  return total;
}

String _fmt(BigInt amount, int decimals) =>
    formatUnits(amount, decimals, maxFraction: decimals);
// Keep base units exact. Round only the short label and expose the full amount in its tooltip.
String _budgetValue(BigInt value, int decimals, {required bool compact}) {
  final places = value.toString().length - decimals;
  var scale = 0;
  var suffix = '';
  if (compact && places > 12) {
    scale = places - 1;
    suffix = '×10^$scale';
  } else if (compact && places > 8) {
    scale = 8;
    suffix = '亿';
  } else if (compact && places > 6) {
    scale = 4;
    suffix = '万';
  }
  final digits = decimals + scale;
  final precision = compact ? (places >= 2 ? 2 : 3) : 6;
  if (digits <= precision) return '${_fmt(value, digits)}$suffix';
  final step = BigInt.from(10).pow(digits - precision);
  if (value > BigInt.zero && value < step) {
    return '< ${_fmt(BigInt.one, precision)}$suffix';
  }
  final rounded = (value + step ~/ BigInt.two) ~/ step;
  final prefix = value.remainder(step) == BigInt.zero ? '' : '≈';
  return '$prefix${_fmt(rounded, precision)}$suffix';
}

String _message(Object error) =>
    error is BackendException ? error.userMessage : error.toString();

/// Read-only preview of an existing pool asset, independent of the launch simulation.
typedef PoolPreview = ({
  String summary,
  List<String> pools,
  BigInt bought,
  int decimals,
  String symbol,
});
const _previewAddress = '0x0000000000000000000000000000000000000001';

Future<TokenMeta> launchPaymentMeta(BackendClient api, String address) async {
  final meta = await api.token(address);
  final decimals = meta.decimals;
  if (meta.address.toLowerCase() != address.toLowerCase() ||
      meta.symbol.trim().isEmpty ||
      decimals == null ||
      decimals < 0 ||
      decimals > 36) {
    throw StateError('底池币地址、名称或精度无法确认');
  }
  return meta;
}

Future<PoolPreview> readLaunchLiquidity(
  BackendClient api,
  String quote,
  BigInt bnb,
  String? dev,
) async {
  final wallet = dev ?? _previewAddress;
  final config = await api.config();
  config.requireUxuySwap();
  if (bnb <= BigInt.zero ||
      !config.maxImpact.isFinite ||
      config.maxImpact < 0 ||
      config.maxImpact > 100) {
    throw StateError('底池币预估金额或价格冲击上限无效');
  }
  final token = await launchPaymentMeta(api, quote);
  final decimals = token.decimals!;
  Future<RoutePlan> forecast(bool buy, BigInt amount) async {
    final request = RouteRequestData(
      buy: buy,
      token: quote,
      wallet: wallet,
      amount: amount,
      forecastOnly: true,
      maxImpactPercent: config.maxImpact,
    );
    final p = await api.route(request);
    if (p.chainId != bscChainId ||
        p.quoteScope != 'wallet' ||
        p.token?.toLowerCase() != quote.toLowerCase() ||
        p.settlementToken != null ||
        p.buy != buy ||
        p.amount != amount ||
        p.value != (buy ? amount : BigInt.zero) ||
        p.wallet.toLowerCase() != wallet.toLowerCase() ||
        p.to.toLowerCase() != config.router.toLowerCase() ||
        p.spender.toLowerCase() != config.approvalSpender?.toLowerCase() ||
        p.simulation != 'forecast' ||
        p.data != '0x' ||
        p.executed ||
        p.deadline <= DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
        p.minOut <= BigInt.zero ||
        p.minOut > p.quoteOut ||
        p.slippagePpm < 0 ||
        p.slippagePpm > request.slippageBps * 100 ||
        p.minOut <
            p.quoteOut *
                BigInt.from(1000000 - p.slippagePpm) ~/
                BigInt.from(1000000) ||
        !p.priceImpact.isFinite ||
        p.priceImpact < 0 ||
        p.priceImpact > config.maxImpact)
      throw uxuyRouteFailed;
    return p;
  }

  final buy = await forecast(true, bnb);
  final summary = [
    '${_fmt(bnb, 18)} BNB → ${_fmt(buy.quoteOut, decimals)} ${token.symbol} · 冲击 ${buy.priceImpact.toStringAsFixed(2)}%',
  ];
  final routes = [buy];
  try {
    final sell = await forecast(false, buy.quoteOut);
    routes.add(sell);
    summary.add(
      '反向预估 ${_fmt(sell.quoteOut, 18)} BNB · 冲击 ${sell.priceImpact.toStringAsFixed(2)}%',
    );
  } on Object catch (e) {
    summary.add('反向报价：${_message(e)}');
  }
  final venues = routes.expand((p) => p.dexes).toSet();
  if (venues.isNotEmpty) summary.add(venues.join(' / '));
  final addresses = routes
      .expand((p) => p.pools)
      .map((s) => s.toLowerCase())
      .toSet();
  final pools = <String>[];
  if (addresses.isNotEmpty) {
    try {
      final block = (await api.rpc([('eth_blockNumber', [])])).single as String;
      if (!RegExp(r'^0x[0-9a-fA-F]+$').hasMatch(block))
        throw StateError('区块无效');
      final depths = await Future.wait(
        addresses.map((a) => _depth(api, a, block)),
      );
      pools.add('区块 ${BigInt.parse(block)}');
      pools.addAll(depths);
    } on Object {
      pools.add('池余额暂时无法读取');
    }
  } else {
    pools.add('报价没有提供可读取的池地址');
  }
  return (
    summary: summary.join('\n'),
    pools: pools,
    bought: buy.quoteOut,
    decimals: decimals,
    symbol: token.symbol,
  );
}

Future<String> _depth(BackendClient api, String pool, String block) async {
  Future<List<Object?>> read(
    String to,
    String def, [
    List<Object?> args = const [],
  ]) async {
    final fn = AbiFunction.parse(def);
    return fn.decodeOutput(
      await api.call(to, bytesToHex(fn.encode(args)), block: block),
    );
  }

  try {
    final tokens = await Future.wait(
      ['token0', 'token1'].map(
        (name) async =>
            (await read(pool, '$name() returns (address)')).single as String,
      ),
    );
    if (tokens[0].toLowerCase() == tokens[1].toLowerCase())
      throw StateError('交易对异常');
    late List<BigInt> amounts;
    String label;
    try {
      final v2 = await read(
        pool,
        'getReserves() returns (uint112,uint112,uint32)',
      );
      amounts = [v2[0] as BigInt, v2[1] as BigInt];
      label = '储备';
    } on Object {
      await read(pool, 'liquidity() returns (uint128)');
      amounts = await Future.wait(
        tokens.map(
          (a) async =>
              (await read(a, 'balanceOf(address) returns (uint256)', [
                    pool,
                  ])).single
                  as BigInt,
        ),
      );
      label = '池内余额';
    }
    final units = await Future.wait(
      tokens.indexed.map((entry) async {
        final (i, address) = entry;
        final values = await Future.wait([
          read(address, 'decimals() returns (uint8)'),
          read(address, 'symbol() returns (string)'),
        ]);
        final decimals = (values.first.single as BigInt).toInt();
        if (decimals > 36) throw StateError('精度未知');
        return '${_fmt(amounts[i], decimals)} ${values.last.single}';
      }),
    );
    return '$pool\n$label ${units.join(' / ')}';
  } on Object {
    return '$pool · 无法核实独立池余额';
  }
}

class LaunchDevBalance extends StatelessWidget {
  const LaunchDevBalance({
    super.key,
    required this.api,
    required this.address,
    required this.paymentToken,
  });

  final BackendClient api;
  final String address;
  final String? paymentToken;

  Future<String> _read() async {
    final token = paymentToken;
    final rows = await api.transferPreviewStates([address], token: token);
    if (rows.length != 1 ||
        rows.single.wallet.toLowerCase() != address.toLowerCase() ||
        rows.single.native.isNegative) {
      throw StateError('未能核实 Dev 钱包余额');
    }
    final wallet = rows.single;
    final bnb = '${_fmt(wallet.native, 18)} BNB';
    if (token == null) return bnb;
    final meta = await launchPaymentMeta(api, token);
    final balance = wallet.tokenBalance;
    if (balance == null || balance.isNegative) {
      throw StateError('未能核实付款币余额');
    }
    return '${_fmt(balance, meta.decimals!)} ${meta.symbol} · $bnb';
  }

  @override
  Widget build(BuildContext context) => _Preview<String>(
    selection: (api, address.toLowerCase(), paymentToken?.toLowerCase()),
    read: _read,
    render: (balance, error, refresh) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            balance != null
                ? 'Dev 余额  $balance'
                : error != null
                ? 'Dev 余额读取失败 · ${_message(error)}'
                : '正在读取 Dev 余额…',
            style: muted,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '刷新 Dev 余额',
          onPressed: refresh,
          icon: const Icon(Icons.refresh, size: 16),
          style: IconButton.styleFrom(
            foregroundColor: UiStyle.muted,
            minimumSize: const Size(32, 32),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    ),
  );
}

class LaunchBudgetPanel extends StatelessWidget {
  const LaunchBudgetPanel({
    super.key,
    required this.api,
    required this.selection,
    required this.readTarget,
    required this.amounts,
    required this.payBnb,
    required this.unit,
    required this.pool,
    required this.dev,
    required this.paymentDecimals,
  });
  final BackendClient api;
  final Object selection;
  final Future<LaunchTarget> Function() readTarget;
  final List<String>? amounts;
  final bool payBnb;
  final String unit;
  final String? pool, dev;
  final int? paymentDecimals;

  @override
  Widget build(BuildContext context) {
    BigInt? planned(int decimals) {
      try {
        return amounts == null ? null : _sum(amounts!, decimals);
      } on FormatException {
        return null;
      }
    }

    final nativeAmount = payBnb ? planned(18) : null;
    final probe = nativeAmount != null && nativeAmount > BigInt.zero
        ? nativeAmount
        : BigInt.from(10).pow(18);
    Widget figure(
      String caption,
      String description,
      BigInt value,
      int digits,
      String symbol, {
      required bool showUnit,
      required bool compact,
      bool emphasized = false,
    }) {
      final exact = _fmt(value, digits);
      final display = _budgetValue(value, digits, compact: compact);
      final full = '$description $exact $symbol';
      return Tooltip(
        message: full,
        excludeFromSemantics: true,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$caption ', style: label),
              TextSpan(
                text: showUnit ? '$display $symbol' : display,
                style: emphasized ? strong : Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          semanticsLabel: full,
        ),
      );
    }

    return _Preview<LaunchTarget>(
      selection: selection,
      read: readTarget,
      render: (result, error, refresh) {
        final decimals = payBnb
            ? 18
            : result?.decimals ?? paymentDecimals ?? 36;
        final total = planned(decimals);
        final sameAsset = !payBnb || pool == null;
        final gap = result != null && total != null && sameAsset
            ? result.amount - total
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 12, thickness: .7),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 520;
                return Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: compact ? 6 : 12,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('开外盘预算', style: strong),
                          if (total != null)
                            figure(
                              '首买',
                              '计划内盘首买',
                              total,
                              decimals,
                              sameAsset ? result?.symbol ?? unit : unit,
                              compact: compact,
                              showUnit: result == null || !sameAsset,
                            )
                          else
                            const Text('首买金额待补全', style: muted),
                          if (result != null)
                            figure(
                              '目标',
                              '迁移目标',
                              result.amount,
                              result.decimals,
                              result.symbol,
                              compact: compact,
                              showUnit: gap == null || gap <= BigInt.zero,
                            )
                          else
                            Text(
                              error == null ? '正在读取目标…' : '目标读取失败',
                              style: muted,
                            ),
                          if (gap != null && gap > BigInt.zero)
                            figure(
                              '还差',
                              '距迁移目标还差',
                              gap,
                              result!.decimals,
                              result.symbol,
                              compact: compact,
                              showUnit: true,
                              emphasized: true,
                            )
                          else if (gap != null)
                            const Text('已达标', style: strong),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新内盘预算',
                      onPressed: refresh,
                      icon: const Icon(Icons.refresh, size: 17),
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 36,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.standard,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                );
              },
            ),
            if (error != null) Text(_message(error), style: muted),
            if (pool != null && isAddress(pool!))
              Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  expandedAlignment: Alignment.centerLeft,
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('BNB 与底池币兑换预览'),
                  children: [
                    _Preview<PoolPreview>(
                      selection: (pool!.toLowerCase(), probe, dev),
                      read: () => readLaunchLiquidity(api, pool!, probe, dev),
                      retryLabel: '刷新兑换报价',
                      render: (r, e, _) {
                        if (r == null)
                          return Text(
                            e == null ? '正在读取 UXUY 市场报价…' : _message(e),
                            style: muted,
                          );
                        final lines = [
                          r.summary,
                          if (nativeAmount != null &&
                              nativeAmount > BigInt.zero &&
                              result != null &&
                              r.decimals == result.decimals)
                            if (r.bought < result.amount)
                              '按市场预估距目标 ${_fmt(result.amount - r.bought, r.decimals)} ${r.symbol}'
                            else
                              '按市场预估达到目标',
                          ...r.pools.expand((line) => line.split('\n')),
                        ];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final line in lines)
                              SelectableText(line, style: muted),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Preview<T> extends StatefulWidget {
  const _Preview({
    required this.selection,
    required this.read,
    required this.render,
    this.retryLabel,
  });
  final Object selection;
  final Future<T> Function() read;
  final Widget Function(T?, Object?, VoidCallback?) render;
  final String? retryLabel;
  @override
  State<_Preview<T>> createState() => _PreviewState<T>();
}

class _PreviewState<T> extends State<_Preview<T>> {
  T? result;
  Object? error;
  Timer? debounce;
  int sequence = 0;
  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(_Preview<T> old) {
    super.didUpdateWidget(old);
    if (old.selection != widget.selection) schedule();
  }

  void schedule() {
    debounce?.cancel();
    final generation = ++sequence;
    result = null;
    error = null;
    debounce = Timer(const Duration(milliseconds: 350), () async {
      T? value;
      Object? failure;
      try {
        value = await widget.read();
      } on Object catch (e) {
        failure = e;
      }
      if (mounted && sequence == generation)
        setState(() {
          result = value;
          error = failure;
        });
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final refresh = result == null && error == null
        ? null
        : () => setState(schedule);
    final content = widget.render(result, error, refresh);
    if (widget.retryLabel == null || refresh == null) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        SmallButton(label: widget.retryLabel!, onPressed: refresh),
      ],
    );
  }
}
