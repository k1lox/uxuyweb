import '../exec/preview_deadline.dart';

import 'package:flutter/material.dart';

import '../evm/evm.dart';
import '../exec/executor.dart';
import '../state/app_state.dart';
import '../wallet/wallet_backup.dart';
import 'batch_group_help.dart';
import 'clipboard_feedback.dart';
import 'key_editor.dart';
import 'group_quote_action.dart';
import 'impact_settings.dart';
import 'linked_page.dart';
import 'widgets.dart';
import 'wallet_overlap.dart';

part 'rapid_group_settings.dart';

class BatchPage extends StatelessWidget {
  const BatchPage({super.key, required this.state,this.active=true});
  final bool active;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final g = s.group;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(t(context, 'groups'), style: panelTitle)),
                if (MediaQuery.sizeOf(context).width < 360)
                  const BatchGroupHelpButton(),
              ],
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => editImpactSettings(context, s),
                  child: Text(t(context, 'impact_settings')),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: g == null ? null : UiStyle.surface,
                    foregroundColor: g == null ? null : UiStyle.text,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(t(context, 'new_group')),
                  onPressed: () => _newGroup(context),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (g == null)
          EmptyState(
            icon: Icons.group_add_outlined,
            title: t(context, 'no_groups_title'),
            hint: t(context, 'no_groups'),
          )
        else ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 680;
              if (!wide) {
                return _NarrowGroupList(
                  groups: s.groups,
                  selected: s.current,
                  onSelect: s.select,
                );
              }
              final columns = constraints.maxWidth >= 1100 ? 4 : 3;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < s.groups.length; i++)
                    SizedBox(
                      width: width,
                      child: _GroupChip(
                        group: s.groups[i],
                        selected: i == s.current,
                        onTap: () => s.select(i),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          if (g is LinkedGroup)
            LinkedGroupDetail(key: ValueKey(g.number), state: s, group: g,active:active)
          else
            GroupDetail(
              key: ValueKey(g.number),
              state: s,
              group: g as TradeGroup,
              active:active,
            ),
        ],
      ],
    );
  }

  /// Create the selected group type.
  Future<void> _newGroup(BuildContext context) async {
    final kind = await showUiDialog<String>(
      context: context,
      builder: (c) => UiDialog(
        title: Text(t(c, 'group_type')),
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (value, title, hint) in [
              ('ordinary', t(c, 'normal_group'), t(c, 'normal_group_hint')),
              ('linked', t(c, 'linked_group'), t(c, 'linked_group_hint')),
              ('rapid', t(c, 'rapid_group_name'), t(c, 'rapid_group_help')),
            ])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: Text(
                  title,
                  style: strong,
                ),
                subtitle: Text(hint, style: muted),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.pop(c, value),
              ),
          ],
        ),
      ),
    );
    switch(kind) {
      case 'ordinary': state.addGroup();
      case 'linked': state.addLinkedGroup();
      case 'rapid': state.addRapidGroup();
    }
  }
}

String statusText(BuildContext context, GroupStatus st) =>
    t(context, switch (st) {
      GroupStatus.needKeys => 'st_need_keys',
      GroupStatus.ready => 'st_ready',
      GroupStatus.running => 'st_running',
      GroupStatus.paused => 'st_paused',
      GroupStatus.pending => 'st_pending',
      GroupStatus.partial => 'st_partial',
      GroupStatus.done => 'st_done',
      GroupStatus.stopped => 'st_stopped',
    });

class _NarrowGroupList extends StatefulWidget {
  const _NarrowGroupList({
    required this.groups,
    required this.selected,
    required this.onSelect,
  });
  final List<GroupBase> groups;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<_NarrowGroupList> createState() => _NarrowGroupListState();
}

