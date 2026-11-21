import 'package:flutter/material.dart';

import '../evm/evm.dart';
import '../exec/transfers.dart';
import '../exec/market.dart' show zeroAddress;
import '../exec/executor.dart' show parseGroupSeconds;
import '../state/app_state.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_backup.dart';
import 'batch_page.dart' show confirmExport;
import 'clipboard_feedback.dart';
import 'generated_wallet_list.dart';
import 'key_editor.dart';
import 'transfer_warmup.dart';
import 'widgets.dart';
import 'wallet_overlap.dart';

enum WalletTool { generate, distribute, collect }

/// Web wallet-tools: generate keys, distribute (one-to-many / many-to-many, optional relays), collect.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.state, this.active = true, this.showTabs = true});
  final bool active;
  final bool showTabs;
  final AppState state;
  @override
  ToolsPageState createState() => ToolsPageState();
}

class ToolsPageState extends State<ToolsPage> {
  WalletTool _tool = WalletTool.generate;
  WalletTool get selectedTool => _tool;

  bool selectTool(WalletTool next) {
    if (next == _tool) return true;
    if (locked) return false;
    setState(() {
      _tool = next;
      _invalidateBalance();
    });
    return true;
  }

  // generate
  final count = TextEditingController(text: '5');
  bool _generatingFromTools = false;
  final _uncheckedGenerated = Expando<Set<String>>();

  // distribute
  bool paired = false;
  String distKeys = '';
  final receivers = TextEditingController();
  bool distToken = false;
  final distTokenAddr = TextEditingController();
  final dMin = TextEditingController();
  final dMax = TextEditingController();
  bool pairedRatio = true;
  final pMin = TextEditingController(text: '100');
  final pMax = TextEditingController(text: '100');
  bool transit = true;
  final iMin = TextEditingController(text: '0');
  final iMax = TextEditingController(text: '0');
  List<Allocation>? allocation;
  TransferAsset? allocationAsset;
  TradeWallet? allocationSource;
  ({Object inputs, Stopwatch age, TransferRun run})? _warmReview;

  TransferRun? _takeWarmReview(Object inputs) {
    final review = _warmReview;
    _warmReview = null;
    return review != null && inputs == review.inputs && review.age.elapsed < const Duration(seconds: 15)
        ? review.run : null;
  }

  // collect
  String collectKeys = '';
  List<TradeWallet> _collectWallets = [];
  final target = TextEditingController();
  bool collectToken = false;
  final collectTokenAddr = TextEditingController();

  String? balanceText;
  ({TransferAsset asset, BigInt gas, List<(BigInt, BigInt)> balances})?
  _pairedBalance;

  String _rangePreview() {
    final data = _pairedBalance;
    if (data == null) return '预计合计 —';
    try {
      final digits = pairedRatio ? 2 : data.asset.decimals;
      final low = parseUnits(pMin.text, digits),
          high = parseUnits(
            pMax.text.trim().isEmpty ? pMin.text : pMax.text,
            digits,
          );
      if (low < BigInt.zero ||
          high < low ||
          high == BigInt.zero ||
          (pairedRatio && high > BigInt.from(10000)))
        return '预计合计 —';
      final keep = data.gas * BigInt.from(transit ? 42000 : 21000);
      BigInt sum(BigInt bound) =>
          data.balances.fold(BigInt.zero, (total, entry) {
            final available = data.asset.native
                ? (entry.$1 > keep ? entry.$1 - keep : BigInt.zero)
                : entry.$2;
            return total +
                (pairedRatio
                    ? available * bound ~/ BigInt.from(10000)
                    : bound < available
                    ? bound
                    : available);
          });
      String format(BigInt x) =>
          formatUnits(x, data.asset.decimals, maxFraction: data.asset.decimals);
      final lo = format(sum(low)), hi = format(sum(high));
      return '预计合计 ${lo == hi ? lo : '$lo–$hi'} ${data.asset.symbol}';
    } on FormatException {
      return '预计合计 —';
    }
  }

  int _balanceRevision = 0;
  bool working = false;

  @override
  void initState() {
    super.initState();
    for (final c in [target, iMin, iMax]) {
      c.addListener(_warmInputChanged);
    }
    final token = widget.state.token?.address ?? '';
    distTokenAddr.text = token;
    collectTokenAddr.text = token;
  }

  @override
  void dispose() {
    for (final c in [
      count,
      receivers,
      distTokenAddr,
      dMin,
      dMax,
      pMin,
      pMax,
      iMin,
      iMax,
      target,
      collectTokenAddr,
    ]) {
      c.dispose();
    }
    distKeys = '';
    collectKeys = '';
    super.dispose();
  }

  void _warmInputChanged() => setState(() {});

  TransferEngine get engine => widget.state.transfers;
  bool get locked => engine.running || working;

