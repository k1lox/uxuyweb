import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../exec/holding_ratio.dart';
import 'clipboard_feedback.dart';
import 'widgets.dart';

class HoldingRatioPage extends StatefulWidget {
  const HoldingRatioPage({super.key, required this.api, required this.active});
  final BackendClient api;
  final bool active;
  @override
  State<HoldingRatioPage> createState() => _HoldingRatioPageState();
}

class _HoldingRatioPageState extends State<HoldingRatioPage>
    with WidgetsBindingObserver {
  final _token = TextEditingController(),
      _addresses = TextEditingController(),
      _pools = TextEditingController();
  HoldingSnapshot? _snapshot;
  TimeOfDay? _checkedAt;
  String? _error;
  bool _busy = false, _auto = false, _visible = true;
  int _revision = 0, _page = 0;
  Timer? _timer;
  DateTime? _nextRefresh;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _revision++;
    _token.dispose();
    _addresses.dispose();
    _pools.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (widget.active && _auto && _visible && !_busy) {
      final delay =
          _nextRefresh?.difference(DateTime.now()) ??
          const Duration(minutes: 1);
      _timer = Timer(
        delay.isNegative ? Duration.zero : delay,
        () => _read(automatic: true),
      );
    }
  }

  @override
  void didUpdateWidget(HoldingRatioPage previous) {
    super.didUpdateWidget(previous);
    if (previous.active != widget.active) {
      _revision++;
      _busy = false;
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (!_visible) {
      _revision++;
      if (mounted && _busy) setState(() => _busy = false);
    }
    _schedule();
  }

  void _edit(String _) {
    _timer?.cancel();
    _revision++;
    setState(() {
      _busy = false;
      _auto = false;
      _snapshot = null;
      _error = null;
      _page = 0;
    });
  }

  Future<void> _read({bool automatic = false}) async {
    if (_busy || !widget.active || !_visible) return;
    final revision = ++_revision;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      if (!automatic) {
        _auto = false;
        _snapshot = null;
        _page = 0;
      }
    });
    try {
      final result = await readHoldingRatio(
        widget.api,
        _token.text,
        _addresses.text,
        _pools.text,
      );
      if (mounted && revision == _revision)
        setState(() {
          _snapshot = result;
          _checkedAt = TimeOfDay.now();
          if (!automatic) _auto = true;
        });
    } catch (e) {
      if (mounted && revision == _revision)
        setState(() => _error = uiErrorText(e));
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _busy = false);
        _nextRefresh = DateTime.now().add(const Duration(minutes: 1));
        _schedule();
      }
    }
  }

  Future<void> _editAddressList(
    TextEditingController field,
    String title,
  ) async {
    var draft = field.text;
    final saved = await showUiDialog<String>(
      context: context,
      builder: (dialogContext) => UiDialog(
        title: Text(title),
        width: 680,
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 5,
          maxLines: 12,
          style: mono,
          decoration: const InputDecoration(hintText: '每行一个公开地址'),
          onChanged: (value) => draft = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t(context, 'cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: Text(t(context, 'save')),
          ),
        ],
      ),
    );
    if (mounted && saved != null && field.text != saved) {
      field.text = saved;
      _edit(saved);
    }
  }

  Widget _expandList(TextEditingController field, String title) => IconButton(
    tooltip: '展开编辑$title',
    onPressed: () => _editAddressList(field, title),
    icon: const Icon(Icons.open_in_full, size: 16),
  );

  @override
  Widget build(BuildContext context) {
    final r = _snapshot;
    final content = ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Panel(
          title: '查询条件',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('代币合约地址', style: label),
              const SizedBox(height: 6),
              InputBox(
                controller: _token,
                address: true,
                hint: '0x…',
                onChanged: _edit,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Flexible(child: Text('钱包公开地址', style: label)),
                  const SizedBox(width: 4),
                  _expandList(_addresses, '钱包公开地址'),
                ],
              ),
              TextField(
                controller: _addresses,
                onChanged: _edit,
                minLines: 2,
                maxLines: 5,
                style: mono,
                decoration: const InputDecoration(hintText: '每行一个公开地址'),
              ),
              _disclosure(
                title: const Text('补充流动性池'),
                tilePadding: EdgeInsets.zero,
                children: [
                  TextField(
                    controller: _pools,
                    onChanged: _edit,
                    minLines: 1,
                    maxLines: 4,
                    style: mono,
                    decoration: InputDecoration(
                      hintText: '每行一个池地址',
                      suffixIcon: _expandList(_pools, '补充池地址'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PrimaryButton(
                    label: '查询控盘率',
                    busy: _busy,
                    onPressed:
                        _token.text.trim().isEmpty ||
                            _addresses.text.trim().isEmpty
                        ? null
                        : () => _read(),
                  ),
                  if (_busy)
                    TextButton(
                      onPressed: () {
                        _revision++;
                        _timer?.cancel();
                        setState(() {
                          _busy = false;
                          _auto = false;
                        });
                      },
                      child: const Text('取消查询'),
                    ),
                  if (r != null && !_busy)
                    TextButton(
                      onPressed: () {
                        setState(() => _auto = !_auto);
                        _schedule();
                      },
                      child: Text(_auto ? '暂停每分钟刷新' : '启用每分钟刷新'),
                    ),
                ],
              ),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: SelectableText(
                    r == null ? _error! : '刷新失败，显示上次查询结果。\n$_error',
                    style: const TextStyle(color: UiStyle.negative),
                  ),
                ),
            ],
          ),
        ),
        if (r != null) ...[
          const SizedBox(height: 12),
          Panel(
            title: '${r.symbol} · 区块 ${r.block}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('控盘率  ${r.percent ?? '暂不可计算'}',
                      style: sectionTitle),
                    Text('查询时间  ${_checkedAt!.format(context)}', style: muted),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(builder: (context, size) {
                  final width = size.maxWidth >= 560 ? (size.maxWidth - 20) / 2 : size.maxWidth;
                  return Wrap(spacing: 20, runSpacing: 8, children: [
                    for (final (name, amount) in [
                      ('持仓', r.held), ('总供应量', r.totalSupply),
                      ('已核实池内余额', r.poolBalance), ('流通量', r.reason == null ? r.circulating : null),
                    ])
                      SizedBox(width: width, child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 94, child: Text(name, style: muted)),
                          Expanded(child: SelectableText(
                            amount == null ? '待核实' :
                              '${formatUnits(amount, r.decimals, maxFraction: r.decimals)} ${r.symbol}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          )),
                        ],
                      )),
                  ]);
                }),
                const SizedBox(height: 8),
                if (r.circulating == BigInt.zero && r.reason == null)
                  const Text('流通量为 0，暂时无法计算持仓占比'),
                if (r.reason != null)
                  Text(
                    r.reason!,
                    style: const TextStyle(color: UiStyle.negative),
                  ),
                for (final text in r.warnings) Text(text, style: muted),
                _disclosure(
                  tilePadding: EdgeInsets.zero,
                  title: Text('流动性池 · ${r.pools.length}'),
                  children: [
                    for (final p in r.pools) _row(p, r.decimals, r.symbol),
                  ],
                ),
                _disclosure(
                  tilePadding: EdgeInsets.zero,
                  title: Text('钱包明细 · ${r.wallets.length}'),
                  children: [
                    for (final w in r.wallets.skip(_page * 50).take(50))
                      _row(w, r.decimals, r.symbol),
                    if (r.wallets.length > 50)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _page == 0
                                ? null
                                : () => setState(() => _page--),
                            child: const Text('上一页'),
                          ),
                          Text(
                            '${_page + 1}/${math.max(1, (r.wallets.length + 49) ~/ 50)}',
                          ),
                          TextButton(
                            onPressed: (_page + 1) * 50 >= r.wallets.length
                                ? null
                                : () => setState(() => _page++),
                            child: const Text('下一页'),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 832),
        child: content,
      ),
    );
  }

  Widget _disclosure({
    required Widget title,
    required EdgeInsetsGeometry tilePadding,
    required List<Widget> children,
  }) => Material(
    type: MaterialType.transparency,
    child: ExpansionTile(
      title: title,
      dense: true,
      minTileHeight: 44,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: tilePadding,
      children: children,
    ),
  );

  Widget _row(HoldingRow row, int decimals, String symbol) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(row.address, style: mono),
            Text(
              [
                if (row.label.isNotEmpty) row.label,
                '${formatUnits(row.balance, decimals, maxFraction: decimals)} $symbol',
              ].join(' · '),
              style: muted,
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: t(context, 'copy_address'),
        icon: const Icon(Icons.content_copy_outlined, size: 16),
        onPressed: () => ClipboardFeedback.copy(
          context,
          row.address,
          successLabel: t(context, 'copied'),
        ),
      ),
    ],
  );
}