class _NarrowGroupListState extends State<_NarrowGroupList> {
  static const double chipWidth = 220;
  static const double gap = 8;
  late final scroll = ScrollController(keepScrollOffset: false);

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(_NarrowGroupList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _revealSelected();
  }

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final position = scroll.position;
      final start = widget.selected * (chipWidth + gap);
      final end = start + chipWidth;
      final leftmost = (end - position.viewportDimension).clamp(0.0, start);
      final target = position.pixels.clamp(leftmost, start)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      if (target != position.pixels) scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 20 + MediaQuery.textScalerOf(context).scale(14) * 4,
    child: ListView.separated(
      controller: scroll,
      scrollDirection: Axis.horizontal,
      itemCount: widget.groups.length,
      separatorBuilder: (_, _) => const SizedBox(width: gap),
      itemBuilder: (_, index) => SizedBox(
        width: chipWidth,
        child: _GroupChip(
          group: widget.groups[index],
          selected: index == widget.selected,
          onTap: () => widget.onSelect(index),
        ),
      ),
    ),
  );
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.group,
    required this.selected,
    required this.onTap,
  });
  final GroupBase group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final mode = g is RapidGroup ? g.direction.label : g is TradeGroup
        ? '${t(context, g.mode == SendMode.bundle ? 'bundle' : 'interval')}${t(context, g.buy ? 'buy' : 'sell')}'
        : t(context, 'sell_then_buy');
    final count = g is LinkedGroup
        ? '${t(context, 'sellers')} ${g.sellers.length} / ${t(context, 'buyers')} ${g.buyers.length}'
        : '${(g as TradeGroup).wallets.length} ${t(context, 'wallets_unit')}';
    final running = g.status == GroupStatus.running;
    final reconciliationWarning =
        g is LinkedGroup && g.trader.reconciliationWarning;
    return Material(
      color: selected ? UiStyle.surface : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? UiStyle.muted : UiStyle.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Text(
                    g.name,
                    style: selected ? strong : null,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      count,
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: mode),
                    TextSpan(
                      text: ' · ',
                      style: TextStyle(
                        color: running ? UiStyle.positive : UiStyle.muted,
                      ),
                    ),
                    TextSpan(
                      text: reconciliationWarning
                          ? t(context, 'st_reconciliation_error')
                          : statusText(context, g.status),
                      style: reconciliationWarning
                          ? const TextStyle(color: UiStyle.negative)
                          : null,
                    ),
                    if (g is TradeGroup && g.wallets.isNotEmpty)
                      TextSpan(
                        text:
                            '  ${t(context, 'selected')} ${g.selected.length}/${g.wallets.length}',
                      ),
                  ],
                ),
                style: muted,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wallet details and settings sit side by side on desktop and stack on narrow screens.
class GroupDetail extends StatefulWidget {
  const GroupDetail({super.key, required this.state, required this.group,this.active=true});
  final bool active;
  final AppState state;
  final TradeGroup group;

  @override
  State<GroupDetail> createState() => _GroupDetailState();
}

class _GroupDetailState extends State<GroupDetail> {
  late final min = TextEditingController(text: widget.group.min);
  late final max = TextEditingController(text: widget.group.max);
  late final iMin = TextEditingController(text: widget.group.intervalMin);
  late final iMax = TextEditingController(text: widget.group.intervalMax);
  bool expanded = false;
  bool refreshing = false;

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

