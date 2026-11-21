import '../exec/preview_deadline.dart';

import 'package:flutter/material.dart';

import '../evm/evm.dart';
import '../exec/linked.dart';
import '../state/app_state.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_backup.dart';
import 'batch_page.dart';
import 'impact_settings.dart';
import 'clipboard_feedback.dart';
import 'generated_wallet_list.dart';
import 'key_editor.dart';
import 'group_quote_action.dart';
import 'widgets.dart';
import 'wallet_overlap.dart';

/// Linked group (web LinkedGroupCard): sellers sell a tranche, buyers buy back with the BNB received,
/// relays top up short buyers. The round survives stops: continue it, end it, or query its transactions.
class LinkedGroupDetail extends StatefulWidget {
  const LinkedGroupDetail({
    super.key,
    required this.state,
    required this.group,
    this.active=true,
  });
  final bool active;
  final AppState state;
  final LinkedGroup group;

  @override
  State<LinkedGroupDetail> createState() => _LinkedGroupDetailState();
}

class _LinkedGroupDetailState extends State<LinkedGroupDetail> {
  late final min = TextEditingController(text: widget.group.min);
  late final max = TextEditingController(text: widget.group.max);
  late final iMin = TextEditingController(text: widget.group.intervalMin);
  late final iMax = TextEditingController(text: widget.group.intervalMax);
  bool refreshing = false;
  bool querying = false;
  bool showRelays = false;
  bool sellersExpanded = false;
  bool buyersExpanded = false;

  @override
  void initState() {
    super.initState();
    widget.group.addListener(_sync);
  }

  @override
  void dispose() {
    widget.group.removeListener(_sync);
    final handle = _preparationHandle;
    if (handle != null) {
      widget.state.cancelPreparation(widget.group, handle: handle);
    }
    for (final c in [min, max, iMin, iMax]) {
      c.dispose();
    }
    super.dispose();
  }

  void _sync() {
    final g = widget.group;
    if (min.text != g.min) min.text = g.min;
    if (max.text != g.max) max.text = g.max;
    if (mounted) setState(() {});
  }

