import '../api/backend_client.dart';
import '../evm/abi.dart';
import 'market.dart';

const _swap = '(address,address,address[],uint256,bytes)';
const _bridge = '(address,address,address,uint256,address,uint256,bytes)';
final _trade = AbiFunction.parse(
  'trade((uint256,$_swap[],$_bridge,address,address,uint256,$_swap[],uint256,uint256))',
);
final _functions = <String, AbiFunction>{};
const _invalid = BackendException(
  'BAD_INNER_ROUTE',
  '官方内盘交易与钱包、金额或底池不符，请重新检查',
  false,
);

bool _same(Object? a, String b) =>
    a.toString().toLowerCase() == b.toLowerCase();

void _require(bool allowed) {
  if (!allowed) throw _invalid;
}

void _exact(RouteLeg leg, String signature, List<Object?> args) {
  final call = _functions.putIfAbsent(
    signature,
    () => AbiFunction.parse(signature),
  );
  _require(_same(leg.data, call.encodeHex(args)));
}

void _conversion(RouteLeg leg, String router, int validUntil) {
  _require(_same(leg.to, router) && leg.data.length <= 262146);
  final args = _trade.decodeInput(leg.data);
  _require(_same(_trade.encodeHex(args), leg.data));
  final p = args.single as List, swaps = p[1] as List, bridge = p[2] as List;
  _require(
    p[0] == leg.amountIn &&
        _same(p[3], leg.recipient) &&
        _same(bridge[0], zeroAddress) &&
        _same(p[4], zeroAddress) &&
        p[5] == BigInt.zero &&
        (p[6] as List).isEmpty &&
        (p[7] == BigInt.zero || (p[7] as BigInt) >= BigInt.from(validUntil)) &&
        swaps.isNotEmpty &&
        swaps.length <= 32,
  );
  var asset = leg.tokenIn;
  for (final swap in swaps.cast<List>()) {
    final path = swap[2] as List;
    _require(
      !_same(swap[0], zeroAddress) &&
          path.length >= 2 &&
          _same(path.first, asset),
    );
    asset = path.last.toString();
  }
  _require(
    _same(asset, leg.tokenOut) && (swaps.last[3] as BigInt) >= leg.minOut,
  );
}