  // The active saved range changes with direction / ratio switches; keep fields in step without fighting typing.
  void _sync() {
    final g = widget.group;
    if (min.text != g.min) min.text = g.min;
    if (max.text != g.max) max.text = g.max;
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => refreshing = true);
    try {
      await widget.state.refresh(widget.group, force: true);
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> _editKeys() async {
    final g = widget.group;
    final saved = await Navigator.of(context).push<String>(
      KeyEditorRoute<String>(
        context: context,
        settings: const RouteSettings(name: '/uxuy_trade/keys'),
        builder: (_) => KeyEditorPage(
          title: '${t(context, 'input_keys')} · ${g.name}',
          backup: widget.state.walletBackup,
          backupCategory: WalletBackupCategory.tradeGroup,
          backupScope: g.name,
          initial: formatPrivateKeyLines(g.wallets),
          onSave: (text) async {
            final n = await widget.state.setKeys(g, text);
            widget.state.log.add('${g.name} 已导入 $n 个钱包');
          },
        ),
      ),
    );
    if (saved != null && mounted && expanded) setState(() => expanded = false);
  }

  bool preparing = false;
  Object? _preparationHandle;

  /// Prepare (amounts drawn once and quoted) → confirm → execute the confirmed amounts.
  Future<void> _start({bool resume = false,WarmGroupQuote? warmed}) async {
    final s = widget.state;
    final g = widget.group;
    if (preparing || s.groupOperationBusy(g)) return;
    await withWalletUse(
      context,
      s,
      owner: g,
      label: g.name,
      addresses: s.groupWallets(g, resume: resume),
      action: () => _prepareAndStart(resume: resume,warmed:warmed),
    );
  }

  Future<void> _prepareAndStart({bool resume = false,WarmGroupQuote? warmed}) async {
    final s = widget.state;
    final g = widget.group;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => preparing = true);
    Object? preparationHandle;
    try {
      final preparation = s.prepare(g, resume: resume,warmed:warmed);
      preparationHandle = s.operationHandle(g);
      _preparationHandle = preparationHandle;
      final prepared = await preparation;
      if (!mounted) return;
      // The state lease remains held while the user confirms; stop only the spinner.
      setState(() => preparing = false);
      final token = s.preparedToken(g);
      if (token == null) throw StateError('交易准备已失效，请重新准备');
      final decimals = token.decimals ?? 18;
      String amount(BigInt v, bool bnb) =>
          '${formatUnits(v, bnb ? 18 : decimals, maxFraction: bnb ? 18 : decimals)} ${bnb ? 'BNB' : token.symbol}';
      final interval = g.mode == SendMode.interval;
      final inputLabel = interval
          ? (g.buy ? 'round_spend' : 'this_round_sell')
          : (g.buy ? 'expected_use' : 'this_time');
      final outLabel = interval
          ? 'first_trade_receive'
          : (g.buy ? 'expected_tokens' : 'expected_receive');
      final fast=warmed!=null&&!warmed.needsApproval&&warmed.fresh;
      final ok = fast || true==await showUiDialog<bool>(
        context: context,
        builder: (c) => UiDialog(
          title: Text('${t(c, g.buy ? 'buy' : 'sell')} · ${g.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TradeTokenWarning(symbol: token.symbol, address: token.address),
              const SizedBox(height: 14),
              tradeReviewLine(t(c, 'wallets'),
                '${prepared.amounts.length}${prepared.skipped > 0 ? ' · ${t(c, 'skipped')} ${prepared.skipped}' : ''}',
              ),
              tradeReviewLine(t(c, inputLabel), amount(prepared.inputTotal, g.buy)),
              if (interval && prepared.amounts.length > 1)
                tradeReviewLine(t(c, 'first_trade'),
                  '${prepared.amounts.keys.first} · ${amount(prepared.amounts.values.first, g.buy)}',
                ),
              tradeReviewLine(t(c, outLabel),
                prepared.quotedOutput == null
                    ? t(c, 'not_quoted')
                    : amount(prepared.quotedOutput!, !g.buy),
              ),
              if (prepared.impact != null)
                tradeReviewLine(t(c,interval ? 'first_trade_impact' : 'price_impact'),
                  '${prepared.impact!.toStringAsFixed(2)}%',
                ),
              const SizedBox(height: 8),
              Text(
                t(c, g.loop ? 'confirm_loop_hint' : 'confirm_hint'),
                style: muted,
              ),
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
      await s.start(
        g,
        resume: resume,
        prepared: prepared,
        impactConfirmed: review.needsConfirmation,
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

  Future<void> _query() async {
    try {
      await widget.state.query(widget.group);
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _endGroup() async {
    try {
      widget.state.endGroup(widget.group);
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> _exportKeys() async {
    final g = widget.group;
    await ClipboardFeedback.confirmed(
      context,
      confirm: () => confirmExport(context),
      text: () => formatPrivateKeyLines(g.wallets),
      successLabel: t(context, 'exported'),
    );
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
    if (ok == true) {
      try {
        widget.state.removeGroup(g);
      } on Object catch (e) {
        if (mounted) await showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final g = widget.group;
    final token = s.token;
    final running = g.trader.running;
    final operationBusy = preparing || s.groupOperationBusy(g);
    final locked =
        running ||
        operationBusy ||
        g.status == GroupStatus.pending ||
        g.status == GroupStatus.partial;
    final symbol = token?.symbol ?? t(context, 'token');
    final unit = g.ratio ? '%' : (g.buy ? 'BNB' : symbol);
    final blocker = token == null
        ? t(context, 'need_token')
        : g.wallets.isEmpty
        ? t(context, 'need_keys')
        : g.selected.isEmpty
        ? t(context, 'need_selection')
        : null;

    final panel = Panel(
      title: '${g.name} · ${g.wallets.length} ${t(context, 'addresses_unit')}',
      trailing: IconButton(
        tooltip: t(context, 'remove_group'),
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close, size: 20),
        onPressed: running || operationBusy ? null : _remove,
      ),
      child: TradeColumns(
        left: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ------------------------------------------------ wallets
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(t(context, 'wallets'), style: strong),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SmallButton(
                      label: t(context, 'input_keys'),
                      onPressed: locked ? null : _editKeys,
                    ),
                    if (g.wallets.isNotEmpty) SmallButton(
                      label: t(context, refreshing ? 'reading' : 'refresh'),
                      onPressed: refreshing ? null : _refresh,
                    ),
                  ],
                ),
              ],
            ),
            if (g.wallets.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: WalletTotal(
                      label: 'BNB ${t(context, 'total')}',
                      value: g.states.isEmpty
                          ? '—'
                          : formatUnits(g.nativeTotal, 18, maxFraction: 4),
                    ),
                  ),
                  Expanded(
                    child: WalletTotal(
                      label: '$symbol ${t(context, 'total')}',
                      value: g.tokenTotal == null || token?.decimals == null
                          ? '—'
                          : formatUnits(
                              g.tokenTotal!,
                              token!.decimals!,
                              maxFraction: 2,
                            ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24, color: UiStyle.border),
              InkWell(
                onTap: () => setState(() => expanded = !expanded),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        runSpacing: 4,
                        children: [
                          Text(
                            t(context, 'wallet_details'),
                            style: strong,
                          ),
                          Text(
                            ' · ${g.wallets.length} ${t(context, 'wallets_unit')} · ${t(context, 'selected')} ${g.selected.length}',
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t(context, expanded ? 'collapse' : 'expand'),
                      style: label,
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ],
            if (expanded && g.wallets.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _exportKeys,
                    child: Text(t(context, 'export_keys')),
                  ),
                  TextButton(
                    onPressed: locked ? null : g.selectAll,
                    child: Text(
                      t(
                        context,
                        g.selected.length == g.wallets.length
                            ? 'select_none'
                            : 'select_all',
                      ),
                    ),
                  ),
                ],
              ),
              for (var i = 0; i < g.wallets.length; i++)
                _WalletRow(
                  index: i,
                  group: g,
                  symbol: symbol,
                  decimals: token?.decimals,
                  enabled: !locked,
                ),
            ],
          ],
        ),
        right: g is RapidGroup ? _RapidGroupSettings(state: s,group:g) : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------------ trade settings
            Text(t(context, 'trade_settings'), style: strong),
            const SizedBox(height: 12),
            TradeControlField(
              text: t(context, 'direction'),
              child: OptionPair<bool>(
                compact: true,
                options: [
                  (true, t(context, 'buy')),
                  (false, t(context, 'sell')),
                ],
                styles: const [OptionStyle.buy, OptionStyle.sell],
                value: g.buy,
                onChanged: locked ? null : g.setBuy,
              ),
            ),
            const SizedBox(height: 10),
            TradeControlField(
              text: t(context, g.buy ? 'per_wallet_buy' : 'per_wallet_sell'),
              topAligned: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OptionPair<bool>(
                    compact: true,
                    options: [
                      (true, t(context, 'ratio')),
                      (false, t(context, 'amount')),
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
                        unit: unit,
                        onMin: (v) => g.update((x) => x.min = v),
                        onMax: (v) => g.update((x) => x.max = v),
                      ),
                    ),
                  ),
                  if (g.ratio) ...[
                    const SizedBox(height: 5),
                    Text(t(context, 'ratio_hint'), style: muted),
                  ],
                ],
              ),
            ),
            const Divider(height: 24, color: UiStyle.border),
            TradeControlField(
              text: t(context, 'execution'),
              child: OptionPair<SendMode>(
                compact: true,
                options: [
                  (SendMode.bundle, t(context, 'bundle')),
                  (SendMode.interval, t(context, 'interval')),
                ],
                value: g.mode,
                onChanged: locked ? null : (v) => g.update((x) => x.mode = v),
              ),
            ),
            if (g.mode == SendMode.interval) ...[
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
            ],
            const SizedBox(height: 8),
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
            TradeControlField(
              text: t(context, 'loop'),
              child: Checkbox(
                semanticLabel: t(context, 'loop'),
                value: g.loop,
                onChanged: locked ? null : (v) => g.update((x) => x.loop = v ?? false),
              ),
            ),
            const Divider(height: 24, color: UiStyle.border),

            if(g.trader.last case final outcome? when outcome.selling && outcome.tradeHashes.isNotEmpty) ...[
              ExpansionTile(
                tilePadding:EdgeInsets.zero,
                title:Text('卖出明细 · 已确认 ${outcome.confirmedWallets.length} 个钱包、${outcome.confirmed} 笔'),
                children:[
                  for(final order in outcome.swapOrders.entries)
                    ListTile(contentPadding:EdgeInsets.zero,
                      title:SelectableText(order.value.wallet),
                      subtitle:SelectableText(order.key),
                      trailing:Text(switch(outcome.swapStatuses[order.key]){
                        'confirmed'=>'已成交','reverted'=>'已回滚','not_included'=>'未上链',
                        'rejected'||'not_submitted'=>'未提交',_=>'待确认',
                      })),
                  if(outcome.confirmedWallets.isNotEmpty)
                    TextButton(onPressed:()=>ClipboardFeedback.copy(context,outcome.confirmedWallets.join('\n'),successLabel:'已复制成交钱包'),child:const Text('复制成交钱包')),
                ],
              ),
              if(outcome.unverifiedSettlement.isEmpty && (outcome.confirmed>0 || outcome.swapStatuses.containsValue('reverted')))
                Text('预计到账 ${formatUnits(outcome.confirmedQuote,18,maxFraction:18)} BNB · 实际到账 ${formatUnits(outcome.nativeReceived,18,maxFraction:18)} BNB · 网络费 ${formatUnits(outcome.networkFees,18,maxFraction:18)} BNB')
              else if(outcome.unverifiedSettlement.isNotEmpty)
                Text('有 ${outcome.unverifiedSettlement.length} 笔卖单的到账及网络费待核实'),
              const SizedBox(height:8),
            ],
            if (g.trader.last case final outcome? when outcome.remainingAssets.values.any((rows) => rows.isNotEmpty))
              Material(type: MaterialType.transparency, child: ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('换币结余'),
                children: [for (final line in outcome.remainingAssets.values.expand((rows) => rows)) SelectableText(line)])),
            if(g.trader.hasPendingSaleTotals && g.status!=GroupStatus.pending)
              TextButton(onPressed:operationBusy||running?null:_query,child:const Text('查询原交易到账')),
            // ------------------------------------------------ action
            if (running)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).width >= 800 ? 40 : 44,
                    child: OutlinedButton(
                      onPressed: g.trader.paused
                          ? () => resumeGroupWithWalletCheck(
                              context,
                              s,
                              g,
                              g.trader.resume,
                            )
                          : g.trader.pause,
                      child: Text(
                        t(context, g.trader.paused ? 'resume' : 'pause'),
                      ),
                    ),
                  ),
                  PrimaryButton(
                    label: t(context, 'stop'),
                    onPressed: g.trader.cancel,
                  ),
                ],
              )
            else if (g.status == GroupStatus.pending) ...[
              PrimaryButton(
                label: '${t(context, 'query_tx')} · ${g.name}',
                onPressed: operationBusy ? null : _query,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t(context, 'query_hint'), style: muted),
              ),
            ] else if (g.status == GroupStatus.partial) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).width >= 800 ? 40 : 44,
                    child: OutlinedButton(
                      onPressed: operationBusy ? null : _endGroup,
                      child: Text(t(context, 'end_group')),
                    ),
                  ),
                  PrimaryButton(
                    label:
                        '${t(context, 'run_remaining')} · ${g.remaining!.length}',
                    onPressed: blocker == null && !operationBusy
                        ? () => _start(resume: true)
                        : null,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t(context, 'remaining_hint'), style: muted),
              ),
            ] else ...[
              if (!g.buy) Text(t(context, 'approval_check_hint'), style: muted),
              GroupQuoteAction(state:s,group:g,active:widget.active,busy:preparing,enabled:blocker==null&&!operationBusy,
                label:t(context,'start'),onStart:(q)=>_start(warmed:q)),
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
            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t(context, 'stop_hint'), style: muted),
              ),
          ],
        ),
      ),
    );
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: g.wallets.isEmpty ? 520 : double.infinity),
        child: panel,
      ),
    );
  }
}