  Future<void> _guard(Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _refresh() async {
    setState(() => refreshing = true);
    await _guard(() => widget.state.refreshLinked(widget.group, force: true));
    if (mounted) setState(() => refreshing = false);
  }

  Future<void> _queryOriginal() async {
    if (querying) return;
    setState(() => querying = true);
    try {
      await _guard(() => widget.state.query(widget.group));
    } finally {
      if (mounted) setState(() => querying = false);
    }
  }

  Future<void> _editKeys(bool sellers) async {
    final g = widget.group;
    final side = sellers ? g.sellers : g.buyers;
    final saved = await Navigator.of(context).push<String>(
      KeyEditorRoute<String>(
        context: context,
        settings: const RouteSettings(name: '/uxuy_trade/keys'),
        builder: (_) => KeyEditorPage(
          backup: widget.state.walletBackup,
          backupCategory: sellers
              ? WalletBackupCategory.linkedSeller
              : WalletBackupCategory.linkedBuyer,
          backupScope: g.name,
          title:
              '${t(context, 'input_keys')} · ${g.name} ${t(context, sellers ? 'sellers' : 'buyers')}',
          initial: formatPrivateKeyLines(side),
          onSave: (text) async {
            final n = await widget.state.setLinkedKeys(
              g,
              sellers: sellers,
              text: text,
            );
            widget.state.log.add(
              '${g.name} ${sellers ? '卖方' : '买方'}已导入 $n 个钱包',
            );
          },
        ),
      ),
    );
    if (saved != null && mounted) {
      setState(() {
        if (sellers) {
          sellersExpanded = false;
        } else {
          buyersExpanded = false;
          showRelays = false;
        }
      });
    }
  }

  Future<void> _copyRelays() async {
    late List<TradeWallet> copied;
    await ClipboardFeedback.confirmed(
      context,
      confirm: () => confirmExport(context),
      text: () {
        final active = List<TradeWallet>.of(widget.group.transits);
        copied = [
          ...active,
          ...widget.group.allTransits.where((w) => !active.contains(w)),
        ];
        return formatPrivateKeyLines(copied);
      },
      onCopied: () => widget.state.markKeysCopied(copied),
      successLabel: t(context, 'exported'),
    );
  }

  bool preparing = false;
  Object? _preparationHandle;

  /// New round: draw and quote the first tranche, confirm, then execute it (web 首轮卖出 / 首批预计到账).
  Future<void> _start([WarmGroupQuote? warmed]) async {
    final s = widget.state;
    final g = widget.group;
    if (preparing || s.groupOperationBusy(g)) return;
    await withWalletUse(
      context,
      s,
      owner: g,
      label: g.name,
      addresses: s.groupWallets(g),
      action: () => _prepareAndStart(warmed),
    );
  }

  Future<void> _prepareAndStart(WarmGroupQuote? warmed) async {
    final s = widget.state;
    final g = widget.group;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => preparing = true);
    Object? preparationHandle;
    try {
      final preparation = s.prepareLinked(g,warmed:warmed);
      preparationHandle = s.operationHandle(g);
      _preparationHandle = preparationHandle;
      final prep = await preparation;
      if (!mounted) return;
      // The state lease remains held while the user confirms; stop only the spinner.
      setState(() => preparing = false);
      final token = s.preparedToken(g);
      if (token == null) throw StateError('交易准备已失效，请重新准备');
      final d = token.decimals ?? 18;
      final fast=warmed!=null&&!warmed.needsApproval&&warmed.fresh;
      final ok=fast || true==await showUiDialog<bool>(
        context: context,
        builder: (c) => UiDialog(
          title: Text('${t(c, 'start_linked')} · ${g.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TradeTokenWarning(symbol: token.symbol, address: token.address),
              const SizedBox(height: 14),
              tradeReviewLine(
                t(c, 'wallets'),
                '${t(c, 'sellers')} ${g.sellers.length} · ${t(c, 'buyers')} ${g.buyers.length}',
              ),
              tradeReviewLine(
                t(c, prep.buy ? 'impact_buy_back' : 'this_round_sell'),
                prep.buy
                    ? '${formatUnits(prep.tranche, 18, maxFraction: 18)} BNB'
                    : '${formatUnits(prep.tranche, d, maxFraction: d)} ${token.symbol}',
              ),
              tradeReviewLine(
                t(c, 'first_batch_expected'),
                prep.expected == null
                    ? t(c, 'not_quoted')
                    : prep.buy
                    ? '${formatUnits(prep.expected!, d, maxFraction: d)} ${token.symbol}'
                    : '${formatUnits(prep.expected!, 18, maxFraction: 18)} BNB',
              ),
              const SizedBox(height: 8),
              if (prep.impact != null)
                tradeReviewLine(t(c, 'price_impact'), '${prep.impact!.toStringAsFixed(2)}%'),
              Text(t(c, 'linked_impact_hint'), style: muted),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t(c, 'cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t(c, 'confirm_execute')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final review = s.preparedImpact(g);
      if (review == null) throw StateError(t(context, 'impact_stale'));
      if (!await confirmImpact(context, review) || !mounted) return;
      await s.startLinked(
        g,
        impactConfirmed: review.needsConfirmation,
        handle: preparationHandle,
      );
    } on PreviewCancelled {
      return;
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (preparationHandle != null) {
        s.cancelPreparation(g, handle: preparationHandle);
      }
      if (identical(_preparationHandle, preparationHandle)) {
        _preparationHandle = null;
      }
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> _endRound() async {
    final g = widget.group;
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: Text('${t(c, 'end_round')} · ${g.name}'),
        content: Text(t(c, 'end_round_hint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t(c, 'cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t(c, 'confirm')),
          ),
        ],
      ),
    );
    if (ok == true) await _guard(() async => widget.state.finishLinked(g));
  }

  Future<void> _remove() async {
    final g = widget.group;
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: Text('${t(context, 'remove_group')} ${g.name}'),
        content: Text(t(context, 'remove_group_hint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t(context, 'cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t(context, 'remove')),
          ),
        ],
      ),
    );
    if (ok == true) await _guard(() async => widget.state.removeGroup(g));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final g = widget.group;
    final tr = g.trader;
    final token = s.token;
    final symbol = token?.symbol ?? t(context, 'token');
    final decimals = token?.decimals ?? 18;
    final running = tr.running;
    final operationBusy = preparing || s.groupOperationBusy(g);
    final locked = g.locked || operationBusy;
    final p = tr.progress;
    final status = g.status;
    final warning = tr.reconciliationWarning;
    final errorMessage = warning
        ? t(
            context,
            p?.phase == 'buy'
                ? 'buy_reconciliation_error'
                : 'sell_reconciliation_error',
          )
        : (!running && !tr.reconciling ? tr.error : null);
    final blocker = token == null
        ? t(context, 'need_token')
        : g.sellers.isEmpty || g.buyers.isEmpty
        ? t(context, 'need_linked_keys')
        : !g.transitsBackedUp
        ? t(
            context,
            widget.state.walletBackup == null
                ? 'transit_backup_rule'
                : 'folder_transit_backup_rule',
          )
        : null;

    return Panel(
      title: '${g.name} · ${t(context, 'sell_then_buy')}',
      trailing: IconButton(
        tooltip: t(context, 'remove_group'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close, size: 20),
        onPressed: running || operationBusy || tr.needsQuery ? null : _remove,
      ),
      child: TradeColumns(
        left: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(t(context, 'wallets'), style: strong),
                if (g.allWallets.isNotEmpty) SmallButton(
                  label: t(context, refreshing ? 'reading' : 'refresh'),
                  onPressed: refreshing ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final sides = [
                  for (final sellers in [true, false])
                    _Side(
                      key: ValueKey(sellers),
                      group: g,
                      sellers: sellers,
                      symbol: symbol,
                      decimals: token?.decimals,
                      onEdit: locked ? null : () => _editKeys(sellers),
                      expanded: sellers ? sellersExpanded : buyersExpanded,
                      onExpand: () => setState(() {
                        if (sellers) {
                          sellersExpanded = !sellersExpanded;
                        } else {
                          buyersExpanded = !buyersExpanded;
                        }
                      }),
                    ),
                ];
                if (constraints.maxWidth < 540) {
                  return Column(children: sides);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: sides[0]),
                    const SizedBox(width: 14),
                    Expanded(child: sides[1]),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Text(t(context, 'relay_hint'), style: muted),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: g.locked || s.groupOperationBusy(g)
                    ? null
                    : () => Navigator.of(context).push<String>(
                        KeyEditorRoute(
                          context: context,
                          builder: (_) => KeyEditorPage(
                            title: '恢复中转备份 · ${g.name}',
                            expectedRecipients: g.buyers
                                .map((w) => w.address)
                                .join('\n'),
                            onRestoreTransits: (backup, recipients) async {
                              await s.restoreTransits(
                                backup,
                                recipients,
                                group: g,
                              );
                            },
                          ),
                        ),
                      ),
                child: const Text('恢复中转备份'),
              ),
            ),
            if (g.buyers.isNotEmpty) _relays(context, g),
          ],
        ),
        right: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t(context, 'trade_settings'), style: strong),
            const SizedBox(height: 8),
            _Flow(phase: running ? p?.phase : null),
            const SizedBox(height: 12),
            TradeControlField(
              text: t(context, 'per_round_sell'),
              topAligned: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OptionPair<bool>(
                    compact: true,
                    options: [
                      (true, t(context, 'ratio')),
                      (false, t(context, 'quantity')),
                    ],
                    value: g.ratio,
                    onChanged: locked ? null : g.setRatio,
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: TradeLockedFields(
                      locked: locked,
                      child: RangeRow(
                        min: min,
                        max: max,
                        unit: g.ratio ? '%' : symbol,
                        onMin: (v) => g.update((x) => x.min = v),
                        onMax: (v) => g.update((x) => x.max = v),
                      ),
                    ),
                  ),
                  if (g.ratio) ...[
                    const SizedBox(height: 5),
                    Text(t(context, 'linked_ratio_hint'), style: muted),
                  ],
                ],
              ),
            ),
            const Divider(height: 24, color: UiStyle.border),
            TradeControlField(
              text: t(context, 'order'),
              child: OptionPair<bool>(
                compact: true,
                options: [
                  (false, t(context, 'sequential')),
                  (true, t(context, 'random')),
                ],
                value: g.randomOrder,
                onChanged: locked ? null : (v) => g.update((x) => x.randomOrder = v),
              ),
            ),
            const SizedBox(height: 8),
            TradeControlField(
              text: t(context, 'interval'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: TradeLockedFields(
                  locked: locked,
                  child: RangeRow(
                    min: iMin,
                    max: iMax,
                    unit: t(context, 'seconds'),
                    onMin: (v) => g.update((x) => x.intervalMin = v),
                    onMax: (v) => g.update((x) => x.intervalMax = v),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.autorenew, size: 16, color: UiStyle.muted),
                const SizedBox(width: 4),
                Text(t(context, 'auto_loop'), style: label),
              ],
            ),
            const Divider(height: 24, color: UiStyle.border),
            // ------------------------------------------------ progress
            if (p != null)
              _ProgressBox(
                progress: p,
                symbol: symbol,
                decimals: decimals,
                reconciling: tr.reconciling,
              ),
            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    errorMessage,
                    style: label.copyWith(color: UiStyle.negative),
                  ),
                ),
              ),

            // ------------------------------------------------ actions
            if (running && !warning && !querying)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).width >= 800
                        ? 40
                        : 44,
                    child: OutlinedButton(
                      onPressed: tr.paused
                          ? () => resumeGroupWithWalletCheck(
                              context,
                              s,
                              g,
                              tr.resume,
                            )
                          : tr.pause,
                      child: Text(
                        t(context, tr.paused ? 'resume' : 'pause'),
                      ),
                    ),
                  ),
                  PrimaryButton(
                    label: t(context, 'stop'),
                    onPressed: tr.cancel,
                  ),
                ],
              )
            else if (tr.needsQuery || querying) ...[
              PrimaryButton(
                label: '${t(context, 'query_tx')} · ${g.name}',
                busy: querying,
                onPressed: querying || (operationBusy && !tr.reconciling)
                    ? null
                    : _queryOriginal,
              ),
              if (!tr.reconciling && !querying)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(t(context, 'query_hint'), style: muted),
                ),
            ] else if (status == GroupStatus.partial)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).width >= 800
                        ? 40
                        : 44,
                    child: OutlinedButton(
                      onPressed: operationBusy ? null : _endRound,
                      child: Text(t(context, 'end_round')),
                    ),
                  ),
                  PrimaryButton(
                    label: t(context, 'continue_round'),
                    onPressed: blocker == null && !operationBusy
                        ? _start
                        : null,
                  ),
                ],
              )
            else ...[
              Text(t(context, 'approval_check_hint'), style: muted),
              GroupQuoteAction(state:s,group:g,active:widget.active,busy:preparing,enabled:blocker==null&&!operationBusy,
                label:t(context,'start_linked'),onStart:_start),
              if (blocker != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(blocker, style: muted),
                ),
            ],
            if (preparing && s.slowPreview(g))
              QuoteWaitNotice(
                cancel: () =>
                    s.cancelPreparation(g, handle: _preparationHandle),
              ),
            if (running && !warning && !querying)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t(context, 'stop_hint'), style: muted),
              ),
          ],
        ),
      ),
    );
  }

  Widget _relays(BuildContext context, LinkedGroup g) {
    final relays = g.transits;
    final unbacked = relays.where((r) => !r.canReceiveFunds).length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => showRelays = !showRelays),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text:
                                '${t(context, 'transits')} · ${relays.length}',
                            style: strong,
                          ),
                          if (unbacked > 0)
                            TextSpan(
                              text:
                                  '  $unbacked ${t(context, 'not_backed_up')}',
                              style: muted.copyWith(color: UiStyle.action),
                            ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _copyRelays,
                    child: Text(t(context, 'copy_transit_keys')),
                  ),
                  Icon(
                    showRelays ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (showRelays)
            GeneratedWalletList(
              wallets: relays,
              onKeyCopied: (wallet) => widget.state.markKeysCopied([wallet]),
              detail: (index) {
                final balance = g.stateOf(relays[index]);
                final amount = balance == null
                    ? '—'
                    : '${formatUnits(balance.native, 18, maxFraction: 4)} BNB';
                return '${t(context, 'buyers')} ${g.buyers[index].address} · $amount';
              },
            ),
        ],
      ),
    );
  }
}

