import 'dart:async';

import 'package:flutter/material.dart';

import '../evm/evm.dart';
import '../exec/executor.dart';
import '../state/app_state.dart';
import 'widgets.dart';

Widget tradeReviewLine(String name, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 100,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: Text(name, style: label),
        ),
      ),
      Expanded(child: Text(value, style: strong)),
    ],
  ),
);

class GroupQuoteAction extends StatefulWidget {
  const GroupQuoteAction({
    super.key,
    required this.state,
    required this.group,
    required this.active,
    required this.busy,
    required this.enabled,
    required this.label,
    required this.onStart,
  });
  final AppState state;
  final GroupBase group;
  final bool active, busy, enabled;
  final String label;
  final Future<void> Function(WarmGroupQuote?) onStart;
  @override
  State<GroupQuoteAction> createState() => _GroupQuoteActionState();
}

class _GroupQuoteActionState extends State<GroupQuoteAction> {
  Timer? _timer;
  String? _key;
  WarmGroupQuote? _shown;
  int _revision = 0;
  bool _clicked = false;
  String? get _identity =>
      widget.active && widget.enabled && !widget.busy && !_clicked
      ? widget.state.quoteIdentity(widget.group)
      : null;

  void _schedule() {
    final identity = _identity;
    if (identity == _key) return;
    _key = identity;
    _shown = null;
    _timer?.cancel();
    final revision = ++_revision;
    if (identity != null)
      _timer = Timer(const Duration(milliseconds: 600), () => _read(revision));
  }

  Future<void> _read(int revision) async {
    if (!mounted || revision != _revision) return;
    WarmGroupQuote? next;
    try {
      next = await widget.state.warmGroupQuote(widget.group);
    } catch (_) {
      /* A manual check is still available. */
    }
    if (!mounted || revision != _revision || _key != _identity) return;
    setState(() => _shown = next);
    final delay = next == null
        ? const Duration(seconds: 5)
        : const Duration(seconds: 15) -
              widget.state.groupQuoteClock().difference(next.started);
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (!mounted || revision != _revision) return;
      setState(() => _shown = null);
      _read(revision);
    });
  }

  Future<void> _click(WarmGroupQuote? quoted) async {
    if (_clicked) return;
    if (quoted != null &&
        (!identical(quoted, _shown) ||
            !quoted.fresh ||
            quoted.identity != _identity)) {
      setState(() {
        _key = null;
        _schedule();
      });
      return;
    }
    setState(() {
      _clicked = true;
      _schedule();
    });
    try {
      await widget.onStart(quoted);
    } finally {
      if (mounted)
        setState(() {
          _clicked = false;
          _schedule();
        });
    }
  }

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    final q = _shown, tok = widget.state.token;
    final ordinary = widget.group;
    final sale = ordinary is TradeGroup ? !ordinary.buy : true;
    final key = q == null
        ? (sale ? 'check_group_approval' : null)
        : q.needsApproval
        ? 'check_group_approval'
        : ordinary is LinkedGroup
        ? 'confirm_linked_start'
        : q.buy
        ? 'confirm_buy'
        : 'confirm_sell';
    final label = key == null ? widget.label : t(context, key);
    final interval = ordinary is TradeGroup && ordinary.mode == SendMode.interval;
    final proceeds = q?.normal?.quotedOutput ?? q?.linked?.expected;
    final proceedsLabel = ordinary is LinkedGroup
        ? 'first_batch_expected'
        : interval ? 'first_trade_receive' : 'expected_receive';
    String amount(BigInt? value, {required bool native}) {
      final decimals = native ? 18 : tok?.decimals;
      if (value == null || decimals == null) return t(context, 'not_quoted');
      final number = formatUnits(value, decimals, maxFraction: decimals);
      return '$number ${native ? 'BNB' : tok!.symbol}';
    }
    final impact = q?.impact;
    final impactText = impact == null ? t(context, 'not_quoted') : '${impact.toStringAsFixed(2)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (q != null && tok != null && tok.decimals != null) ...[
          SelectableText('${tok.symbol} · ${tok.address}', style: mono),
          const SizedBox(height: 6),
          tradeReviewLine(
            t(context, q.buy ? 'round_spend' : 'this_round_sell'),
            amount(q.amount, native: q.buy),
          ),
          tradeReviewLine(t(context, proceedsLabel), amount(proceeds, native: !q.buy)),
          tradeReviewLine(t(context, interval ? 'first_trade_impact' : 'price_impact'), impactText),
          const SizedBox(height: 6),
        ],
        PrimaryButton(
          label: label,
          busy: widget.busy,
          onPressed: widget.enabled && !_clicked ? () => _click(q) : null,
        ),
      ],
    );
  }
}