/// The exact pinned transaction target, visible before a user confirms either group type.
class TradeTokenWarning extends StatelessWidget {
  const TradeTokenWarning({
    super.key,
    required this.symbol,
    required this.address,
  });
  final String symbol;
  final String address;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const ValueKey('trade-token-warning'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: UiStyle.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: UiStyle.action,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('BSC · $symbol', style: strong)),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            address,
            semanticsLabel: '合约地址：$address',
            style: mono,
          ),
          const SizedBox(height: 8),
          Text(
            Localizations.localeOf(context).languageCode == 'zh'
                ? '请核对网络与代币地址，确认后将按此代币执行。'
                : 'Check the network and token address. Confirming trades this token.',
            style: label,
          ),
        ],
      ),
    ),
  );
}

/// Prevent mouse and keyboard edits while a prepared or unfinished round owns these fields.
class TradeLockedFields extends StatelessWidget {
  const TradeLockedFields({
    super.key,
    required this.locked,
    required this.child,
  });
  final bool locked;
  final Widget child;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: locked,
    child: AbsorbPointer(absorbing: locked, child: child),
  );
}

class WalletTotal extends StatelessWidget {
  const WalletTotal({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: muted, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(value, style: panelTitle),
      ],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.index,
    required this.group,
    required this.symbol,
    required this.decimals,
    required this.enabled,
  });
  final int index;
  final TradeGroup group;
  final String symbol;
  final int? decimals;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final w = group.wallets[index];
    final st = group.stateOf(w);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: WalletAddressRow(
        number: index + 1,
        address: w.address,
        leading: SizedBox(
          width: 32,
          child: Checkbox(
            value: group.selected.contains(w.address),
            visualDensity: VisualDensity.compact,
            onChanged: enabled ? (_) => group.toggle(w) : null,
          ),
        ),
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
                '${formatUnits(st!.tokenBalance!, decimals!, maxFraction: 2)} $symbol',
                style: muted,
              ),
          ],
        ),
      ),
    );
  }
}