  Future<void> _do(Future<void> Function() f) async {
    setState(() => working = true);
    try {
      await f();
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void _invalidateBalance() {
    _balanceRevision++;
    balanceText = null;
    _pairedBalance = null;
  }

  void _edit(VoidCallback change, {bool keepBalance = false}) => setState(() {
    change();
    _warmReview = null;
    if (_tool == WalletTool.distribute) allocation = null;
    if (!keepBalance) _invalidateBalance();
  });

  void _setCollectionKeys(String keys) {
    if (keys == collectKeys) return;
    final parsed = _parse(keys, allowEmpty: true);
    _edit(() { collectKeys = keys; _collectWallets = parsed; });
  }

  Future<String?> _keys(
    String title,
    String initial,
    String backupCategory, {
    bool distribution = false,
  }) async {
    late String canonical;
    final saved = await Navigator.of(context).push<String>(
      KeyEditorRoute(
        context: context,
        settings: const RouteSettings(name: '/uxuy_trade/tool_keys'),
        builder: (_) => KeyEditorPage(
          title: title,
          initial: initial,
          backup: widget.state.walletBackup,
          backupCategory: backupCategory,
          singleWallet: distribution && !paired,
          onSave: (text) async {
            final wallets = _parse(
              text,
              distribution: distribution,
              allowEmpty: true,
            );
            canonical = formatPrivateKeyLines(wallets);
          },
        ),
      ),
    );
    return saved == null ? null : canonical;
  }

  List<TradeWallet> _parse(
    String keys, {
    bool distribution = false,
    bool allowEmpty = false,
  }) {
    final list = parsePrivateKeys(
      keys,
      existing: const {},
      startIndex: 0,
      maxCount: distribution && !paired ? 1 : 10000,
      rejectDuplicates: distribution && paired,
    );
    if (list.isEmpty && !allowEmpty) throw const FormatException('请输入私钥');
    return list;
  }

  int _count(String keys) =>
      keys.split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty).length;

  Future<void> _copy(String text) =>
      ClipboardFeedback.copy(context, text, successLabel: t(context, 'copied'));

  bool _containsGenerated(List<TradeWallet>? wallets) =>
      wallets == null || widget.state.generatedBatches.any((b) => identical(b.wallets, wallets));

  Future<void> _copyKeys(
    List<TradeWallet> list, {
    List<TradeWallet>? generatedBatch,
  }) async {
    final copied = List<TradeWallet>.of(list);
    await ClipboardFeedback.confirmed(
      context,
      confirm: () async {
        if (await confirmExport(context) != true || !mounted) return false;
        return _containsGenerated(generatedBatch);
      },
      text: () => formatPrivateKeyLines(copied),
      onCopied: () => widget.state.markKeysCopied(copied),
      successLabel: t(context, 'exported'),
    );
  }

  Widget _download(
    List<TradeWallet> wallets,
    String scope, {
    List<TradeWallet>? generatedBatch,
  }) => PopupMenuButton<bool>(
    tooltip: '下载 TXT',
    enabled: wallets.isNotEmpty,
    icon: const Icon(Icons.download_outlined),
    itemBuilder: (context) => const [
      PopupMenuItem(value: false, child: Text('下载公开地址 TXT')),
      PopupMenuItem(value: true, child: Text('下载私钥 TXT')),
    ],
    onSelected: (secret) async {
      final selected = List<TradeWallet>.of(wallets);
      if (secret && await confirmExport(context) != true) return;
      if (!mounted || !_containsGenerated(generatedBatch)) return;
      final lines = secret
          ? formatPrivateKeyLines(selected)
          : selected.map((w) => w.address).join('\n');
      widget.state.downloadText!(
        '${scope}_${secret ? '私钥' : '地址'}_${DateTime.now().millisecondsSinceEpoch}.txt',
        '$lines\n',
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) => LayoutBuilder(builder: (context, bounds) {
        final batches = widget.state.generatedBatches;
        final columns = bounds.maxWidth >= 740 ? 2 : 1;
        final groupRows = _tool == WalletTool.generate
            ? (batches.length + columns - 1) ~/ columns
            : 0;
        final formIndex = widget.showTabs ? 1 : 0;
        return ListView.builder(
          key: PageStorageKey<WalletTool>(_tool),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          itemCount: formIndex + 1 + groupRows,
          itemBuilder: (context, index) {
            if (widget.showTabs && index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: SubTabs<WalletTool>(
                      options: [
                        for (final tool in WalletTool.values) (tool, t(context, tool.name)),
                      ],
                      value: _tool,
                      onChanged: locked ? null : selectTool,
                    ),
                  ),
                ),
              );
            }
            if (index == formIndex) {
              return switch (_tool) {
                WalletTool.generate => _generate(context),
                WalletTool.distribute => _distribute(context),
                WalletTool.collect => _collect(context),
              };
            }

            final first = (index - formIndex - 1) * columns;
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _generatedGroup(context, batches[first], batches.last.wallets)),
                  if (columns == 2) ...[
                    const SizedBox(width: 16),
                    Expanded(
                      child: first + 1 < batches.length
                          ? _generatedGroup(context, batches[first + 1], batches.last.wallets)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      }),
    );
  }

  // ------------------------------------------------------------------ generate

  Future<void> _startGenerating() async {
    final s = widget.state;
    final target = int.tryParse(count.text) ?? 0;
    await _do(() async {
      _generatingFromTools = true;
      try {
        final backup = s.walletBackup;
        if (backup != null) {
          await backup.checkAccess();
          if (!backup.connected) {
            throw StateError(backup.errorMessage ?? '请先连接可写的本地备份目录');
          }
        }
        final created = await s.generate(target);
        if (backup != null && created.any((w) => !w.canReceiveFunds)) {
          throw StateError(backup.errorMessage ?? '新钱包私钥尚未通过写入回查');
        }
        if (mounted && created.length < target) {
          showNotice(context, "${t(context, 'st_stopped')} · ${t(context, 'generated')} ${created.length} / $target");
        }
      } finally {
        _generatingFromTools = false;
      }
    });
  }

  Widget _generate(BuildContext context) {
    final s = widget.state;
    final generating = s.generatingWallets;
    final backingUp = _generatingFromTools && !generating && (s.walletBackup?.pendingCount ?? 0) > 0;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(t(context, 'count'), style: label),
        SizedBox(
          width: 104,
          child: InputBox(controller: count, number: true, enabled: !generating && !_generatingFromTools),
        ),
        if (generating)
          PrimaryButton(
            label: t(context, 'stop_generation'),
            onPressed: s.stoppingWalletGeneration ? null : s.stopGeneratingWallets,
          )
        else
          PrimaryButton(
            label: t(context, backingUp ? 'backing_up_wallets' : 'generate_action'),
            busy: !backingUp && (s.busy || working),
            onPressed: backingUp ? null : _startGenerating,
          ),
        if (generating)
          Text(
            "${t(context, 'generated')} ${s.generatedWalletCount} / ${s.generationTarget}",
            style: muted,
          ),
      ],
    );
  }

  Future<void> _renameGroup(GeneratedWalletBatch batch) async {
    final controller = TextEditingController(text: batch.name);
    controller.selection = TextSelection(baseOffset: 0, extentOffset: batch.name.length);
    try {
      final name = await showUiDialog<String>(
        context: context,
        builder: (c) => UiDialog(
          width: 360,
          title: const Text('修改组名'),
          content: TextField(
            autofocus: true,
            controller: controller,
            decoration: const InputDecoration(labelText: '组名'),
            onSubmitted: (value) => Navigator.pop(c, value),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(t(c, 'cancel'))),
            TextButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(t(c, 'save'))),
          ],
        ),
      );
      if (mounted && name != null && name.trim() != batch.name) {
        await _do(() => widget.state.renameGeneratedBatch(batch, name));
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteGroup(GeneratedWalletBatch batch) async {
    final name = batch.name;
    Future<void>? saving;
    await showUiDialog<void>(
      context: context,
      builder: (c) => UiDialog(
        title: Text(t(c, 'delete_wallet_group')),
        width: 400,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("$name · ${batch.wallets.length} ${t(c, 'wallets_unit')}", style: strong),
            const SizedBox(height: 8),
            Text(t(c, 'delete_wallet_group_hint')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(t(c, 'cancel'))),
          TextButton(
            onPressed: () {
              // Register the pending disk write before the dialog's exit animation.
              if (name == batch.name) {
                saving ??= _do(() => widget.state.deleteGeneratedBatch(batch));
              }
              Navigator.pop(c);
            },
            child: Text(t(c, 'confirm_remove')),
          ),
        ],
      ),
    );
    await saving;
  }

  Widget _generatedGroup(BuildContext context, GeneratedWalletBatch batch, List<TradeWallet> newest) {
    final s = widget.state;
    final list = batch.wallets;
    final unbacked = list.where((w) => !w.canReceiveFunds).length;
    final pending = s.walletBackup != null && unbacked > 0;
    final unchecked = _uncheckedGenerated[list] ??= <String>{};
    final selected = list.where((w) => !unchecked.contains(w.address)).toList(growable: false);
    final allSelected = selected.length == list.length;
    void toggleAll() => setState(() {
      if (allSelected) {
        unchecked.addAll(list.map((w) => w.address));
      } else {
        unchecked.clear();
      }
    });
    return Panel(
      key: ObjectKey(list),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(batch.name, style: panelTitle)),
                  IconButton(
                    tooltip: '修改组名',
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    onPressed: working || pending || s.walletBackup?.connected == false
                        ? null : () => _renameGroup(batch),
                  ),
                  IconButton(
                    tooltip: t(context, 'delete_group_action'),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    onPressed: working || unbacked > 0 || s.walletBackup?.connected == false
                        ? null : () => _deleteGroup(batch),
                  ),
                ],
              ),
              Text("${t(context, 'generated')} ${list.length}", style: muted),
              if (!pending)
                Text(
                  unbacked > 0 ? "$unbacked ${t(context, 'not_backed_up')}" : t(context, 'backed_up'),
                  style: muted.copyWith(color: unbacked > 0 ? UiStyle.negative : UiStyle.positive),
                ),
            ],
          ),
          if (pending)
            const Text('等待本批私钥写入并回查', style: muted)
          else ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const ValueKey('generated-select-all'),
                      semanticLabel: t(context, 'select_all'),
                      visualDensity: VisualDensity.compact,
                      tristate: true,
                      value: selected.isEmpty || allSelected ? allSelected : null,
                      onChanged: (_) => toggleAll(),
                    ),
                    InkWell(
                      excludeFromSemantics: true,
                      canRequestFocus: false,
                      onTap: toggleAll,
                      child: Text(t(context, 'select_all'), style: label),
                    ),
                  ],
                ),
                Text("${t(context, 'selected')} ${selected.length}/${list.length}", style: muted),
              ],
            ),
            GeneratedWalletList(
              // A fresh generation closes any previously revealed private key.
              key: ObjectKey(newest),
              wallets: list,
              unchecked: unchecked,
              onCheckChanged: (wallet, checked) => setState(() {
                if (checked) {
                  unchecked.remove(wallet.address);
                } else {
                  unchecked.add(wallet.address);
                }
              }),
              onKeyCopied: (wallet) => s.markKeysCopied([wallet]),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (s.downloadText != null)
                  _download(selected, '生成钱包', generatedBatch: list),
                SmallButton(
                  label: t(context, 'copy_selected_addresses'),
                  onPressed: selected.isEmpty ? null : () => _copy(selected.map((w) => w.address).join('\n')),
                ),
                SmallButton(
                  label: t(context, 'copy_selected_keys'),
                  onPressed: selected.isEmpty ? null : () => _copyKeys(selected, generatedBatch: list),
                ),
              ],
            ),
            if (unbacked > 0) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t(context, 'backup_rule'), style: muted),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ distribute

  Future<TransferAsset> _asset(bool token, TextEditingController address) =>
      engine.asset(token ? address.text : null);

  Future<void> _readBalance({
    required String keys,
    required bool token,
    required TextEditingController address,
    bool distribution = false,
  }) async {
    final revision = ++_balanceRevision;
    if (balanceText != null || _pairedBalance != null)
      setState(() {
        balanceText = null;
        _pairedBalance = null;
      });
    final wallets = _parse(keys, distribution: distribution);
    try {
      final asset = await _asset(token, address);
      if (!mounted || revision != _balanceRevision) return;
      final states = await widget.state.api.transferWalletStates(
        [for (final w in wallets) w.address],
        token: asset.address,
        refresh: true,
      );
      if (!mounted || revision != _balanceRevision) return;
      if (distribution && paired) {
        final gas = await widget.state.api.gas();
        if (!mounted || revision != _balanceRevision) return;
        _pairedBalance = (
          asset: asset,
          gas: gas.gasPrice,
          balances: [
            for (final state in states)
              (state.native, state.tokenBalance ?? BigInt.zero),
          ],
        );
      }
      final bnb = states.fold(BigInt.zero, (a, s) => a + s.native);
      final amount = asset.native
          ? bnb
          : states.fold(
              BigInt.zero,
              (a, s) => a + (s.tokenBalance ?? BigInt.zero),
            );
      setState(
        () => balanceText =
            '${formatUnits(amount, asset.decimals, maxFraction: asset.decimals)} ${asset.symbol}'
            '${asset.native ? '' : ' · ${formatUnits(bnb, 18, maxFraction: 18)} BNB'}',
      );
    } catch (_) {
      if (mounted && revision == _balanceRevision) rethrow;
    }
  }

  Future<void> _apply() async {
    final s = widget.state;
    final recipients = parseRecipients(
      receivers.text,
      rejectDuplicates: paired,
    );
    if (recipients.length > 10000) {
      throw const FormatException('请填写 1–10000 个接收地址');
    }
    final senders = _parse(distKeys, distribution: true);
    final asset = await _asset(distToken, distTokenAddr);
    final transits = transit ? await s.transitsFor(recipients) : null;
    List<Allocation> rows;
    if (paired) {
      final lo = parseUnits(pMin.text, pairedRatio ? 2 : asset.decimals);
      final hi = parseUnits(
        pMax.text.trim().isEmpty ? pMin.text : pMax.text,
        pairedRatio ? 2 : asset.decimals,
      );
      rows = await engine.drawPaired(
        senders,
        recipients,
        asset,
        ratio: pairedRatio,
        min: lo,
        max: hi,
        transits: transits,
      );
    } else {
      final lo = parseUnits(dMin.text, asset.decimals);
      final hi = parseUnits(
        dMax.text.trim().isEmpty ? dMin.text : dMax.text,
        asset.decimals,
      );
      rows = engine.drawOneToMany(
        senders.first,
        recipients,
        lo,
        hi,
        transits: transits,
      );
    }
    setState(() {
      allocation = rows;
      allocationAsset = asset;
      allocationSource = senders.first;
    });
  }

  Widget _warmTransfer({required bool distribution}) {
    if (!widget.active || locked) return const SizedBox.shrink();
    final rows = allocation;
    final source = allocationSource;
    final distributionAsset = allocationAsset;
    final low = parseGroupSeconds(iMin.text), high = parseGroupSeconds(iMax.text);
    final recipient = target.text.trim();
    final token = collectToken ? collectTokenAddr.text.trim() : null;
    if (distribution
        ? rows == null || source == null || distributionAsset == null ||
          !rows.any((r) => r.amount > BigInt.zero) || low == null || high == null || low > high
        : _collectWallets.isEmpty || !isAddress(recipient) || recipient.toLowerCase() == zeroAddress ||
          token != null && (!isAddress(token) || token.toLowerCase() == zeroAddress)) {
      return const SizedBox.shrink();
    }
    final Object inputs = distribution ? (rows, source, low, high, distributionAsset) : (_collectWallets, recipient, token);
    return TransferWarmup(
      identity: inputs,
      interval: Duration(seconds: distribution ? 10 : 5),
      prepare: (check) async {
        final age = Stopwatch()..start();
        _warmReview = null;
        final TransferRun run;
        if (distribution) {
          run = await engine.prepareDistribution(rows!, distributionAsset!, source: source!,
            intervalMin: low!, intervalMax: high!, unbacked: widget.state.unbackedAddresses, checkPreview: check);
        } else {
          final sources = _collectWallets;
          final asset = await engine.asset(token);
          check();
          run = await engine.prepareCollection(sources, recipient, asset, checkPreview: check);
        }
        check();
        _warmReview = (inputs: inputs, age: age, run: run);
        return '本次预计 ${formatUnits(run.total, run.asset.decimals, maxFraction: run.asset.decimals)} ${run.asset.symbol}';
      },
    );
  }

  Future<void> _startDistribute() async {
    final s = widget.state;
    final rows = allocation;
    final asset = allocationAsset;
    if (rows == null || asset == null) {
      throw StateError(t(context, 'need_apply'));
    }
    await _ensureTransitBackup(rows);
    if (!mounted) return;
    final iLo = parseGroupSeconds(iMin.text),
        iHi = parseGroupSeconds(iMax.text);
    if (iLo == null || iHi == null)
      throw const FormatException('间隔可填 0 至 86400 秒，最多三位小数');
    final source = allocationSource!;
    Future<TransferRun> prepare() => engine.prepareDistribution(
      rows,
      asset,
      source: source,
      intervalMin: iLo,
      intervalMax: iHi,
      unbacked: s.unbackedAddresses,
    );
    final run = _takeWarmReview((rows, source, iLo, iHi, asset)) ?? await prepare();
    if (mounted) {
      setState(() => allocation = run.rows);
      await _executeTransfer(run, prepare: prepare);
    }
  }

  Future<void> _executeTransfer(TransferRun run, {bool retry = false, Future<TransferRun> Function()? prepare}) =>
      withWalletUse(
        context,
        widget.state,
        owner: run,
        label: run.label,
        addresses: {
          for (final leg in run.legs)
            if (leg.status != TransferStatus.confirmed &&
                leg.status != TransferStatus.skipped) ...[
              leg.from.address,
              leg.recipient,
            ],
        },
        action: () async {
          final backup = widget.state.walletBackup;
          if (backup != null) {
            final sources = {
              for (final leg in run.legs)
                if (leg.status != TransferStatus.confirmed &&
                    leg.status != TransferStatus.skipped &&
                    run.rows[leg.row].transit?.address != leg.from.address)
                  leg.from,
            };
            await Future.wait([
              backup.requireStoredIfConnected(
                run.label == '归集'
                    ? WalletBackupCategory.toolCollectionSource
                    : WalletBackupCategory.toolDistributionSource,
                sources,
              ),
              if (retry) _ensureTransitBackup(run.rows),
            ]);
            if (!mounted) return;
          }
          if (!retry && !await _confirm(run)) return;
          if (!mounted) return;
          if (retry) {
            await engine.execute(run);
          } else {
            final fresh = await prepare!();
            if (!mounted) return;
            if (!run.covers(fresh)) throw StateError('转账金额、接收地址或网络费已变化，请重新确认');
            await engine.execute(fresh);
          }
        },
      );

  Future<void> _ensureTransitBackup(List<Allocation> rows) async {
    final backup = widget.state.walletBackup;
    if (backup == null) return;
    final transits = {
      for (final row in rows)
        if (row.transit != null) row.recipient: row.transit!,
    };
    if (transits.isNotEmpty) {
      await backup.requireTransitsStoredIfConnected(
        WalletBackupCategory.distributionTransit,
        transits,
      );
    }
  }

  Future<bool> _confirm(TransferRun run) async {
    final fees =
        run.legs.fold(BigInt.zero, (a, l) => a + BigInt.from(l.gasLimit)) *
        run.gasPrice;
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: Text(run.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${run.rows.length} ${t(c, 'addresses_unit')} · ${run.legs.length} ${t(c, 'legs')}',
            ),
            const SizedBox(height: 4),
            Text(
              '${t(c, 'total')} ${formatUnits(run.total, run.asset.decimals, maxFraction: run.asset.decimals)} ${run.asset.symbol}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${t(c, 'network_fee')} ≤ ${formatUnits(fees, 18, maxFraction: 18)} BNB',
              style: muted,
            ),
            const SizedBox(height: 8),
            Text(t(c, 'confirm_transfer_hint'), style: muted),
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
    return ok == true;
  }

  Iterable<TransferRun> _visibleRuns({required bool collection}) sync* {
    final current = engine.current;
    if (current != null &&
        ((current.label == '归集') == collection || current.hasUnknown)) {
      yield current;
    }
    yield* engine.retainedRuns;
  }

  Widget _runPanel(TransferRun run) => _RunPanel(
    key: ObjectKey(run),
    state: widget.state,
    run: run,
    onRetry: () => _do(() => _executeTransfer(run, retry: true)),
  );

  Widget _distribute(BuildContext context) {
    final s = widget.state;
    final unit = distToken ? t(context, 'token') : 'BNB';
    final rows = allocation;
    final applyLabel = t(context, 'apply');
    final apply = locked ? null : () => _do(_apply);
    final busyRun =
        engine.current != null &&
        engine.current!.label != '归集' &&
        !engine.current!.complete &&
        !engine.current!.hasUnknown;
    final configuration = Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OptionPair<bool>(
            compact: true,
            options: [
              (false, t(context, 'one_to_many')),
              (true, t(context, 'many_to_many')),
            ],
            value: paired,
            onChanged: locked ? null : (v) => _edit(() => paired = v),
          ),
          if (paired)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t(context, 'paired_hint'), style: muted),
            ),
          const SizedBox(height: 12),
          _KeyField(
            label: t(context, 'distributor_keys'),
            summary: distKeys.isEmpty
                ? t(context, 'not_filled')
                : (paired
                      ? '${_count(distKeys)} ${t(context, 'keys_unit')}'
                      : _firstAddress(distKeys)),
            onTap: locked
                ? null
                : () async {
                    final v = await _keys(
                      t(context, 'distributor_keys'),
                      distKeys,
                      WalletBackupCategory.toolDistributionSource,
                      distribution: true,
                    );
                    if (v != null) _edit(() => distKeys = v.trim());
                  },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${t(context, 'receivers')}${receivers.text.trim().isEmpty ? '' : ' · ${_lines(receivers.text)}'}',
                style: label,
              ),
              if (s.groups.isNotEmpty)
                UiMenu<GroupBase>(
                  enabled: !locked,
                  onSelected: (g) => _edit(
                    () => receivers.text = [
                      for (final w in g.allWallets) w.address,
                    ].join('\n'),
                  ),
                  options: [
                    for (final g in s.groups)
                      (g, '${g.name} · ${g.allWallets.length}'),
                  ],
                  child: Text(t(context, 'load_group')),
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: receivers,
            enabled: !locked,
            minLines: 3,
            maxLines: 8,
            style: mono,
            onChanged: (_) => _edit(() {}),
            decoration: InputDecoration(
              hintText: t(context, 'one_address_per_line'),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 12),
          _assetRow(
            context,
            distToken,
            distTokenAddr,
            (v) => _edit(() => distToken = v),
            onRefresh: () => _do(
              () => _readBalance(
                keys: distKeys,
                token: distToken,
                address: distTokenAddr,
                distribution: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (paired) ...[
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  t(context, 'per_wallet_distribute'),
                  style: const TextStyle(fontSize: 14),
                ),
                OptionPair<bool>(
                  compact: true,
                  options: [
                    (true, t(context, 'ratio')),
                    (false, t(context, 'quantity')),
                  ],
                  value: pairedRatio,
                  onChanged: locked
                      ? null
                      : (v) => _edit(() {
                          pairedRatio = v;
                          pMin.text = v ? '100' : '';
                          pMax.text = pMin.text;
                        }, keepBalance: true),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ShortField(
              child: RangeRow(
                min: pMin,
                max: pMax,
                unit: pairedRatio ? '%' : unit,
                onMin: (_) => _edit(() {}, keepBalance: true),
                onMax: (_) => _edit(() {}, keepBalance: true),
              ),
            ),
          ] else ...[
            Text(t(context, 'per_address'), style: label),
            const SizedBox(height: 6),
            _ShortField(
              child: RangeRow(
                min: dMin,
                max: dMax,
                unit: unit,
                onMin: (_) => _edit(() {}, keepBalance: true),
                onMax: (_) => _edit(() {}, keepBalance: true),
              ),
            ),
          ],
          const SizedBox(height: 6),
          if (paired) Text(_rangePreview(), style: label),
          Text(
            t(context, paired ? 'apply_hint_paired' : 'apply_hint_single'),
            style: muted,
          ),
          const SizedBox(height: 8),
          _ShortField(
            maxWidth: 420,
            child: Labeled(
              text: t(context, 'interval'),
              child: RangeRow(
                min: iMin,
                max: iMax,
                unit: t(context, 'seconds'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: transit,
                    onChanged: locked
                        ? null
                        : (v) => _edit(
                            () => transit = v ?? false,
                            keepBalance: true,
                          ),
                  ),
                  Flexible(
                    child: Text(
                      t(context, 'relay_distribution'),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
              if (transit)
                TextButton(
                  onPressed: locked
                      ? null
                      : () async {
                          final restored = await Navigator.of(context)
                              .push<String>(
                                KeyEditorRoute(
                                  context: context,
                                  builder: (_) => KeyEditorPage(
                                    title: '恢复中转备份',
                                    expectedRecipients: receivers.text,
                                    onRestoreTransits:
                                        (backup, recipients) async {
                                          await s.restoreTransits(
                                            backup,
                                            recipients,
                                          );
                                        },
                                  ),
                                ),
                              );
                          if (mounted && restored != null) _edit(() {});
                        },
                  child: const Text('恢复中转备份'),
                ),
              if (rows == null)
                PrimaryButton(label: applyLabel, onPressed: apply)
              else
                SmallButton(label: applyLabel, onPressed: apply),
            ],
          ),
        ],
      ),
    );
    final result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rows != null)
                _allocationView(context, rows, allocationAsset!),
              if (transit &&
                  s.distributionTransits.length >
                      (rows?.where((r) => r.transit != null).length ?? 0))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${t(context, 'relay_history')} · ${s.distributionTransits.length}',
                          style: muted,
                        ),
                      ),
                      if (s.downloadText != null)
                        _download(
                          s.distributionTransits.values.toList(),
                          '全部中转',
                        ),
                      TextButton(
                        onPressed: () =>
                            _copyKeys(s.distributionTransits.values.toList()),
                        child: Text(t(context, 'copy_transit_keys')),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (engine.running && engine.current?.label != '归集')
                PrimaryButton(label: t(context, 'stop'), onPressed: engine.stop)
              else
                PrimaryButton(
                  label: t(context, 'start_distribute'),
                  busy: working,
                  onPressed: rows == null || busyRun
                      ? null
                      : () => _do(_startDistribute),
                ),
              if (!busyRun) _warmTransfer(distribution: true),
              if (rows == null && !engine.running)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    t(context, 'need_apply'),
                    textAlign: TextAlign.start,
                    style: muted,
                  ),
                ),
            ],
          ),
        ),
        for (final run in _visibleRuns(collection: false)) ...[
          const SizedBox(height: 12),
          _runPanel(run),
        ],
      ],
    );
    return _ToolColumns(first: configuration, second: result);
  }

  int _lines(String text) =>
      text.split(RegExp(r'[\s,;，；]+')).where((x) => x.isNotEmpty).length;

  Widget _assetRow(
    BuildContext context,
    bool token,
    TextEditingController address,
    ValueChanged<bool> onToken, {
    required VoidCallback onRefresh,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(t(context, 'asset'), style: label),
            OptionPair<bool>(
              compact: true,
              options: [(false, 'BNB'), (true, t(context, 'token'))],
              value: token,
              onChanged: locked ? null : onToken,
            ),
            SmallButton(
              label: t(context, 'refresh'),
              onPressed: locked ? null : onRefresh,
            ),
          ],
        ),
        if (token) ...[
          const SizedBox(height: 8),
          InputBox(
            controller: address,
            address: true,
            hint: t(context, 'token_address'),
            onChanged: (_) => _edit(() {}),
          ),
        ],
        if (balanceText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${t(context, 'balance')} $balanceText', style: muted),
          ),
      ],
    );
  }

  Widget _allocationView(
    BuildContext context,
    List<Allocation> rows,
    TransferAsset asset,
  ) {
    final total = rows.fold(BigInt.zero, (a, r) => a + r.amount);
    final run = engine.current;
    final relays = [
      for (final r in rows)
        if (r.transit != null) r.transit!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 4,
          children: [
            Text(
              '${t(context, 'distribution_details')} · ${rows.length}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${t(context, 'total')} ${formatUnits(total, asset.decimals, maxFraction: asset.decimals)} ${asset.symbol}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              final st = run != null && identical(run.rows, rows)
                  ? run.statusOf(i)
                  : null;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _TransferAddressRow(
                  number: i + 1,
                  sender: r.sender?.address,
                  address: r.recipient,
                  detail: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        formatUnits(
                          r.amount,
                          asset.decimals,
                          maxFraction: asset.decimals,
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (st != null)
                        SizedBox(
                          width: 52,
                          child: Text(
                            statusLabel(context, st),
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 12,
                              color: statusColor(st),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (relays.isNotEmpty) ...[
          const Divider(height: 16, color: UiStyle.border),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${t(context, 'relays')} · ${relays.length}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (widget.state.downloadText != null)
                _download(relays, '本次中转'),
              TextButton(
                onPressed: () => _copyKeys(relays),
                child: Text(t(context, 'copy_transit_keys')),
              ),
              TextButton(
                onPressed: () =>
                    _copy(relays.map((w) => w.address).join('\n')),
                child: Text(t(context, 'copy_relay_addresses')),
              ),
            ],
          ),
          GeneratedWalletList(
            wallets: relays,
            onKeyCopied: (wallet) => widget.state.markKeysCopied([wallet]),
          ),
          if (relays.any((r) => !r.canReceiveFunds))
            Text(
              t(
                context,
                widget.state.walletBackup == null
                    ? 'transit_backup_rule'
                    : 'folder_transit_backup_rule',
              ),
              style: const TextStyle(color: UiStyle.action, fontSize: 12),
            ),
          Text(t(context, 'relay_note'), style: muted),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ collect

  Future<void> _startCollect() async {
    final sources = _collectWallets, recipient = target.text.trim();
    final token = collectToken ? collectTokenAddr.text.trim() : null;
    Future<TransferRun> prepare() async => engine.prepareCollection(sources, recipient, await engine.asset(token));
    final run = _takeWarmReview((sources, recipient, token)) ?? await prepare();
    if (mounted) await _executeTransfer(run, prepare: prepare);
  }

  Widget _collect(BuildContext context) {
    final s = widget.state;
    final n = _count(collectKeys);
    final configuration = Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KeyField(
            label: t(context, 'collector_keys'),
            summary: n == 0
                ? t(context, 'not_filled')
                : '$n ${t(context, 'keys_unit')}',
            onTap: locked
                ? null
                : () async {
                    final v = await _keys(
                      t(context, 'collector_keys'),
                      collectKeys,
                      WalletBackupCategory.toolCollectionSource,
                    );
                    if (mounted && v != null) _setCollectionKeys(v);
                  },
            extra: s.groups.isEmpty
                ? null
                : UiMenu<GroupBase>(
                    enabled: !locked,
                    onSelected: (g) async {
                      final wallets = g.allWallets;
                      _setCollectionKeys(formatPrivateKeyLines(wallets));
                      await s.walletBackup?.capture(
                        WalletBackupCategory.toolCollectionSource,
                        wallets,
                      );
                    },
                    options: [
                      for (final g in s.groups)
                        (g, '${g.name} · ${g.allWallets.length}'),
                    ],
                    child: Text(t(context, 'load_group')),
                  ),
          ),
          const SizedBox(height: 12),
          Text(t(context, 'target'), style: label),
          const SizedBox(height: 6),
          InputBox(controller: target, hint: '0x…', address: true),
          const SizedBox(height: 12),
          _assetRow(
            context,
            collectToken,
            collectTokenAddr,
            (v) => _edit(() => collectToken = v),
            onRefresh: () => _do(
              () => _readBalance(
                keys: collectKeys,
                token: collectToken,
                address: collectTokenAddr,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (engine.running && engine.current?.label == '归集')
            PrimaryButton(label: t(context, 'stop'), onPressed: engine.stop)
          else
            PrimaryButton(
              label: t(context, 'start_collect'),
              busy: working,
              onPressed: () => _do(_startCollect),
            ),
          _warmTransfer(distribution: false),
        ],
      ),
    );
    final runs = _visibleRuns(collection: true).toList();
    return _ToolColumns(
      first: configuration,
      second: runs.isNotEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < runs.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _runPanel(runs[i]),
                ],
              ],
            )
          : Panel(
              title: t(context, 'execution'),
              child: Text(t(context, 'log_empty'), style: muted),
            ),
    );
  }

  String _firstAddress(String keys) {
    try {
      return _parse(keys, distribution: true).single.address;
    } on Object {
      return '请检查分发方私钥';
    }
  }
}

class _TransferAddressRow extends StatelessWidget {
  const _TransferAddressRow({
    required this.number,
    required this.address,
    this.sender,
    required this.detail,
  });

  final int number;
  final String address;
  final String? sender;
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    Widget copyAddress(String value) => Tooltip(
      message: t(context, 'copy_address'),
      child: TextButton(
        style: TextButton.styleFrom(
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: 2),
        ),
        onPressed: () => ClipboardFeedback.copy(
          context,
          value,
          successLabel: t(context, 'copied'),
        ),
        child: Text(value, style: mono),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 26,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('$number', style: muted),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (sender case final source?) ...[
                copyAddress(source),
                const Icon(Icons.arrow_forward, size: 14),
              ],
              copyAddress(address),
              detail,
            ],
          ),
        ),
      ],
    );
  }
}

