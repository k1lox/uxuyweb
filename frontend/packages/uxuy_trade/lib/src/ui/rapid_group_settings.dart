part of 'batch_page.dart';

extension _RapidLabel on RapidDirection {
  String get label => switch (this) {
    RapidDirection.buy => '只买入',
    RapidDirection.sell => '只卖出',
    RapidDirection.both => '买卖交替',
  };
}

class _RapidGroupSettings extends StatefulWidget {
  const _RapidGroupSettings({required this.state, required this.group});
  final AppState state;
  final RapidGroup group;
  @override
  State<_RapidGroupSettings> createState() => _RapidGroupSettingsState();
}

class _RapidGroupSettingsState extends State<_RapidGroupSettings> {
  Object? handle;
  bool checking = false;

  @override
  void dispose() {
    if (handle != null)
      widget.state.cancelPreparation(widget.group, handle: handle);
    super.dispose();
  }

  Future<void> _start() async {
    final s = widget.state, g = widget.group;
    if (checking || s.groupOperationBusy(g)) return;
    setState(() => checking = true);
    try {
      await withWalletUse(
        context,
        s,
        owner: g,
        label: g.name,
        addresses: g.selectedWallets.map((w) => w.address),
        action: () async {
          final done = s.prepareRapid(g);
          handle = s.operationHandle(g);
          final checked = await done;
          if (!mounted || !identical(handle, s.operationHandle(g))) return;
          final p = checked.plan, token = s.preparedToken(g)!;
          final confirmed = await showUiDialog<bool>(
            context: context,
            builder: (c) => UiDialog(
              title: const Text('确认快速交易'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TradeTokenWarning(symbol: token.symbol, address: token.address),
                  const SizedBox(height: 12),
                  tradeReviewLine(
                    t(c, 'wallets'),
                    '${p.wallets.length} 个 · ${p.direction.label}',
                  ),
                  if (p.direction != RapidDirection.sell)
                    tradeReviewLine('每笔买入', '${formatUnits(p.buyAmount, 18, maxFraction: 18)} BNB'),
                  if (p.direction != RapidDirection.buy)
                    tradeReviewLine(
                      '每笔卖出',
                      '${p.percentSell ? formatUnits(p.sellValue, 2) : formatUnits(p.sellValue, token.decimals!, maxFraction: token.decimals!)} ${p.percentSell ? '%' : token.symbol}',
                    ),
                  if (p.percentSell && p.direction != RapidDirection.buy)
                    const Text('比例按该钱包当笔实际持仓计算。', style: muted),
                  tradeReviewLine('交易总数', '${p.total} 笔'),
                  if (checked.remainingCount < p.total)
                    tradeReviewLine('继续执行', '剩余 ${checked.remainingCount} 笔'),
                  tradeReviewLine('交易间隔', '${g.interval} 秒'),
                  if (p.minNative > BigInt.zero || p.minToken > BigInt.zero)
                    tradeReviewLine('停止线', '${g.minNative} BNB / ${g.minToken} ${token.symbol}'),
                  const Divider(height: 16, color: UiStyle.border),
                  tradeReviewLine('网络费单价', '${formatUnits(checked.gasPrice, 9, maxFraction: 9)} Gwei'),
                  tradeReviewLine('买卖网络费上限', '${formatUnits(checked.maximumGasCost, 18, maxFraction: 18)} BNB'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(t(c, 'cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('确认开始'),
                ),
              ],
            ),
          );
          if (!mounted ||
              confirmed != true ||
              !identical(handle, s.operationHandle(g)))
            return;
          await s.startRapid(g, checked);
        },
      );
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (handle != null) s.cancelPreparation(g, handle: handle);
      handle = null;
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state, g = widget.group;
    final blocked =
        checking ||
        g.running ||
        s.groupOperationBusy(g) ||
        g.trader.unresolved.isNotEmpty || g.trader.pendingRemainderHashes.isNotEmpty;
    final token = s.token;
    Widget field(
      String name,
      String value,
      String unit,
      ValueChanged<String> save,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Text(name, style: label)),
        const SizedBox(height: 4),
        Semantics(
          label: name,
          child: TextFormField(
            key: ValueKey(name + unit),
            initialValue: value,
            enabled: !blocked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(suffixText: unit),
            onChanged: save,
          ),
        ),
      ],
    );
    Widget fieldGrid(List<Widget> fields) => LayoutBuilder(
      builder: (_, constraints) {
        const gap = 12.0;
        final width = constraints.maxWidth < 292
            ? constraints.maxWidth
            : ((constraints.maxWidth - gap) / 2).clamp(140.0, 170.0).toDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final field in fields) SizedBox(width: width, child: field),
          ],
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t(context, 'trade_settings'), style: strong),
        const SizedBox(height: 12),
        TradeControlField(
          text: t(context, 'direction'),
          child: OptionPair<RapidDirection>(
            compact: true,
            options: [for (final d in RapidDirection.values) (d, d.label)],
            styles: const [OptionStyle.buy, OptionStyle.sell, OptionStyle.accent],
            value: g.direction,
            onChanged: blocked ? null : (d) => g.update((_) => g.direction = d),
          ),
        ),
        if (g.direction != RapidDirection.buy) ...[
          const SizedBox(height: 8),
          TradeControlField(
            text: '卖出方式',
            child: OptionPair<bool>(
              compact: true,
              options: const [(true, '比例'), (false, '数量')],
              value: g.percentSell,
              onChanged: blocked ? null : (v) => g.update((_) => g.percentSell = v),
            ),
          ),
        ],
        const SizedBox(height: 12),
        fieldGrid([
          if (g.direction != RapidDirection.sell)
            field('每笔买入', g.buyAmount, 'BNB', (v) => g.buyAmount = v),
          if (g.direction != RapidDirection.buy)
            g.percentSell
                ? field('每笔卖出', g.sellPercent, '%', (v) => g.sellPercent = v)
                : field('每笔卖出', g.sellAmount, token?.symbol ?? '代币', (v) => g.sellAmount = v),
        ]),
        const Divider(height: 24, color: UiStyle.border),
        fieldGrid([
          field('交易间隔', g.interval, '秒', (v) => g.interval = v),
          field('交易总数', g.total, '笔', (v) => g.total = v),
        ]),
        const SizedBox(height: 14),
        fieldGrid([
          field('BNB 停止线', g.minNative, 'BNB', (v) => g.minNative = v),
          field('代币停止线', g.minToken, token?.symbol ?? '代币', (v) => g.minToken = v),
        ]),
        const SizedBox(height: 6),
        const Text('任一钱包低于停止线时停止整组（0 不限制）', style: muted),
        const Divider(height: 24, color: UiStyle.border),
        if (g.direction != RapidDirection.buy)
          Text(t(context, 'approval_check_hint'), style: muted),
        if (g.running)
          SmallButton(label: '停止', onPressed: g.cancel)
        else if (s.groupOperationBusy(g))
          SmallButton(
            label: '取消检查',
            onPressed: () => s.cancelPreparation(g, handle: handle),
          )
        else if (g.trader.unresolved.isNotEmpty || g.trader.pendingRemainderHashes.isNotEmpty)
          SmallButton(
            label: '查询原交易',
            onPressed: () async {
              try {
                await s.query(g);
              } catch (e) {
                if (context.mounted) await showError(context, e);
              }
            },
          )
        else
          PrimaryButton(
            label: '检查并准备',
            onPressed: token != null && g.selected.isNotEmpty && !checking
                ? _start
                : null,
          ),
        if (g.trader.last case final out?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '已提交 ${out.tradeHashes.length} · 已确认 ${out.confirmed} · 待核实 ${g.trader.unresolved.length} · 失败 ${out.failed}',
              style: muted,
            ),
          ),
      ],
    );
  }
}