/// Check the signed bytes against the known launchpad ABI and the immutable wallet order.
void validateInnerRoute(
  RouteRequestData req,
  RoutePlan plan,
  ModuleConfig config, {
  required bool forecast,
}) {
  final market = req.market!, platform = market.innerPlatform;
  final target = market.innerTarget?.toLowerCase();
  final quote = market.nativeToQuoteSwapEnabled && req.settlementToken == null
      ? zeroAddress
      : market.quote.toLowerCase();
  final token = req.token.toLowerCase(), wallet = req.wallet.toLowerCase();
  final settlement = req.settlementToken?.toLowerCase() ?? zeroAddress;
  final wrapped = wbnb.toLowerCase();
  _require(
    target != null &&
        _same(market.address, token) &&
        quote != token &&
        plan.source == 'official' &&
        plan.dexes.length == 1 &&
        plan.dexes.first == platform &&
        _same(plan.spender, target) &&
        _same(plan.to, target) &&
        plan.pools.length == 1 &&
        _same(plan.pools.single, target),
  );
  final approvals = <(String, String), BigInt>{};
  for (final approval in plan.approvals) {
    final key = (approval.token, approval.spender);
    _require(
      approval.token != zeroAddress &&
          approval.amount > BigInt.zero &&
          approval.amount.bitLength < 256 &&
          !approvals.containsKey(key) &&
          (approval.spender == target &&
                  (req.buy
                      ? approval.token == quote
                      : approval.token == token &&
                            approval.amount == req.amount) ||
              !req.buy &&
                  approval.token == quote &&
                  _same(approval.spender, config.approvalSpender ?? '')),
    );
    approvals[key] = approval.amount;
  }
  if (forecast) {
    _require(plan.legs.isEmpty);
  }
  final legs = forecast ? plan.steps : plan.legs;
  _require(
    legs.isNotEmpty &&
        legs.length <= 3 &&
        legs.where((l) => l.kind == 'official').length == 1 &&
        legs.first.tokenIn == (req.buy ? zeroAddress : token) &&
        legs.first.amountIn == req.amount &&
        legs.last.tokenOut == (req.buy ? token : settlement) &&
        legs.last.minOut >= plan.minOut,
  );
  if (!forecast)
    _require(
      plan.legs.fold<int>(0, (sum, l) => sum + l.gasLimit) == plan.gasLimit,
    );
  final seen = <(String, String), BigInt>{};
  for (final (index, l) in legs.indexed) {
    _require(
      l.recipient == wallet &&
          l.tokenIn != l.tokenOut &&
          l.amountIn > BigInt.zero &&
          l.minOut > BigInt.zero,
    );
    if (l is RouteLeg)
      _require(
        l.gasLimit >= 21000 &&
            l.gasLimit <= 30000000 &&
            l.value == (l.tokenIn == zeroAddress ? l.amountIn : BigInt.zero),
      );
    if (index > 0)
      _require(
        legs[index - 1].tokenOut == l.tokenIn &&
            legs[index - 1].minOut == l.amountIn,
      );
    switch (l.kind) {
      case 'official':
        _require(
          l.to == target &&
              l.tokenIn == (req.buy ? quote : token) &&
              l.tokenOut == (req.buy ? token : quote),
        );
        if (l is! RouteLeg) break;
        _require(_same(l.data, plan.data));
        switch (platform) {
          case 'four':
            if (req.buy) {
              _exact(l, 'buyTokenAMAP(address,address,uint256,uint256)', [
                token,
                wallet,
                l.amountIn,
                l.minOut,
              ]);
            } else {
              _exact(l, 'sellToken(uint256,address,uint256,uint256)', [
                BigInt.zero,
                token,
                l.amountIn,
                l.minOut,
              ]);
            }
          case 'flap':
            _exact(
              l,
              'swapExactInputV3((address,address,uint256,uint256,bytes,bytes))',
              [
                [l.tokenIn, l.tokenOut, l.amountIn, l.minOut, <int>[], <int>[]],
              ],
            );
          case 'genius':
            _exact(
              l,
              req.buy
                  ? 'buy(uint256,uint256,address)'
                  : 'sell(uint256,uint256,address)',
              [l.amountIn, l.minOut, wallet],
            );
          default:
            throw _invalid;
        }
      case 'conversion':
        config.requireUxuySwap();
        _require(
          !{l.tokenIn, l.tokenOut}.contains(token) &&
              {
                zeroAddress,
                quote,
                settlement,
              }.containsAll({l.tokenIn, l.tokenOut}),
        );
        _require(_same(l.to, config.router));
        if (l is RouteLeg) _conversion(l, config.router, plan.deadline);
      case 'wrap':
        _require(
          l.to == wrapped &&
              l.tokenIn == zeroAddress &&
              l.tokenOut == wrapped &&
              l.amountIn == l.minOut,
        );
        if (l is RouteLeg) _exact(l, 'deposit()', []);
      case 'unwrap':
        _require(
          l.to == wrapped &&
              l.tokenIn == wrapped &&
              l.tokenOut == zeroAddress &&
              l.amountIn == l.minOut,
        );
        if (l is RouteLeg) _exact(l, 'withdraw(uint256)', [l.amountIn]);
      default:
        throw _invalid;
    }
    if (l.tokenIn != zeroAddress && l.kind != 'unwrap') {
      final spender = l.kind == 'conversion'
          ? config.approvalSpender!.toLowerCase()
          : target!;
      seen[(l.tokenIn, spender)] = l.amountIn;
    }
  }
  _require(
    seen.length == approvals.length &&
        seen.entries.every((e) => approvals[e.key] == e.value),
  );
}