/// Keys leave the module only on an explicit confirmation.
Future<bool?> confirmExport(BuildContext context) => showUiDialog<bool>(
  context: context,
  builder: (c) => UiDialog(
    title: Text(t(c, 'export_keys')),
    content: Text(t(c, 'export_keys_hint')),
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

/// Align related trade settings on one label column and stack long fields on phones.
class TradeControlField extends StatelessWidget {
  const TradeControlField({
    super.key,
    required this.text,
    required this.child,
    this.topAligned = false,
  });
  final String text;
  final Widget child;
  final bool topAligned;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 300) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: label),
            const SizedBox(height: 6),
            child,
          ],
        );
      }
      return Row(
        crossAxisAlignment: topAligned
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Padding(
              padding: EdgeInsets.only(right: 8, top: topAligned ? 8 : 0),
              child: Text(text, style: label),
            ),
          ),
          Expanded(
            child: Align(alignment: AlignmentDirectional.centerStart, child: child),
          ),
        ],
      );
    },
  );
}

/// A single-scrolling trading workspace. Columns have natural height, never their own scroll area.
class TradeColumns extends StatelessWidget {
  const TradeColumns({super.key, required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 820) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            left,
            const Divider(height: 28, color: UiStyle.border),
            right,
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: left),
          const SizedBox(width: 24),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.only(left: 24),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: UiStyle.border)),
              ),
              child: right,
            ),
          ),
        ],
      );
    },
  );
}