String statusLabel(BuildContext context, TransferStatus s) =>
    t(context, switch (s) {
      TransferStatus.confirmed => 'ts_confirmed',
      TransferStatus.notIncluded => 'ts_not_received',
      TransferStatus.failed => 'ts_failed',
      TransferStatus.unknown => 'ts_unknown',
      TransferStatus.submitted => 'ts_submitted',
      TransferStatus.skipped => 'ts_skipped',
      TransferStatus.waiting => 'ts_waiting',
    });

Color statusColor(TransferStatus s) => switch (s) {
  TransferStatus.confirmed => UiStyle.positive,
  TransferStatus.failed || TransferStatus.notIncluded => UiStyle.negative,
  TransferStatus.unknown => UiStyle.action,
  _ => UiStyle.muted,
};

/// Status counts of the current transfer run and its recovery actions (web retry queue).
class _RunPanel extends StatelessWidget {
  const _RunPanel({
    super.key,
    required this.state,
    required this.run,
    required this.onRetry,
  });
  final AppState state;
  final TransferRun run;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final engine = state.transfers;
    final active = engine.running && identical(engine.current, run);
    final checking = engine.querying(run);
    final originalHash = run.legs.map((leg) => leg.hash).nonNulls.firstOrNull;
    Widget chip(TransferStatus s) {
      final n = run.count(s);
      if (n == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Text(
          '${statusLabel(context, s)} $n',
          style: muted.copyWith(color: statusColor(s)),
        ),
      );
    }