/// 卖方卖出 → 中转补款 → 买方买回, with the current phase highlighted while running.
class _Flow extends StatelessWidget {
  const _Flow({required this.phase});
  final String? phase;

  @override
  Widget build(BuildContext context) {
    Widget step(String key, bool active) => Text(
      t(context, key),
      style: active ? strong : muted,
    );
    const arrow = Icon(Icons.arrow_forward, size: 13, color: UiStyle.muted);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        step('sellers', phase == 'sell'),
        arrow,
        step('relay_funding', false),
        arrow,
        step('buyers', phase == 'buy'),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    super.key,
    required this.group,
    required this.sellers,
    required this.symbol,
    required this.decimals,
    required this.onEdit,
    required this.expanded,
    required this.onExpand,
  });
  final LinkedGroup group;
  final bool sellers;
  final String symbol;
  final int? decimals;
  final VoidCallback? onEdit;

  final bool expanded;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final list = sellers ? g.sellers : g.buyers;
    final bnb = g.nativeTotal(list);
    final tok = g.tokenTotal(list);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    t(context, sellers ? 'sellers' : 'buyers'),
                    style: strong,
                  ),
                  Text(
                    '${list.length} ${t(context, 'wallets_unit')}',
                    style: muted,
                  ),
                ],
              ),
              SmallButton(label: t(context, 'input_keys'), onPressed: onEdit),
            ],
          ),
          if (list.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: WalletTotal(
                    label: 'BNB ${t(context, 'total')}',
                    value: bnb == null ? '—' : formatUnits(bnb, 18, maxFraction: 4),
                  ),
                ),
                Expanded(
                  child: WalletTotal(
                    label: '$symbol ${t(context, 'total')}',
                    value: tok == null || decimals == null
                        ? '—'
                        : formatUnits(tok, decimals!, maxFraction: 2),
                  ),
                ),
                IconButton(
                    key: ValueKey(
                      sellers ? 'linked-seller-details' : 'linked-buyer-details',
                    ),
                    tooltip: t(context, expanded ? 'collapse' : 'expand'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                    ),
                    onPressed: onExpand,
                  ),
              ],
            ),
          ],
          if (expanded)
            for (var i = 0; i < list.length; i++) _row(i, list[i], g),
        ],
      ),
    );
  }

  Widget _row(int i, TradeWallet w, LinkedGroup g) {
    final st = g.stateOf(w);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: WalletAddressRow(
        number: i + 1,
        address: w.address,
        detail: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              st == null
                  ? '—'
                  : '${formatUnits(st.native, 18, maxFraction: 4)} BNB',
              style: muted.copyWith(color: UiStyle.text),
            ),
            if (st?.tokenBalance != null && decimals != null)
              Text(
                '${formatUnits(st!.tokenBalance!, decimals!, maxFraction: 2)} ${symbol}',
                style: muted,
              ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBox extends StatelessWidget {
  const _ProgressBox({
    required this.progress,
    required this.symbol,
    required this.decimals,
    required this.reconciling,
  });
  final LinkedProgress progress;
  final String symbol;
  final int decimals;
  final bool reconciling;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final round = t(context, 'round_fmt').replaceAll('{n}', '${p.round}');
    final phase = t(context, p.phase == 'sell' ? 'phase_sell' : 'phase_buy');
    final toBuy = reconciling
        ? '—'
        : '${formatUnits(p.buyRemaining, 18, maxFraction: 6)} BNB';
    final received = reconciling && p.phase == 'sell'
        ? '—'
        : '${formatUnits(p.received, 18, maxFraction: 6)} BNB';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: UiStyle.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            p.finished
                ? '$round · ${t(context, 'st_done')}'
                : '$round · $phase',
            style: strong,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${t(context, 'this_round_sell')} ${formatUnits(p.tranche, decimals, maxFraction: 2)} $symbol',
                  style: muted,
                ),
              ),
              Text(
                '${t(context, 'to_buy_back')} $toBuy',
                style: strong,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('${t(context, 'received_total')} $received', style: muted),
        ],
      ),
    );
  }
}