    return Panel(
      title: '${run.label} · ${run.rows.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (originalHash != null &&
              (run.hasUnknown || !identical(engine.current, run)))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(originalHash, style: mono),
            ),
          Wrap(
            children: [
              for (final s in [
                TransferStatus.confirmed,
                TransferStatus.submitted,
                TransferStatus.unknown,
                TransferStatus.notIncluded,
                TransferStatus.failed,
                TransferStatus.waiting,
                TransferStatus.skipped,
              ])
                chip(s),
            ],
          ),
          if (run.label == '归集') ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: run.rows.length,
                itemBuilder: (_, i) => _TransferAddressRow(
                  number: i + 1,
                  address: run.rows[i].sender!.address,
                  detail: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        formatUnits(
                          run.rows[i].amount,
                          run.asset.decimals,
                          maxFraction: run.asset.decimals,
                        ),
                        style: const TextStyle(fontSize: 12),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          statusLabel(context, run.statusOf(i)),
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            fontSize: 12,
                            color: statusColor(run.statusOf(i)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (!active) ...[
            const SizedBox(height: 10),
            if (run.hasUnknown)
              PrimaryButton(
                label: t(context, 'query_transfers'),
                busy: checking,
                onPressed: () async {
                  try {
                    await engine.query(run);
                  } catch (e) {
                    if (context.mounted) await showError(context, e);
                  }
                },
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: checking ? null : () => engine.finish(run),
                    child: Text(t(context, 'finish')),
                  ),
                  if (run.retryable &&
                      !run.legs.any((l) => l.status == TransferStatus.failed))
                    PrimaryButton(
                      label: t(context, 'retry_unfinished'),
                      onPressed: engine.running || checking ? null : onRetry,
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// A private key field that opens the separate editor instead of editing inline.
class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.label,
    required this.summary,
    required this.onTap,
    this.extra,
  });
  final String label;
  final String summary;
  final VoidCallback? onTap;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final address = isAddress(summary);
    final edit = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).width < 600 ? 40 : 34),
        child: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          runAlignment: WrapAlignment.center,
          children: [
            Text(label, style: strong),
            if (!address) Text(summary, style: muted),
            Text(t(context, 'edit'), style: muted.copyWith(
              color: onTap == null ? UiStyle.muted : UiStyle.text,
              fontWeight: FontWeight.w600,
            )),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [edit, ?extra],
        ),
        if (address)
          InkWell(onTap: onTap, child: Text(summary, style: mono)),
      ],
    );
  }
}

/// A single page scroll with side-by-side input / result areas on desktop.
class _ToolColumns extends StatelessWidget {
  const _ToolColumns({required this.first, required this.second});
  final Widget first, second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 920) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 16), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 6, child: first),
          const SizedBox(width: 20),
          Expanded(flex: 5, child: second),
        ],
      );
    },
  );
}

/// Numeric ranges need readable fields, not the width reserved for a long address.
class _ShortField extends StatelessWidget {
  const _ShortField({required this.child, this.maxWidth = 360});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
