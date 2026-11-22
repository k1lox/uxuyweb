import '../exec/preview_deadline.dart';
import 'impact_settings.dart';

import 'dart:async' show Timer;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../exec/executor.dart' show bscBundleTipRecipient, PreparedRound, SendMode;
import '../exec/genius_launch.dart';
import '../exec/genius_configurable.dart';
import '../exec/genius_quote_labels.dart';
import '../exec/launch.dart';
import '../exec/flap_vault.dart';
import '../exec/flap_vault_adapters.dart';
import '../exec/market.dart' show zeroAddress, fourManager, flapPortal;
import '../state/app_state.dart';
import '../wallet/wallet.dart';
import '../wallet/wallet_backup.dart';
import 'clipboard_feedback.dart';
import 'key_editor.dart';
import 'launch_allocation.dart';
import 'launch_budget.dart';
import 'flap_vault_editor.dart';
import 'widgets.dart';
import 'wallet_overlap.dart';

/// Launchpads (web 发射台): Four.meme / Flap / Genius, each with its own form, bundle status and liquidation.
class LaunchPage extends StatefulWidget {
  const LaunchPage({
    super.key,
    required this.state,
    required this.onTrade,
    this.active = true,
    this.selectedPlatform,
    this.onPlatformChanged,
    this.tips,
    this.actionsInSidebar = false,
  }) : assert(tips == null || tips.length == 3), assert(
         selectedPlatform == null ||
             (selectedPlatform >= 0 && selectedPlatform <= 2),
       );
  final AppState state;

  /// The desktop sidebar owns platform selection. Keep the same mounted forms
  /// when switching so drafts, keys and pending transaction state survive.
  final int? selectedPlatform;
  final bool active;
  final ValueChanged<int>? onPlatformChanged;
  final List<LaunchTipDraft>? tips;
  final bool actionsInSidebar;

  /// Switch to the batch page with the launched token loaded.
  final VoidCallback onTrade;

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends State<LaunchPage> {
  int platform = 0;
  final _scroll = ScrollController();
  final _formStorage = PageStorageBucket();

  @override
  void didUpdateWidget(covariant LaunchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedPlatform != null) platform = widget.selectedPlatform!;
    if (widget.selectedPlatform != oldWidget.selectedPlatform &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Set while Four's official API cannot be used for launching (reported by the Four form's config load).
  String? fourUnavailable;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final four = fourUnavailable == null
        ? 'Four.meme'
        : 'Four.meme · ${t(context, 'launch_unavailable')}';
    final active = widget.selectedPlatform ?? platform;
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        return ListView(
          key: const PageStorageKey('launch-page-scroll'),
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(
            desktop ? 24 : 16,
            16,
            desktop ? 24 : 16,
            32,
          ),
          children: [
            if (!desktop || widget.selectedPlatform == null) ...[
              SubTabs<int>(
                options: [(0, four), (1, 'Flap'), (2, 'Genius')],
                value: active,
                onChanged: (i) {
                  final reason = s.workspaceBlockReason(
                    [WorkspacePage.four, WorkspacePage.flap, WorkspacePage.genius][i],
                  );
                  if (reason != null) {
                    UiNotice.show(context, reason);
                    return;
                  }
                  setState(() => platform = i);
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                  widget.onPlatformChanged?.call(i);
                },
              ),
              const SizedBox(height: 16),
            ],
            // Keep the list's saved scroll offset separate from form fields and
            // expandable details, which also read and write page storage.
            PageStorage(
              key: const ValueKey('launch-platform-forms'),
              bucket: _formStorage,
              child: Column(
                children: [
                  Offstage(
                    offstage: active != 0,
                    child: _LaunchForm(
                      key: const ValueKey('four'),
                      state: s,
                      launcher: s.four,
                      kind: _Kind.four,
                      tip: widget.tips?[0],
                      actionsInSidebar: widget.actionsInSidebar,
                      active: widget.active && active == 0,
                      onTrade: widget.onTrade,
                      onUnavailable: (reason) =>
                          setState(() => fourUnavailable = reason),
                    ),
                  ),
                  Offstage(
                    offstage: active != 1,
                    child: _LaunchForm(
                      key: const ValueKey('flap'),
                      state: s,
                      launcher: s.flap,
                      kind: _Kind.flap,
                      tip: widget.tips?[1],
                      actionsInSidebar: widget.actionsInSidebar,
                      active: widget.active && active == 1,
                      onTrade: widget.onTrade,
                    ),
                  ),
                  Offstage(
                    offstage: active != 2,
                    child: _LaunchForm(
                      key: const ValueKey('genius'),
                      state: s,
                      launcher: s.genius,
                      kind: _Kind.genius,
                      tip: widget.tips?[2],
                      actionsInSidebar: widget.actionsInSidebar,
                      active: widget.active && active == 2,
                      onTrade: widget.onTrade,
                    ),
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

typedef _Kind = LaunchAllocationPlatform;

/// Buyer list text: one private key per line, optionally followed by an amount overriding the default.
List<LaunchBuyer> parseBuyers(
  String text,
  String defaultAmount,
  int decimals,
) => [for (final row in _buyerRows(text, defaultAmount, decimals)) row.buyer];

Iterable<({LaunchBuyer buyer, String? overrideAmount})> _buyerRows(
  String text,
  String defaultAmount,
  int decimals,
) sync* {
  final seen = <String>{};
  var lineNumber = 0;
  for (final line in const LineSplitter().convert(ordinaryWalletInput(text))) {
    lineNumber++;
    if (line.trim().isEmpty) continue;
    try {
      final row = parseWalletKeyLine(line, allowAmount: true);
      final wallet = TradeWallet.import('L${seen.length + 1}', row.key);
      final amount = row.amount ?? defaultAmount;
      if (amount.trim().isEmpty) throw const FormatException('缺少金额');
      final value = parseUnits(amount, decimals);
      if (seen.add(wallet.address.toLowerCase())) {
        yield (buyer: LaunchBuyer(wallet, value), overrideAmount: row.amount);
      }
    } on FormatException catch (e) {
      throw FormatException('第 $lineNumber 行：${e.message}');
    }
  }
}

class _LaunchForm extends StatefulWidget {
  const _LaunchForm({
    super.key,
    required this.state,
    required this.launcher,
    required this.active,
    required this.kind,
    required this.tip,
    required this.actionsInSidebar,
    required this.onTrade,
    this.onUnavailable,
  });
  final AppState state;
  final Launcher launcher;
  final bool active;
  final _Kind kind;
  final LaunchTipDraft? tip;
  final bool actionsInSidebar;
  final VoidCallback onTrade;

  /// Four only: called with the reason when its official API cannot be used, and with null once it can.
  final ValueChanged<String?>? onUnavailable;

  @override
  State<_LaunchForm> createState() => _LaunchFormState();
}

class _LaunchFormState extends State<_LaunchForm> {
  final c = <String, TextEditingController>{};
  TextEditingController ctl(String k, [String v = '']) =>
      c.putIfAbsent(k, () => TextEditingController(text: v));

  LaunchImage? image;
  TradeWallet? _creator;
  bool taxToken = false;
  bool migrate = false, exemptInside = false;
  String insideText = '', outsideText = '';
  int insideCount = 0, outsideCount = 0;
  void _setPurchaseMode(bool withOuter) {
    migrate = withOuter;
    if (!withOuter && widget.kind != _Kind.genius) {
      outsideText = '';
      outsideCount = 0;
      ctl('outerDefault').clear();
    }
  }
  late final _standaloneTip = widget.tip == null ? LaunchTipDraft() : null;
  LaunchTipDraft get _tip => widget.tip ?? _standaloneTip!;
  BigInt get _bundleTip {
    final value = _tip.text.trim();
    return parseUnits(value.isEmpty ? '0' : value, 18);
  }
  Future<void> _editBuyerGroup(bool outside) async {
    final name = t(context, outside ? 'external_wallets' : 'internal_wallets');
    final result = await Navigator.of(context).push<String>(
      KeyEditorRoute(
        context: context,
        settings: const RouteSettings(name: '/uxuy_trade/launch_keys'),
        builder: (_) => KeyEditorPage(
          title: name,
          initial: outside ? outsideText : insideText,
          keyBeforeAmount: true,
          backup: widget.state.walletBackup,
          backupCategory: outside
              ? WalletBackupCategory.launchExternalBuyer
              : WalletBackupCategory.launchInternalBuyer,
          backupScope: _backupScope,
          onSave: (text) async {
            final rows = parseBuyers(text, '1', 36);
            final cap = widget.kind == _Kind.genius
                ? (outside ? geniusOuterWalletLimit : geniusInnerWalletLimit(migrate: migrate, tip: _bundleTip))
                : 100;
            if (rows.length > cap) throw FormatException('$name 最多 $cap 个地址');
            final other = parseBuyers(
              outside ? insideText : migrate ? outsideText : '',
              '1',
              36,
            ).map((b) => b.wallet.address.toLowerCase()).toSet();
            if (rows.any(
              (r) =>
                  other.contains(r.wallet.address.toLowerCase()) ||
                  r.wallet.address.toLowerCase() ==
                      _creator?.address.toLowerCase(),
            ))
              throw const FormatException('Dev、内盘、外盘钱包不能重复');
            if (widget.kind != _Kind.genius && rows.length + other.length > 100)
              throw const FormatException('内外盘买家合计最多 100 位');
          },
        ),
      ),
    );
    if (mounted && result != null)
      setState(() {
        final count = parseBuyers(result, '1', 36).length;
        if (outside) {
          outsideText = result;
          outsideCount = count;
        } else {
          insideText = result;
          insideCount = count;
        }
      });
  }

  Future<void> _allocateBuyers(bool outside) => _guard(() async {
    final source = outside ? outsideText : insideText;
    final title = t(context, outside ? 'external_wallets' : 'internal_wallets');
    final fallback = ctl(outside ? 'outerDefault' : 'innerDefault').text;
    final token = _purchaseToken;
    final nativePool = switch (widget.kind) {
      _Kind.four => (selectedRaised ?? (throw StateError('请先选择底池'))).native,
      _Kind.flap => (selectedPayment ?? (throw StateError('请先选择底池'))).native,
      _Kind.genius => geniusQuote == zeroAddress,
    };
    final rows = _buyerRows(source, '0', 36).toList();
    final api = widget.state.api;
    final symbol = _purchaseUnit;
    late final load = () async {
      final decimals = token == null
          ? 18
          : (await launchPaymentMeta(api, token)).decimals!;
      final balances = await loadLaunchAllocation(
        api,
        buyers: [for (final r in rows) (address: r.buyer.wallet.address, amount: r.overrideAmount ?? fallback)],
        platform: widget.kind,
        paymentToken: token,
        nativePool: nativePool,
        migrate: migrate,
        outside: outside,
      );
      return (decimals: decimals, balances: balances);
    }();
    final changes = await showUiDialog<Map<String, String>>(
      context: context,
      builder: (c) => FutureBuilder(
        future: load,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            final error = snapshot.error;
            return UiDialog(
              title: Text('$title · 按余额分配'),
              content: Text(error == null ? '正在读取钱包余额…' :
                error is BackendException ? error.userMessage : '$error'),
            );
          }
          final data = snapshot.requireData;
          return LaunchAllocationDialog(
            title: '$title · 按余额分配', rows: data.balances, decimals: data.decimals, symbol: symbol,
          );
        },
      ),
    );
    if (!mounted || changes == null) return;
    if (_purchaseToken != token || (outside ? outsideText : insideText) != source || l.busy || _confirming) {
      throw StateError('钱包或付款币已变化，请重新分配');
    }
    final text = rows.map((row) {
      final wallet = row.buyer.wallet;
      final amount = changes[wallet.address] ?? row.overrideAmount;
      return [wallet.exportPrivateKey(), if (amount != null) amount].join(' ');
    }).join('\n');
    setState(() {
      if (outside) {
        outsideText = text;
      } else {
        insideText = text;
      }
    });
  });

  Widget _buyerGroup(bool outside, bool locked) {
    final count = outside ? outsideCount : insideCount;
    final title = t(context, outside ? 'external_wallets' : 'internal_wallets');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          SmallButton(
            label: '$title · $count',
            onPressed: locked ? null : () => _editBuyerGroup(outside),
          ),
          if (count > 0) SmallButton(
            label: '按余额分配',
            onPressed: locked ? null : () => _allocateBuyers(outside),
          ),
        ]),
        if (count > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _field(
              t(context, 'per_wallet_amount'),
              ctl(outside ? 'outerDefault' : 'innerDefault'),
              locked,
              unit: _purchaseUnit,
              width: 200,
            ),
          ),
      ],
    );
  }

  bool nonTax = false;
  String category = 'Meme';
  int geniusRewardMode = 0;
  bool geniusLpRewards = false;
  bool geniusFoundation = false;
  bool alpha = false;

  String? geniusLogo;
  bool customGeniusQuote = false;
  String get geniusQuote => ctl('quote').text.trim().isEmpty
      ? zeroAddress
      : ctl('quote').text.trim().toLowerCase();

  Future<LaunchTarget> _readBudgetTarget() async {
    switch (widget.kind) {
      case _Kind.four:
        final asset = selectedRaised!;
        final tax = taxToken ? int.parse(ctl('buyTax').text) : 0;
        final crossing = migrate;
        final data = await (l as FourLauncher).previewTarget(asset, tax);
        return (
          amount: crossing ? data.crossing : data.base, decimals: data.decimals,
          symbol: asset.lookupSymbol,
        );
      case _Kind.flap:
        final asset = selectedPayment!;
        final tax = nonTax ? '0' : ctl('buyTax').text.trim();
        final data = await (l as FlapLauncher).previewTarget(
          asset, nonTax ? 7 : 6, parseUnits(tax, 2),
        );
        return (amount: data.gross, decimals: asset.decimals, symbol: asset.symbol);
      case _Kind.genius:
        final data = await (l as GeniusLauncher).previewPool(geniusQuote);
        return (amount: data.threshold, decimals: data.decimals, symbol: data.symbol);
    }
  }

  Widget _budget() {
    if (!widget.active || widget.kind == _Kind.four && selectedRaised == null ||
        widget.kind == _Kind.flap && selectedPayment == null) return const SizedBox.shrink();
    List<String>? amounts;
    try {
      amounts = launchInnerAmounts(ctl('devAmount').text, insideText, ctl('innerDefault').text);
    } on FormatException {
      // Incomplete rows are editable and must never appear as a zero budget.
    }
    return Padding(padding: const EdgeInsets.only(top: 10), child: LaunchBudgetPanel(
      api: widget.state.api,
      selection: (widget.kind, _poolToken, selectedRaised?.totalBAmount,
        taxToken, nonTax, ctl('buyTax').text, migrate),
      readTarget: _readBudgetTarget, amounts: amounts, payBnb: _purchaseToken == null,
      unit: _purchaseUnit, pool: _poolToken, dev: _creator?.address,
      paymentDecimals: selectedPayment?.decimals,
    ));
  }

  bool loading = false;
  bool get _confirming => _tip.confirming;
  bool _checkingConfirmation = false;
  List<String> _vaultWarnings = const [];
  final _vaultEditor = GlobalKey<FlapVaultEditorState>();

  List<FourRaised> raised = [];
  FourRaised? selectedRaised;
  List<FlapPayment> payments = [];
  FlapPayment? selectedPayment;
  bool paymentChosen = false;
  List<FlapPayment> officialPayments = [],
      directoryPayments = [],
      manualPayments = [];
  final catalogNotices = <bool, ({String message, bool retry, bool failed})>{};
  void mergeFlapCatalogs() {
    final byAddress = <String, FlapPayment>{};
    for (final p in [
      ...officialPayments,
      ...directoryPayments,
      ...manualPayments,
    ]) {
      if (p.available) byAddress.putIfAbsent(p.address.toLowerCase(), () => p);
    }
    final previous = paymentChosen ? selectedPayment : null;
    payments = byAddress.values.toList();
    selectedPayment =
        byAddress[previous?.address.toLowerCase()] ??
        (payments.isEmpty
            ? null
            : payments.firstWhere(
                (p) => p.native,
                orElse: () => payments.first,
              ));
    _syncFundingCurrency();
  }

  final _catalogTimers = <bool, Timer>{};
  final _catalogGeneration = <bool, int>{};
  Future<void> loadFlapCatalog(
    bool custom, {
    int retry = 0,
    int? generation,
  }) async {
    final revision = generation ?? ((_catalogGeneration[custom] ?? 0) + 1);
    if (retry == 0) {
      _catalogTimers.remove(custom)?.cancel();
      _catalogGeneration[custom] = revision;
    }
    final title = custom ? '自定义底池币列表' : '官方底池币列表';
    String? notice;
    var needsRetry = true;
    var failed = false;
    try {
      final result = await (l as FlapLauncher).catalogSnapshot(custom: custom);
      if (!mounted || _catalogGeneration[custom] != revision) return;
      if (custom) {
        directoryPayments = result.tokens;
      } else {
        officialPayments = result.tokens;
      }
      if (result.refreshError?.isNotEmpty == true) {
        failed = true;
        notice = '$title更新失败，暂用上次的列表。\n${result.refreshError}';
      } else if (result.stale) {
        needsRetry = retry >= 6;
        notice = needsRetry
            ? '$title尚未更新，可重试。'
            : '正在更新$title，暂用上次的列表。';
        if (retry < 6) {
          _catalogTimers[custom] = Timer(
            const Duration(seconds: 5),
            () =>
                loadFlapCatalog(custom, retry: retry + 1, generation: revision),
          );
        }
      } else if (result.partial || result.tokens.isEmpty) {
        notice = result.tokens.isEmpty
            ? '$title暂无可选代币。'
            : '$title中部分代币资料尚未取全，可选择已列出的币。';
      }
    } on Object catch (e) {
      failed = true;
      notice =
          '$title读取失败。\n${e is BackendException ? e.userMessage : e.toString()}';
    }
    if (!mounted || _catalogGeneration[custom] != revision) return;
    setState(() {
      if (notice == null) {
        catalogNotices.remove(custom);
      } else {
        catalogNotices[custom] = (message: notice, retry: needsRetry, failed: failed);
      }
      mergeFlapCatalogs();
    });
  }

  Launcher get l => widget.launcher;
  String get _backupScope => switch (widget.kind) {
    _Kind.four => 'FourMeme',
    _Kind.flap => 'Flap',
    _Kind.genius => 'Genius',
  };

  @override
  void initState() {
    super.initState();
    for (final e in {
      'buyTax': '3',
      'sellTax': '3',
      'burn': '0',
      'divide': '0',
      'liq': '0',
      'rec': '100',
      'mkt': '100',
      'minShare': '1000000',
      'minShareNT': '10000',
      'flapAntiFarmerDays': '30',
      'geniusBuy': '0',
      'geniusSell': '0',
      'geniusBurn': '0',
      'geniusRewards': '0',
      'geniusLiquidity': '0',
      'geniusYears': '0',
      'geniusMinimum': '1',
    }.entries) {
      ctl(e.key, e.value);
    }
    if (widget.kind == _Kind.four) taxToken = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadConfig());
  }

  @override
  void dispose() {
    for (final timer in _catalogTimers.values) {
      timer.cancel();
    }
    l.cancelLiquidationPreview();
    _standaloneTip?.dispose();
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on Object catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  /// Loaded silently on open; a failure is shown inline next to the field (no pop-up over other pages).
  String? configError;

  /// Four only: why its official API cannot be used right now. Replaces the form until a check succeeds.
  String? unavailable;

  Future<void> _loadConfig() async {
    if (widget.kind == _Kind.genius || loading) return;
    setState(() {
      loading = true;
      configError = null;
    });
    try {
      if (widget.kind == _Kind.four) {
        raised = await (l as FourLauncher).raisedTokens();
        selectedRaised = raised.isEmpty
            ? null
            : raised.firstWhere((r) => r.native, orElse: () => raised.first);
      } else {
        await Future.wait([loadFlapCatalog(false), loadFlapCatalog(true)]);
      }
      unavailable = null;
    } on Object catch (e) {
      if (widget.kind == _Kind.four &&
          e is BackendException &&
          e.isFourOfficialOutage) {
        // Four's own API is out of reach (Cloudflare challenge, outage): launching waits, trading does not.
        unavailable = e.message;
      } else {
        // Backend codes carry their own explanation (cooldown seconds, Flap 403).
        configError = e is BackendException
            ? e.userMessage
            : (e is StateError ? e.message : '$e');
      }
    }
    if (!mounted) return;
    setState(() => loading = false);
    if (widget.kind == _Kind.four) widget.onUnavailable?.call(unavailable);
  }

  /// Four's official API is out of reach: explain, keep trading pointers, and let the user check again.
  Widget _unavailable(BuildContext context) => Column(
    children: [
      EmptyState(
        icon: Icons.pause_circle_outline,
        title: t(context, 'four_launch_unavailable'),
        hint: t(context, 'four_launch_unavailable_hint'),
      ),
      Text(unavailable!, style: muted, textAlign: TextAlign.center),
      const SizedBox(height: 12),
      SmallButton(
        label: t(context, loading ? 'loading' : 'recheck'),
        onPressed: loading ? null : _loadConfig,
      ),
    ],
  );

  Future<void> _pickImage() async {
    final picker = widget.state.imagePicker;
    if (picker == null) {
      showNotice(context, t(context, 'no_picker'));
      return;
    }
    await _guard(() async {
      final img = await picker();
      if (img != null) {
        setState(() {
          image = img;
          geniusLogo = null;
        });
      }
    });
  }

  bool payWithBnb = true;
  String get _purchaseUnit => payWithBnb ? 'BNB' : _poolUnit;
  String? get _purchaseToken => payWithBnb ? null : _poolToken;
  String get _poolUnit => switch (widget.kind) {
    _Kind.four => selectedRaised?.lookupSymbol ?? 'BNB',
    _Kind.flap => selectedPayment?.symbol ?? 'BNB',
    _Kind.genius =>
      ctl('quote').text.trim().isEmpty ||
              ctl('quote').text.trim().toLowerCase() == zeroAddress
          ? 'BNB'
          : geniusQuoteLabels[geniusQuote] ?? t(context, 'pool_token'),
  };

  String? get _poolToken {
    final String? quote = switch (widget.kind) {
      _Kind.four =>
        selectedRaised?.native == false ? selectedRaised?.address : null,
      _Kind.flap => selectedPayment?.address,
      _Kind.genius => ctl('quote').text.trim(),
    };
    return quote == null || quote.isEmpty || quote.toLowerCase() == zeroAddress
        ? null
        : quote;
  }

  String? _amountAsset;
  void _syncFundingCurrency() {
    final asset = _purchaseToken?.toLowerCase();
    if (asset == _amountAsset) return;
    _amountAsset = asset;
    ctl('devAmount', '0').text = '0';
    ctl('innerDefault').clear();
    ctl('outerDefault').clear();
    String keysOnly(String text) => [
      for (final line in const LineSplitter().convert(ordinaryWalletInput(text)))
        if (line.trim().isNotEmpty) parseWalletKeyLine(line, allowAmount: true).key,
    ].join('\n');
    insideText = keysOnly(insideText);
    outsideText = keysOnly(outsideText);
  }

  void _selectPayment(bool bnb) {
    if (payWithBnb != bnb) {
      setState(() {
        payWithBnb = bnb;
        _syncFundingCurrency();
      });
    }
  }

  Future<void> _editCreator(String title) async {
    late TradeWallet saved;
    String? overrideAmount;
    final v = await Navigator.of(context).push<String>(
      KeyEditorRoute(
        context: context,
        settings: const RouteSettings(name: '/uxuy_trade/launch_keys'),
        builder: (_) => KeyEditorPage(
          title: title,
          initial: _creator?.exportPrivateKey() ?? '',
          backup: widget.state.walletBackup,
          backupCategory: WalletBackupCategory.launchDev,
          singleWallet: true,
          backupScope: _backupScope,
          keyBeforeAmount: true,
          onSave: (text) async {
            final rows = _buyerRows(text, '0', _purchaseToken == null ? 18 : 36).toList();
            if (rows.length != 1) throw const FormatException('请输入一个 Dev 私钥');
            final buyer = rows.single.buyer;
            if ([
              ...parseBuyers(insideText, '1', 36),
              if (migrate) ...parseBuyers(outsideText, '1', 36),
            ].any((b) => b.wallet.address.toLowerCase() == buyer.wallet.address.toLowerCase())) {
              throw const FormatException('Dev、内盘、外盘钱包不能重复');
            }
            overrideAmount = rows.single.overrideAmount;
            validateLaunchPurchases(buyer, const [], const [], migrate: false);
            saved = TradeWallet.import('Dev', buyer.wallet.exportPrivateKey());
          },
        ),
      ),
    );
    if (mounted && v != null) {
      setState(() {
        _creator = saved;
        if (overrideAmount != null)
          ctl('devAmount', '0').text = overrideAmount!;
      });
    }
  }

  Future<void> _launch() async {
    if (_confirming || l.busy) return;
    setState(() {
      _tip.confirming = true;
      _checkingConfirmation = true;
      _vaultWarnings = const [];
    });
    try {
      await _guard(() async {
        final dev = _creator ?? (throw StateError('请先选择 Dev 钱包'));
        final fourPool = widget.kind == _Kind.four
            ? selectedRaised ?? (throw StateError('底池代币配置尚未加载完成'))
            : null;
        final text = ctl('devAmount', '0').text.trim();
        final purchaseToken = _purchaseToken;
        final metadata =
            purchaseToken != null &&
                (insideCount > 0 ||
                    migrate && outsideCount > 0 ||
                    !RegExp(r'^0+(?:\.0+)?$').hasMatch(text))
            ? await launchPaymentMeta(widget.state.api, purchaseToken)
            : null;
        final decimals = metadata == null
            ? 18
            : metadata.decimals ?? (throw StateError('底池币精度未知'));
        final devBuy = LaunchBuyer(dev, parseUnits(text, decimals));
        final internal = parseBuyers(
          insideText,
          ctl('innerDefault').text,
          decimals,
        );
        final external = migrate
            ? parseBuyers(outsideText, ctl('outerDefault').text, decimals)
            : <LaunchBuyer>[];
        validateLaunchPurchases(devBuy, internal, external, migrate: migrate);
        if (migrate && external.isEmpty)
          throw const FormatException('内外盘至少需要一位外盘买家');
        if (widget.kind == _Kind.four && migrate && !taxToken)
          throw const FormatException('Four 普通币的毕业由平台完成，无法在发行捆绑内衔接外盘');
        final participants = [
          dev,
          ...internal.map((b) => b.wallet),
          ...external.map((b) => b.wallet),
        ];
        final purchaseUnit = metadata?.symbol.isNotEmpty == true
            ? metadata!.symbol
            : _purchaseUnit;
        final tip = _bundleTip;
        final img = image;
        await withWalletUse(
          context,
          widget.state,
          owner: l,
          label: '${l.label} · ${t(context, 'prepare_launch')}',
          addresses: participants.map((w) => w.address).toList(),
          action: () async {
            final backup = widget.state.walletBackup;
            if (backup != null) {
              await backup.requireStoredIfConnected(
                WalletBackupCategory.launchDev,
                [dev],
                scope: _backupScope,
              );
              if (!mounted) return;
              for (final (category, buyers) in [
                (WalletBackupCategory.launchInternalBuyer, internal),
                (WalletBackupCategory.launchExternalBuyer, external),
              ]) {
                if (buyers.isNotEmpty)
                  await backup.requireStoredIfConnected(
                    category,
                    buyers.map((b) => b.wallet).toList(),
                    scope: _backupScope,
                  );
              }
              if (!mounted) return;
              widget.state.requireReceivable(
                participants.map((w) => w.address).toList(),
              );
            }
            final geniusPolicy = widget.kind == _Kind.genius
                ? _geniusPolicy()
                : null;
            GeniusAlphaQuote? alphaQuote;
            if (alpha && l is GeniusLauncher) {
              alphaQuote = await (l as GeniusLauncher).quoteAlpha(geniusM52);
            }
            final flapForm = widget.kind == _Kind.flap
                ? await _captureFlapForm(img, tip, dev.address)
                : null;
            if (mounted) setState(() => _checkingConfirmation = false);
            if (!mounted ||
                !await _confirm(
                  tip,
                  hasDevPurchase: devBuy.amount > BigInt.zero,
                  buyGroups: [
                    for (final (name, group) in [
                      ('内盘', internal),
                      ('外盘', external),
                    ])
                      if (group.isNotEmpty)
                        '$name ${group.length} 个钱包 · ${formatUnits(group.fold(BigInt.zero, (total, b) => total + b.amount), decimals, maxFraction: decimals)} $purchaseUnit',
                  ],
                  purchaseToken:
                      devBuy.amount > BigInt.zero ||
                          internal.isNotEmpty ||
                          external.isNotEmpty
                      ? purchaseToken
                      : null,
                  devPurchase:
                      '${formatUnits(devBuy.amount, decimals, maxFraction: decimals)} $purchaseUnit',
                  flapForm: flapForm,
                  geniusPolicy: geniusPolicy,
                  alphaQuote: alphaQuote,
                ))
              return;
            l.confirmApproval = (token, spender, buyers, cost) =>
                _reviewApproval(
                  token,
                  spender,
                  buyers,
                  cost,
                  decimals,
                  purchaseUnit,
                );
            l.confirmCosts = (txs, price, session) => _reviewCosts(
              txs,
              price,
              session,
              devBuy,
              internal,
              external,
              decimals,
              purchaseUnit,
            );
            switch (widget.kind) {
              case _Kind.four:
                if (img == null) throw const FormatException('请选择代币图片');
                final tax = taxToken
                    ? FourTax(
                        feeRate: int.parse(ctl('buyTax').text),
                        feeRateSell: int.parse(ctl('sellTax').text),
                        burn: int.parse(ctl('burn').text),
                        divide: int.parse(ctl('divide').text),
                        liquidity: int.parse(ctl('liq').text),
                        recipient: int.parse(ctl('rec').text),
                        recipientAddress: ctl('recAddr').text,
                        minSharing: int.parse(ctl('minShare').text),
                      )
                    : null;
                await (l as FourLauncher).launch(
                  FourLaunchForm(
                    name: ctl('name').text,
                    shortName: ctl('symbol').text,
                    desc: ctl('desc').text,
                    label: category,
                    webUrl: ctl('website').text,
                    twitterUrl: ctl('twitter').text,
                    telegramUrl: ctl('telegram').text,
                    tax: tax,
                    external: migrate,
                    payWithBnb: payWithBnb,
                    raised: fourPool!,
                    image: img,
                    tip: tip,
                  ),
                  dev: devBuy,
                  internal: internal,
                  external: external,
                );
              case _Kind.flap:
                await (l as FlapLauncher).launch(
                  flapForm!,
                  dev: devBuy,
                  internal: internal,
                  external: external,
                );
              case _Kind.genius:
                final g = l as GeniusLauncher;
                var logo = geniusLogo;
                if (logo == null) {
                  if (img == null) throw const FormatException('请选择代币图片');
                  logo = geniusLogo = await g.uploadImage(img, dev);
                }
                final quote = ctl('quote').text.trim();
                await g.launch(
                  GeniusLaunchForm(
                    policy: geniusPolicy!,
                    payWithBnb: payWithBnb,
                    external: migrate,
                    exemptInternal: exemptInside,
                    name: ctl('name').text,
                    symbol: ctl('symbol').text,
                    logo: logo,
                    description: ctl('desc').text,
                    socials: {
                      for (final f in [
                        'twitter',
                        'telegram',
                        'discord',
                        'website',
                        'farcaster',
                      ])
                        f: ctl(f).text.trim(),
                    },
                    quote: quote.isEmpty ? zeroAddress : quote,
                    creatorFeeRecipient: geniusFoundation
                        ? geniusM52Foundation
                        : ctl('creator').text.trim().isEmpty
                        ? dev.address
                        : ctl('creator').text.trim(),
                    alpha: alphaQuote != null,
                    confirmedAlpha: alphaQuote,
                    snipeTaxExemptions: ctl('exempt').text
                        .split(RegExp(r'[\s,;，]+'))
                        .where((x) => x.isNotEmpty)
                        .toList(),
                    tip: tip,
                  ),
                  dev: devBuy,
                  internal: internal,
                  external: external,
                );
            }
          },
        );
      });
    } finally {
      l.confirmCosts = null;
      l.confirmApproval = null;
      if (mounted)
        setState(() {
          _tip.confirming = false;
          _checkingConfirmation = false;
        });
    }
  }

  Future<FlapLaunchForm> _captureFlapForm(
    LaunchImage? img,
    BigInt tip,
    String creator,
  ) async {
    if (img == null) throw const FormatException('请选择代币图片');
    final payment = selectedPayment ?? (throw StateError('支付币配置尚未加载完成'));
    final vault = _vaultEditor.currentState?.capture();
    int bps(String key) => parseUnits(
      ctl(key).text.trim().isEmpty ? '0' : ctl(key).text,
      2,
    ).toInt();
    // Capture all editable parameters before any awaited request or confirmation.
    final values = {for (final entry in c.entries) entry.key: entry.value.text};
    final useNonTax = nonTax;
    final buyTax = useNonTax ? 0 : bps('buyTax');
    final sellTax = useNonTax ? 0 : bps('sellTax');
    final marketing = useNonTax ? 0 : bps('mkt');
    final burn = useNonTax ? 0 : bps('burn');
    final dividend = useNonTax ? 0 : bps('divide');
    final liquidity = useNonTax ? 0 : bps('liq');
    final enteredDividend = values['flapDividendToken']?.trim() ?? '';
    String? dividendToken = useNonTax || enteredDividend.isEmpty
        ? null
        : enteredDividend;
    var minimumShare = useNonTax && vault != null
        ? BigInt.zero
        : parseUnits(
            useNonTax ? values['minShareNT']! : values['minShare']!,
            18,
          );
    if (vault is FlapCuratedVaultSelection) {
      if (vault.dividendToken != null) {
        if (dividendToken != null &&
            dividendToken.toLowerCase() != vault.dividendToken!.toLowerCase()) {
          throw StateError('所选金库要求指定分红资产，请清空自定义分红代币后重试');
        }
        dividendToken = vault.dividendToken;
      }
      if (vault.minimumShare != null) minimumShare = vault.minimumShare!;
    }
    final gasBudget = vault == null
        ? BigInt.zero
        : await flapVaultGasDeficit(
            widget.state.api,
            factory: vault.factory,
            creator: creator,
            quoteToken: payment.address,
          );
    final form = FlapLaunchForm(
      payWithBnb: payWithBnb,
      external: migrate,
      nonTax: useNonTax,
      name: values['name'] ?? '',
      symbol: values['symbol'] ?? '',
      description: values['desc'] ?? '',
      socials: {
        for (final name in [
          'telegram',
          'twitter',
          'github',
          'youtube',
          'debox',
          'website',
        ])
          name: values[name] ?? '',
      },
      payment: payment,
      buyTaxBps: buyTax,
      sellTaxBps: sellTax,
      marketingBps: marketing,
      burnBps: burn,
      dividendBps: dividend,
      liquidityBps: liquidity,
      minimumShare: minimumShare,
      beneficiary:
          useNonTax || (values['flapBeneficiary']?.trim() ?? '').isEmpty
          ? null
          : values['flapBeneficiary']!.trim(),
      antiFarmerDays:
          int.tryParse(values['flapAntiFarmerDays']!.trim()) ??
          (throw const FormatException('保护期请输入 0 至 365 的整数天数')),
      vault: vault,
      dividendToken: dividendToken,
      vaultGasBudget: gasBudget,
      image: img,
      tip: tip,
    );
    form.validate();
    if (vault != null) {
      final context = form.vaultContext(creator);
      validateFlapCuratedLaunch(vault, context, quoteSymbol: payment.symbol);
      _vaultWarnings = validatePolicies(vault.info.policies, context);
    }
    return form;
  }

  Future<bool> _reviewApproval(
    String token,
    String spender,
    List<LaunchBuyer> buyers,
    BigInt network,
    int decimals,
    String unit,
  ) async {
    if (!mounted) return false;
    final total = buyers.fold(BigInt.zero, (sum, b) => sum + b.amount);
    final result = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: const Text('确认独立授权'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${buyers.length} 个钱包 · 合计 ${formatUnits(total, decimals, maxFraction: decimals)} $unit',
              style: strong,
            ),
            SelectableText('付款代币  $token', style: mono),
            SelectableText('授权对象  $spender', style: mono),
            Text('本批网络费上限 ${formatUnits(network, 18, maxFraction: 18)} BNB'),
            UiAccordion(
              title: '逐钱包额度',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final b in buyers)
                    SelectableText(
                      '${b.wallet.address} · ${formatUnits(b.amount, decimals, maxFraction: decimals)} $unit',
                      style: mono,
                    ),
                ],
              ),
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
            child: const Text('确认授权'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<bool> _reviewCosts(
    List<LaunchTx> txs,
    BigInt price,
    LaunchSession session,
    LaunchBuyer dev,
    List<LaunchBuyer> internal,
    List<LaunchBuyer> external,
    int decimals,
    String unit,
  ) async {
    if (!mounted) return false;
    String purchase(BigInt amount) =>
        '${formatUnits(amount, decimals, maxFraction: decimals)} $unit';
    final network = txs.fold(
      BigInt.zero,
      (total, tx) => total + price * BigInt.from(tx.gasLimit),
    );
    final sent = txs.fold(BigInt.zero, (total, tx) => total + tx.value);
    String bnb(BigInt value) =>
        '${formatUnits(value, 18, maxFraction: 18)} BNB';
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: const Text('确认发币支出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${session.symbol} · BSC', style: strong),
            SelectableText(session.token, style: mono),
            const SizedBox(height: 8),
            Text('本轮 BNB 支出上限  ${bnb(sent + network)}', style: strong),
            Text('网络费上限  ${bnb(network)} · ${formatUnits(price, 9, maxFraction: 9)} Gwei'),
            const Text('网络费以最终回执为准', style: muted),
            const Divider(height: 16),
            Text('Dev 首买  ${purchase(dev.amount)}'),
            for (final (stage, buyers) in [('内盘', internal), ('外盘', external)])
              if (buyers.isNotEmpty)
                UiAccordion(
                  title:
                      '$stage ${buyers.length} 个钱包 · 支出上限 ${purchase(buyers.fold(BigInt.zero, (sum, buyer) => sum + buyer.amount))}',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final buyer in buyers)
                        SelectableText(
                          '${buyer.wallet.address} · ${purchase(buyer.amount)}',
                          style: mono,
                        ),
                    ],
                  ),
                ),
            if (txs.any((tx) => tx.kind == 'funding'))
              Text('BNB 先换成底池币再首买。超过本次首买用量的底池币留在付款钱包。', style: muted),
            for (final tx in txs.whereType<LaunchFundingTx>())
              SelectableText('${tx.from.address} · ${bnb(tx.value)} → 至少 ${formatUnits(tx.minimumDelivery!, tx.asset.decimals!, maxFraction: tx.asset.decimals!)} ${tx.asset.symbol}，首买上限 ${formatUnits(tx.poolSpend, tx.asset.decimals!, maxFraction: tx.asset.decimals!)} ${tx.asset.symbol}', style: mono),
            for (final tx in txs)
              if (tx.kind == 'create')
                Text('平台发行费  ${bnb(tx.creationFee ?? tx.value)}')
              else if (tx.kind == 'tip')
                Text(_builderTipDetails(c, tx.value, tx.to!))
              else if (tx.purchasedToken == null)
                Text('${tx.label}  ${bnb(tx.value)}'),
            if (session.reserved > BigInt.zero)
              Text('另留在 Dev 钱包供清仓使用  ${bnb(session.reserved)}'),
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

  Future<bool> _confirm(
    BigInt tip, {
    required String devPurchase,
    List<String> buyGroups = const [],
    bool hasDevPurchase = true,
    String? purchaseToken,
    FlapLaunchForm? flapForm,
    GeniusConfigurablePolicy? geniusPolicy,
    GeniusAlphaQuote? alphaQuote,
  }) async {
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: Text(t(c, 'prepare_launch')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("${t(c, 'dev_buy')}  $devPurchase", style: strong),
            for (final text in buyGroups) Text(text, style: strong),
            if (purchaseToken != null) ...[
              SelectableText('付款代币 $purchaseToken', style: mono),
              if (hasDevPurchase)
                SelectableText(
                  'Dev 预购授权对象 ${switch (widget.kind) {
                    _Kind.four => fourManager,
                    _Kind.flap => flapForm?.vault == null ? flapPortal : flapVaultPortal,
                    _Kind.genius => geniusM52LaunchAndBuy,
                  }}',
                  style: mono,
                ),
              if (buyGroups.isNotEmpty && migrate && widget.kind == _Kind.four)
                SelectableText('外盘底池币授权对象 $fourPancakeRouter', style: mono),
              const Text('额度不足时，先独立提交本次预购所需额度的授权。授权确认后才发送创建交易。'),
            ],
            if (geniusPolicy != null) ...[
              Text(
                'Genius m5.2 · BSC · ${ctl('symbol').text.trim()}',
                style: strong,
              ),
              Text(
                '创作者买税 ${geniusPolicy.buyBps / 100}% · 卖税 ${geniusPolicy.sellBps / 100}%',
              ),
              if (geniusFoundation) const Text('收益份额将发送到 Genius Foundation'),
              if (geniusPolicy.integrator.toLowerCase() != zeroAddress)
                SelectableText(
                  '集成方从创作者收益中分成 · ${geniusPolicy.integrator}',
                  semanticsLabel: '集成方从创作者收益中分成 · ${geniusPolicy.integrator}',
                ),
              if (alphaQuote != null)
                Text(
                  '开通 Alpha 费用  ${formatUnits(alphaQuote.priceWei, 18, maxFraction: 18)} BNB',
                  style: strong,
                ),
              const SizedBox(height: 8),
            ],
            if (flapForm != null) ...[
              Text(
                'Flap V${flapForm.tokenVersion} · BSC · ${flapForm.symbol}',
                style: strong,
              ),
              const SizedBox(height: 8),
            ],
            if (widget.kind == _Kind.four)
              Text(
                'Four.meme · BSC · ${ctl('symbol').text.trim()}',
                style: strong,
              ),
            if (tip > BigInt.zero)
              Text(
                '${t(c, 'tip')} ${formatUnits(tip, 18, maxFraction: 18)} BNB',
              ),
            if (flapForm?.vault case final vault?) ...[
              const Divider(height: 24),
              Text(
                flapForm!.nonTax
                    ? '金库收益 · 100% 可分配 LP 手续费'
                    : '使用金库 · 税收分配 ${formatUnits(BigInt.from(flapForm.marketingBps), 2)}%',
                style: strong,
              ),
              const SizedBox(height: 6),
              SelectableText(
                vault.factory,
                semanticsLabel: vault.factory,
                style: mono,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < vault.rows.length; i++)
                for (final field in vault.info.schema.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${vault.info.schema.isArray ? '${i + 1}. ' : ''}${field.name}：${vault.rows[i][field.name] ?? ''}',
                    ),
                  ),
              if (flapForm.dividendToken != null)
                SelectableText(
                  '分红资产：${flapForm.dividendToken}',
                  semanticsLabel: '分红资产：${flapForm.dividendToken}',
                  style: mono,
                ),
              if (!flapForm.nonTax)
                Text(
                  '分红最低持仓 ${formatUnits(flapForm.minimumShare, 18)} 枚',
                  style: muted,
                ),
              if (flapForm.vaultGasBudget > BigInt.zero)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '另需预存金库运行费 ${formatUnits(flapForm.vaultGasBudget, 18)} BNB，与发币一并提交；若预存成功但发币失败，款项不会自动退回。',
                    style: strong.copyWith(color: UiStyle.action),
                  ),
                ),
              for (final warning in _vaultWarnings)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    warning,
                    style: const TextStyle(
                      color: UiStyle.action,
                      fontSize: 14,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                '请核对收益接收者和金库参数，创建后部分设置不可修改。',
                style: TextStyle(color: UiStyle.action, fontSize: 14),
              ),
            ],
            const SizedBox(height: 8),
            const Text('下一步将模拟发币，并在签名前列出本轮 BNB 支出。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t(c, 'cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('继续预检'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: l,
      builder: (context, _) {
        final locked =
            _confirming ||
            l.busy ||
            l.state == LaunchState.pending ||
            l.state == LaunchState.launched;
        // A launch already sent keeps its status and liquidation; only an idle form waits for Four's API.
        if (unavailable != null && !locked) return _unavailable(context);
        final config = Column(
          key: const ValueKey('launch-configuration'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section(t(context, 'basic_info'), [
              _imageRow(context, locked),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 436),
                  child: Row(children: [
                    Expanded(flex: 3, child: _field(t(context, 'token_name'), ctl('name'), locked)),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: _field(t(context, 'token_symbol'), ctl('symbol'), locked)),
                  ]),
                ),
              ),
              _field(t(context, 'description'), ctl('desc'), locked, lines: 3),
              UiAccordion(
                key: ValueKey('launch-socials-${widget.kind.name}'),
                title: t(context, 'socials'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final f in switch (widget.kind) {
                      _Kind.four => ['website', 'twitter', 'telegram'],
                      _Kind.flap => [
                        'website',
                        'twitter',
                        'telegram',
                        'github',
                        'youtube',
                        'debox',
                      ],
                      _Kind.genius => [
                        'website',
                        'twitter',
                        'telegram',
                        'discord',
                        'farcaster',
                      ],
                    })
                      _field(
                        f[0].toUpperCase() + f.substring(1),
                        ctl(f),
                        locked,
                      ),
                  ],
                ),
              ),
            ]),
            _section(
              t(context, 'token_type'),
              _platformFields(context, locked),
            ),
          ],
        );
        final wallets = _walletPanel(context, locked);
        final execution = _section(t(context, 'execution'), [_status(context)]);
        final showResultFirst = l.state == LaunchState.pending ||
            l.state == LaunchState.launched ||
            l.state == LaunchState.failed;
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 860) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showResultFirst) execution,
                  config,
                  wallets,
                  if (!showResultFirst) execution,
                ],
              );
            }
            return Row(
              key: const ValueKey('launch-desktop-columns'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: config),
                const SizedBox(width: 20),
                SizedBox(
                  width: (constraints.maxWidth * .38).clamp(360.0, 460.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showResultFirst) execution,
                      wallets,
                      if (!showResultFirst) execution,
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Read the custom pool token's symbol and decimals; creation will ask Flap for a signed curve.
  Future<void> _useCustomPool() => _guard(() async {
    final a = ctl('customPool').text.trim();
    if (!isAddress(a)) throw const FormatException('请输入有效的底池代币地址');
    final previous = selectedPayment?.address;
    final meta = await launchPaymentMeta(widget.state.api, a);
    if (!mounted || l.busy || _confirming || l.state == LaunchState.pending ||
        l.state == LaunchState.launched || previous != selectedPayment?.address ||
        ctl('customPool').text.trim().toLowerCase() != a.toLowerCase()) return;
    final p = FlapPayment.custom(
      a,
      meta.symbol,
      meta.decimals!,
    );
    setState(() {
      manualPayments = [
        ...manualPayments.where((x) => x.address != p.address),
        p,
      ];
      selectedPayment = p;
      paymentChosen = true;
      mergeFlapCatalogs();
    });
  });

  Widget _configButton(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SmallButton(
        label: t(context, loading ? 'loading' : 'load_config'),
        onPressed: loading ? null : _loadConfig,
      ),
      if (configError != null) ...[
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            configError!,
            style: const TextStyle(color: UiStyle.negative, fontSize: 12),
          ),
        ),
      ],
    ],
  );

  List<Widget> _platformFields(BuildContext context, bool locked) {
    switch (widget.kind) {
      case _Kind.four:
        return [
          _controls([
            _control(
              t(context, 'category'),
              UiSelect<String>(
                value: category,
                semanticLabel: t(context, 'category'),
                options: [for (final x in fourLabels) (x, x)],
                onChanged: locked ? null : (v) => setState(() => category = v),
              ),
            ),
            _control(
              t(context, 'pool_token'),
              raised.isEmpty
                  ? _configButton(context)
                  : UiSelect<String>(
                      value: selectedRaised?.address,
                      semanticLabel: t(context, 'pool_token'),
                      options: [for (final r in raised) (r.address, r.display)],
                      onChanged: locked
                          ? null
                          : (v) => setState(
                              () {
                                selectedRaised = raised.firstWhere((r) => r.address == v);
                                _syncFundingCurrency();
                              },
                            ),
                    ),
            ),
            OptionPair<bool>(
              options: [
                (false, t(context, 'normal_token')),
                (true, t(context, 'tax_token')),
              ],
              value: taxToken,
              onChanged: locked ? null : (v) => setState(() {
                taxToken = v;
                if (!v) _setPurchaseMode(false);
              }),
            ),
          ]),
          if (taxToken) ..._taxFields(context, locked, four: true),
        ];
      case _Kind.flap:
        return [
          _controls([
            _control(
              t(context, 'pool_token'),
              payments.isEmpty
                  ? _configButton(context)
                  : UiSelect<String>(
                      value: selectedPayment?.address,
                      semanticLabel: t(context, 'pool_token'),
                      options: [
                        for (final p in payments)
                          (
                            p.address,
                            [if (p.name.isNotEmpty && p.name != p.symbol) p.name, p.symbol,
                              if (p.category == 'custom') '自定义'].join(' · '),
                          ),
                      ],
                      onChanged: locked
                          ? null
                          : (v) => setState(() {
                              paymentChosen = true;
                              selectedPayment = payments.firstWhere(
                                (p) => p.address == v,
                              );
                              _syncFundingCurrency();
                            }),
                    ),
            ),
            OptionPair<bool>(
              options: [
                (false, '${t(context, 'tax_token')} V6'),
                (true, '${t(context, 'non_tax_token')} V7'),
              ],
              value: nonTax,
              onChanged: locked ? null : (v) => setState(() => nonTax = v),
            ),
          ]),
          const SizedBox(height: 12),
          for (final entry in catalogNotices.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Flexible(child: Text(entry.value.message,
                    style: entry.value.failed ? muted.copyWith(color: UiStyle.negative) : muted)),
                  if (entry.value.retry) ...[
                    const SizedBox(width: 8),
                    SmallButton(
                      label: '重试',
                      onPressed: loading ? null : () => loadFlapCatalog(entry.key),
                    ),
                  ],
                ],
              ),
            ),
          _field(
            t(context, 'custom_pool'),
            ctl('customPool'),
            locked,
            wrapAddress: true,
          ),
          if (ctl('customPool').text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SmallButton(
                label: t(context, 'use_custom_pool'),
                onPressed: locked ? null : _useCustomPool,
              ),
            ),
          if (!nonTax) ...[
            ..._taxFields(context, locked, four: false),
            _field(
              '创作者收款地址（留空使用 Dev）',
              ctl('flapBeneficiary'),
              locked,
              wrapAddress: true,
            ),
            UiAccordion(
              key: const ValueKey('flap-dividend-asset'),
              title: '分红资产',
              child: _field(
                '分红代币（留空使用底池代币）',
                ctl('flapDividendToken'),
                locked,
                wrapAddress: true,
              ),
            ),
          ],
          FlapVaultEditor(
            key: _vaultEditor,
            api: widget.state.api,
            nonTax: nonTax,
            holderSettings: nonTax
                ? _controls([
                    _field(
                      t(context, 'min_holding'),
                      ctl('minShareNT'),
                      locked,
                      width: 200,
                    ),
                  ])
                : null,
            quoteToken: selectedPayment?.address ?? zeroAddress,
            quoteSymbol: selectedPayment?.symbol ?? 'BNB',
            quoteDecimals: selectedPayment?.decimals ?? 18,
            locked: locked || selectedPayment == null,
          ),
          const SizedBox(height: 12),
          _controls([
            _field(
              '防挖提卖保护期',
              ctl('flapAntiFarmerDays'),
              locked,
              unit: '天',
              width: 160,
            ),
          ]),
          Text('0–365 天；0 为关闭。', style: muted),
        ];
      case _Kind.genius:
        return [
          Text('Genius m5.2', style: strong),
          const SizedBox(height: 8),
          _control(
            t(context, 'pool_token'),
            UiSelect<String>(
              value: customGeniusQuote ? 'custom' : geniusQuote,
              semanticLabel: 'Genius 底池目录',
              maxWidth: 520,
              options: [
                ('custom', '自定义底池币'),
                for (final row in geniusQuoteLabels.entries)
                  (row.key, '${row.value} · ${row.key}'),
              ],
              onChanged: locked
                  ? null
                  : (v) => setState(() {
                      customGeniusQuote = v == 'custom';
                      if (!customGeniusQuote) ctl('quote').text = v;
                      _syncFundingCurrency();
                    }),
            ),
          ),
          const SizedBox(height: 8),
          if (customGeniusQuote)
            _field(
              t(context, 'quote_address'),
              ctl('quote'),
              locked,
              wrapAddress: true,
            ),
          _check(
            '收益份额交给 Genius Foundation',
            geniusFoundation,
            locked,
            (v) => geniusFoundation = v,
          ),
          if (!geniusFoundation)
            _field(
              t(context, 'creator_recipient'),
              ctl('creator'),
              locked,
              wrapAddress: true,
            ),
          _controls([
            _field('创作者买税', ctl('geniusBuy'), locked, unit: '%', width: 145),
            _field('创作者卖税', ctl('geniusSell'), locked, unit: '%', width: 145),
          ]),
          UiAccordion(
            title: '税收分配与期限',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _controls([
                  _field(
                    '销毁',
                    ctl('geniusBurn'),
                    locked,
                    unit: '%',
                    width: 130,
                  ),
                  _field(
                    '持币奖励',
                    ctl('geniusRewards'),
                    locked,
                    unit: '%',
                    width: 140,
                  ),
                  _field(
                    '流动性',
                    ctl('geniusLiquidity'),
                    locked,
                    unit: '%',
                    width: 140,
                  ),
                  _field(
                    '期限（0 为永久）',
                    ctl('geniusYears'),
                    locked,
                    unit: '年',
                    width: 160,
                  ),
                ]),
                if (!geniusFoundation)
                  Text('剩余份额归收益地址。多个收益地址可按比例分配。', style: muted),
                if (!geniusFoundation)
                  _field(
                    '多地址分配（每行：地址 百分比）',
                    ctl('geniusRecipients'),
                    locked,
                    lines: 2,
                    wrapAddress: true,
                  ),
                _control(
                  '奖励资产',
                  UiSelect<int>(
                    value: geniusRewardMode,
                    options: const [(0, '底池代币'), (1, '本代币'), (2, '指定代币')],
                    onChanged: locked
                        ? null
                        : (v) => setState(() => geniusRewardMode = v),
                  ),
                ),
                if (geniusRewardMode == 2)
                  _field(
                    '奖励代币合约',
                    ctl('geniusRewardAsset'),
                    locked,
                    wrapAddress: true,
                  ),
                _field('奖励最低持仓', ctl('geniusMinimum'), locked, width: 180),
                _check(
                  '启用 LP 手续费奖励',
                  geniusLpRewards,
                  locked,
                  (v) => geniusLpRewards = v,
                ),
                _field(
                  '集成方地址（可选）',
                  ctl('geniusIntegrator'),
                  locked,
                  wrapAddress: true,
                ),
              ],
            ),
          ),
          _check(t(context, 'alpha'), alpha, locked, (v) => alpha = v),
          _field(
            t(context, 'exemptions'),
            ctl('exempt'),
            locked,
            lines: 2,
            wrapAddress: true,
          ),
        ];
    }
  }

  GeniusConfigurablePolicy _geniusPolicy() {
    String number(String key) =>
        ctl(key).text.trim().isEmpty ? '0' : ctl(key).text.trim();
    int bps(String key) => parseUnits(number(key), 2).toInt();
    final recipients = <(String, int)>[];
    for (final line
        in (geniusFoundation ? '' : ctl('geniusRecipients').text).split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'[\s,，]+'));
      if (parts.length != 2) throw const FormatException('收益分配请每行输入一个地址和百分比');
      recipients.add((parts[0], parseUnits(parts[1], 2).toInt()));
    }
    final integrator = ctl('geniusIntegrator').text.trim();
    return GeniusConfigurablePolicy(
      buyBps: bps('geniusBuy'),
      sellBps: bps('geniusSell'),
      burnBps: bps('geniusBurn'),
      rewardsBps: bps('geniusRewards'),
      liquidityBps: bps('geniusLiquidity'),
      recipients: recipients,
      feeYears: int.parse(number('geniusYears')),
      rewardMode: geniusRewardMode,
      rewardAsset: geniusRewardMode == 2
          ? ctl('geniusRewardAsset').text.trim()
          : zeroAddress,
      minimumHolding: parseUnits(number('geniusMinimum'), 18),
      lpRewards: geniusLpRewards,
      integrator: integrator.isEmpty ? zeroAddress : integrator,
    );
  }

  List<Widget> _taxFields(
    BuildContext context,
    bool locked, {
    required bool four,
  }) => [
    const SizedBox(height: 10),
    _controls([
      for (final (k, name) in [('buyTax', 'buy_tax'), ('sellTax', 'sell_tax')])
        if (four)
          _control(
            t(context, name),
            UiSelect<String>(
              value: ctl(k).text,
              semanticLabel: t(context, name),
              options: [
                for (final v in ['1', '3', '5', '10']) (v, '$v%'),
              ],
              onChanged: locked ? null : (v) => setState(() => ctl(k).text = v),
            ),
          )
        else
          _field(t(context, name), ctl(k), locked, width: 140),
    ]),
    if (!four) Text('单边可设为 0 或 1%–10%，买卖税至少一项大于 0。', style: muted),
    const SizedBox(height: 8),
    Text(t(context, 'tax_split'), style: label),
    const SizedBox(height: 6),
    _controls([
      for (final (k, name)
          in four
              ? [
                  ('burn', 'burn'),
                  ('divide', 'dividend'),
                  ('liq', 'liquidity'),
                  ('rec', 'recipient'),
                ]
              : [
                  ('mkt', 'marketing'),
                  ('burn', 'burn'),
                  ('divide', 'dividend'),
                  ('liq', 'liquidity'),
                ])
        SizedBox(
          width: 120,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(context, name), style: muted),
              const SizedBox(height: 4),
              IgnorePointer(
                ignoring: locked,
                child: ExcludeFocus(
                  excluding: locked,
                  child: InputBox(controller: ctl(k), number: true),
                ),
              ),
            ],
          ),
        ),
    ]),
    const SizedBox(height: 10),
    ListenableBuilder(
      listenable: Listenable.merge([
        for (final k in ['burn', 'divide', 'liq', if (four) 'rec' else 'mkt'])
          ctl(k),
      ]),
      builder: (context, _) {
        final entries = [
          for (final k in ['burn', 'divide', 'liq', if (four) 'rec' else 'mkt'])
            ctl(k).text.trim(),
        ];
        try {
          final values = entries
              .map((v) => parseUnits(v, four ? 0 : 2))
              .toList();
          final maximum = four ? BigInt.from(100) : BigInt.from(10000);
          if (values.any((v) => v.isNegative || v > maximum))
            throw const FormatException();
          final total = values.fold(BigInt.zero, (sum, value) => sum + value);
          final unit = four ? 0 : 2;
          final diff = total - maximum;
          final allocated = '已分配 ${formatUnits(total, unit)}%';
          return Text(
            diff == BigInt.zero
                ? allocated
                : '$allocated · ${diff.isNegative ? '剩余' : '超出'} ${formatUnits(diff.abs(), unit)}%',
            style: diff == BigInt.zero
                ? muted
                : const TextStyle(color: UiStyle.negative),
          );
        } on Object {
          return const Text(
            '请填写 0–100% 范围内的有效分配比例',
            style: TextStyle(color: UiStyle.negative),
          );
        }
      },
    ),
    const SizedBox(height: 6),
    if (four)
      _field(
        t(context, 'recipient_address'),
        ctl('recAddr'),
        locked,
        wrapAddress: true,
      ),
    _controls([
      _field(t(context, 'min_holding'), ctl('minShare'), locked, width: 200),
    ]),
  ];

  Widget _check(String text, bool v, bool locked, ValueChanged<bool> set) =>
      Row(
        children: [
          Checkbox(
            value: v,
            onChanged: locked ? null : (x) => setState(() => set(x ?? false)),
          ),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      );

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Panel(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  /// Compact independent controls share a row when they fit. Long fields stay
  /// outside this flow so addresses, descriptions and private-key editors retain
  /// the full reading/editing width on desktop and stack naturally on phones.
  Widget _controls(List<Widget> children) => Wrap(
    spacing: 16,
    runSpacing: 10,
    crossAxisAlignment: WrapCrossAlignment.end,
    children: children,
  );

  Widget _control(String title, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: label),
      const SizedBox(height: 6),
      child,
    ],
  );

  Widget _field(
    String name,
    TextEditingController ctl,
    bool locked, {
    int lines = 1,
    bool wrapAddress = false,
    String? unit,
    double? width,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: label),
          const SizedBox(height: 6),
          TextField(
            controller: ctl,
            enabled: !locked,
            onChanged: (_) => setState(() {
              if (identical(ctl, c['quote'])) _syncFundingCurrency();
            }),
            minLines: lines,
            maxLines: wrapAddress ? null : lines,
            keyboardType: wrapAddress && lines == 1 ? TextInputType.text : null,
            textInputAction: wrapAddress && lines == 1
                ? TextInputAction.done
                : null,
            inputFormatters: wrapAddress && lines == 1
                ? [FilteringTextInputFormatter.singleLineFormatter]
                : null,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              suffixText: unit,
              contentPadding: UiStyle.fieldPadding,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _imageRow(BuildContext context, bool locked) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: UiStyle.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: image == null
              ? const Icon(Icons.image_outlined, color: UiStyle.muted)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(
                    Uint8List.fromList(image!.bytes),
                    fit: BoxFit.cover,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(t(context, 'token_image'), style: label),
                  SmallButton(
                    label: t(context, 'pick_image'),
                    onPressed: locked ? null : _pickImage,
                  ),
                ],
              ),
              if (image != null)
                Text(
                  '${image!.filename} · ${(image!.bytes.length / 1024).toStringAsFixed(0)} KB${geniusLogo != null ? ' · ${t(context, 'image_ready')}' : ''}',
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _walletPanel(BuildContext context, bool locked) {
    final address = _creator?.address;
    final fixedInner = widget.kind == _Kind.four && !taxToken;
    final inner = t(context, 'internal_mode');
    final devWallet = t(context, 'dev_wallet');
    final devAmount = t(context, 'dev_buy');

    Widget inline(String title, Widget control) => Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title, style: label),
        control,
      ],
    );

    return Padding(
      key: const ValueKey('launch-wallets'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fixedInner) ...[
              Text(inner, style: panelTitle),
              const SizedBox(height: 4),
              const Text('普通币由 Four 平台迁移。选择税币可配置同块外盘首买。', style: muted),
            ] else
              Semantics(
                container: true,
                explicitChildNodes: true,
                label: t(context, 'launch_mode'),
                child: SubTabs<bool>(
                  options: [(false, inner), (true, t(context, 'external_mode'))],
                  value: migrate,
                  horizontalPadding: 8,
                  onChanged: locked ? null : (v) => setState(() => _setPurchaseMode(v)),
                ),
              ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: locked ? null : () => _editCreator(devWallet),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: MediaQuery.sizeOf(context).width < 600 ? 40 : 32,
                ),
                child: Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runAlignment: WrapAlignment.center,
                  children: [
                    Text(devWallet, style: strong),
                    if (address == null)
                      Text(t(context, 'not_filled'), style: muted),
                    Text(t(context, 'edit'), style: label),
                  ],
                ),
              ),
            ),
            if (address != null) ...[
              const SizedBox(height: 4),
              SelectableText(address, semanticsLabel: address, style: mono),
              if (widget.active && !locked) ...[
                const SizedBox(height: 4),
                LaunchDevBalance(
                  api: widget.state.api,
                  address: address,
                  paymentToken: _purchaseToken,
                ),
              ],
            ],
            const SizedBox(height: 16),
            if (_poolToken != null) ...[
              inline(
                '首买付款币',
                OptionPair<bool>(
                  compact: true,
                  options: [(true, 'BNB'), (false, _poolUnit)],
                  value: payWithBnb,
                  onChanged: locked ? null : _selectPayment,
                ),
              ),
              const SizedBox(height: 8),
            ],
            inline(
              devAmount,
              SizedBox(
                width: 148,
                child: Semantics(
                  label: devAmount,
                  child: InputBox(
                    key: const ValueKey('launch-dev-amount'),
                    controller: ctl('devAmount', '0'),
                    enabled: !locked,
                    number: true,
                    suffix: _purchaseUnit,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _buyerGroup(false, locked),
                if (migrate) _buyerGroup(true, locked),
              ],
            ),
            if (widget.kind == _Kind.genius && insideCount > 0)
              _check(
                t(context, 'exempt_internal'),
                exemptInside,
                locked,
                (v) => exemptInside = v,
              ),
            if (!widget.actionsInSidebar)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: LaunchTipField(draft: _tip, launcher: l),
              ),
            _budget(),
          ],
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final s = l.session;
    final isCurrentToken = s != null &&
        widget.state.token?.address.toLowerCase() == s.token.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (l.stage.isNotEmpty || l.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              l.error ?? l.stage,
              style: l.error != null ? muted.copyWith(color: UiStyle.negative) : muted,
            ),
          ),
        if (l.state == LaunchState.launched && s != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${t(context, 'launched')} · ${s.symbol}',
                  style: panelTitle,
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => ClipboardFeedback.copy(
                    context,
                    s.token,
                    successLabel: t(context, 'copied'),
                  ),
                  child: Text(
                    s.token,
                    style: mono,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isCurrentToken
                      ? '已设为当前代币 · BSC'
                      : '注意：当前代币尚未切换到 ${s.symbol}，请勿误交易旧币。',
                  style: isCurrentToken ? muted : strong.copyWith(color: UiStyle.action),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    PrimaryButton(
                      label: t(context, 'trade_this'),
                      onPressed: () => _guard(() async {
                        await widget.state.adoptLaunchToken(s.token);
                        if (!mounted) return;
                        widget.onTrade();
                      }),
                    ),
                  ],
                ),
                if (!widget.actionsInSidebar)
                  LaunchRoundControls(state: widget.state, launcher: l),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: l.busy || l.pendingLiquidation ? null : () => _guard(() async => l.reset()),
                    child: Text(t(context, 'next_round')),
                  ),
                ),
              ],
            ),
          ),
        if (l.liquidationRemainders.isNotEmpty)
          Material(type: MaterialType.transparency, child: ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('清仓换币结余'),
            children: [for (final line in l.liquidationRemainders) SelectableText(line, style: mono)])),
        if (l.state == LaunchState.pending)
          PrimaryButton(
            label: t(context, 'query_tx'),
            onPressed: () => _guard(l.query),
          ),
        if (l.state == LaunchState.idle ||
            l.state == LaunchState.failed ||
            l.state == LaunchState.preparing)
          PrimaryButton(
            label: t(context, 'prepare_launch'),
            busy: l.busy || _checkingConfirmation,
            onPressed: _creator == null || _confirming ? null : _launch,
          ),
        if (l.transactions.isNotEmpty)
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              key: ValueKey(('launch-receipts', l.transactions.first)),
              tilePadding: EdgeInsets.zero,
              title: Text('${t(context, 'tx_list')} · ${l.transactions.length}'),
              children: [
                for (final tx in l.transactions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(tx.label)),
                          _Badge(status: tx.status),
                        ]),
                        if (tx.hash != null) SelectableText(tx.hash!, style: mono),
                        if (tx.receipt?['blockNumber'] case final String number)
                          Text(
                            '区块 ${BigInt.tryParse(number) ?? number} · 交易位置 ${BigInt.tryParse("${tx.receipt?['transactionIndex']}") ?? "未知"}',
                            style: muted,
                          ),
                        if (tx.actualNetworkFee case final fee?)
                          Text(
                            '实付网络费 ${formatUnits(fee, 18, maxFraction: 18)} BNB',
                            style: muted,
                          ),
                        if (tx.delivered case final amount?)
                          Text(
                            tx is LaunchFundingTx
                                ? '兑换净到账 ${formatUnits(amount, tx.asset.decimals!, maxFraction: tx.asset.decimals!)} ${tx.asset.symbol}'
                                : '首买净到账 ${formatUnits(amount, 18, maxFraction: 18)} ${l.session?.symbol ?? ""}',
                            style: muted,
                          ),
                        if (tx is LaunchFundingTx && tx.status == 'confirmed')
                          Text(
                            switch (tx.confirmedSettlement) {
                              (spent: final used, remaining: final left) =>
                                '首买实付 ${formatUnits(used, tx.asset.decimals!, maxFraction: tx.asset.decimals!)} ${tx.asset.symbol} · 本笔结余 ${formatUnits(left, tx.asset.decimals!, maxFraction: tx.asset.decimals!)} ${tx.asset.symbol}',
                              null => '本笔底池币结余待核实',
                            },
                            style: muted,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

String _builderTipDetails(BuildContext context, BigInt amount, String recipient) =>
    '${t(context, 'tip_per_bundle')} · ${formatUnits(amount, 18, maxFraction: 18)} BNB\n'
    '${t(context, 'recipient_address')}  $recipient';

// A platform's draft is shared by its form and sidebar. The launch confirmation
// locks the same value in both layouts until the review has finished.
class LaunchTipDraft extends TextEditingController {
  LaunchTipDraft() : super(text: '0');
  bool _confirming = false;
  bool get confirming => _confirming;
  set confirming(bool value) {
    if (_confirming == value) return;
    _confirming = value;
    notifyListeners();
  }
}

class LaunchTipField extends StatelessWidget {
  const LaunchTipField({super.key, required this.draft, required this.launcher});
  final LaunchTipDraft draft;
  final Launcher launcher;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (_, _) {
      final submitted = launcher.state == LaunchState.pending || launcher.state == LaunchState.launched;
      final tip = launcher.session?.tip;
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: SizedBox(
          width: 160,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(context, 'tip'), style: label),
              const SizedBox(height: 6),
              if (submitted && tip != null)
                Text('${formatUnits(tip, 18, maxFraction: 18)} BNB')
              else
                TextField(
                  controller: draft,
                  enabled: !submitted && !draft.confirming && !launcher.busy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    suffixText: 'BNB',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class LaunchRoundControls extends StatelessWidget {
  const LaunchRoundControls({
    super.key,
    required this.state,
    required this.launcher,
    this.showIdentity = false,
  });

  final AppState state;
  final Launcher launcher;
  final bool showIdentity;

  @override
  Widget build(BuildContext context) {
    final l = launcher;
    final s = l.session;
    if (l.state != LaunchState.launched || s == null) return const SizedBox.shrink();
    final knownPoolSymbol = s.poolSymbol?.trim() ?? geniusQuoteLabels[s.poolToken.toLowerCase()] ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showIdentity) ...[
          Text('${t(context, 'liquidate')} · ${s.symbol} · ${l.label}', style: strong),
          SelectableText(s.token, style: mono),
          const SizedBox(height: 6),
        ],
        if (s.poolToken.toLowerCase() != zeroAddress) ...[
          const SizedBox(height: 8),
          Text(t(context, 'liquidate_asset'), style: muted),
          FutureBuilder<String?>(
            key: ObjectKey(s),
            initialData: knownPoolSymbol,
            future: knownPoolSymbol.isEmpty ? s.lookupPoolSymbol(l.api) : null,
            builder: (context, snapshot) {
              final symbol = snapshot.data ?? '';
              final label = symbol.isEmpty ? s.poolToken
                  : symbol.toUpperCase() == 'BNB' ? '$symbol · ${s.poolToken}' : symbol;
              return UiSelect<bool>(
                value: l.receivePoolToken,
                semanticLabel: t(context, 'liquidate_asset'),
                options: [(false, 'BNB'), (true, label)],
                onChanged: l.busy || l.pendingLiquidation ? null : l.selectLiquidationOutput,
              );
            },
          ),
        ],
        const SizedBox(height: 8),
        PrimaryButton(
          label: l.pendingLiquidation ? '查询原清仓交易' : t(context, 'liquidate'),
          busy: l.checkingLiquidation,
          onPressed: l.busy ? null : () => _liquidate(context),
        ),
        if (!l.pendingLiquidation)
          Text(t(context, 'approval_check_hint'), style: muted),
        if (l.slowLiquidation)
          QuoteWaitNotice(cancel: l.cancelLiquidationPreview),
      ],
    );
  }

  Future<void> _liquidate(BuildContext context) async {
    final l = launcher;
    final settings = state.impactSettings;
    final session = l.session;
    if (session == null) return;
    try {
      await withWalletUse(
        context,
        state,
        owner: l,
        label: '${l.label} · ${t(context, 'liquidate')}',
        addresses: session.liquidationWallets.map((w) => w.address),
        action: () async {
          final prep = await l.prepareLiquidation();
          if (context.mounted) await _confirmLiquidation(context, prep, settings);
        },
      );
    } on PreviewCancelled {
      return;
    } on Object catch (e) {
      if (context.mounted) await showError(context, e);
    }
  }

  Future<void> _confirmLiquidation(
    BuildContext context,
    PreparedRound prep,
    ImpactSettings settings,
  ) async {
    final l = launcher;
    final session = l.session;
    if (session == null) return;
    final symbol = session.symbol;
    final settlement = l.liquidationSettlement;
    final unit = settlement?.symbol ?? 'BNB';
    final precision = settlement?.decimals ?? 18;
    final rows = prep.amounts.entries.toList();
    final ok = await showUiDialog<bool>(
      context: context,
      builder: (c) => UiDialog(
        title: Text(t(c, 'liquidate')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${l.label} · BSC · $symbol', style: strong),
            SelectableText(session.token, style: mono),
            const SizedBox(height: 8),
            if (session.tip > BigInt.zero)
              Text(_builderTipDetails(c, session.tip, bscBundleTipRecipient)),
            Text(
              '${t(c, 'wallets')} ${prep.amounts.length} · ${formatUnits(prep.inputTotal, 18, maxFraction: 18)} $symbol',
            ),
            const SizedBox(height: 4),
            Text(
              '${t(c, 'expected_receive')} ${prep.quotedOutput == null ? t(c, 'not_quoted') : '${formatUnits(prep.quotedOutput!, precision, maxFraction: precision)} $unit'}',
            ),
            const SizedBox(height: 4),
            Text(
              '${t(c, 'price_impact')} ${prep.impact == null ? t(c, 'not_quoted') : '${prep.impact!.toStringAsFixed(2)}%'}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: (prep.impact ?? 0) > settings.bundle
                    ? UiStyle.negative
                    : UiStyle.text,
              ),
            ),
            const SizedBox(height: 8),
            if (settlement != null) SelectableText(settlement.address, style: mono),
            Text(t(c, 'liquidate_hint').replaceAll('{asset}', unit), style: muted),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                child: Text(t(c, 'liquidate_wallet_details')),
                onPressed: () => showUiDialog<void>(
                  context: c,
                  builder: (d) => UiDialog(
                    title: Text(t(d, 'liquidate_wallet_details')),
                    content: SizedBox(
                      height: 300,
                      child: ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, i) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(checksumAddress(rows[i].key), style: mono),
                            Text('${formatUnits(rows[i].value, 18, maxFraction: 18)} $symbol'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
    if (ok != true || !context.mounted) return;
    final review = ImpactReview(
      SendMode.bundle,
      prep.impact,
      settings,
      v4: prep.v4ImpactUnavailable,
      canConfirmUnknown: prep.canConfirmUnknown,
    );
    if (!await confirmImpact(context, review) || !context.mounted) return;
    await l.liquidate(prep, settings.bundle, review.needsConfirmation);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      'confirmed' => (t(context, 'ts_confirmed'), UiStyle.positive),
      'reverted' => (t(context, 'ts_failed'), UiStyle.negative),
      'purchase_unproven' => ('首买到账未核实', UiStyle.negative),
      'alpha_unproven' => ('Alpha 付款未核实', UiStyle.negative),
      'protocol_unproven' => ('平台事件未核实', UiStyle.negative),
      'order_mismatch' => ('区块或顺序不符', UiStyle.negative),
      'not_included' ||
      'rejected' ||
      'not_submitted' => (t(context, 'ts_not_received'), UiStyle.negative),
      'submitted' => (t(context, 'ts_submitted'), UiStyle.muted),
      'unknown' => (t(context, 'ts_unknown'), UiStyle.action),
      _ => (t(context, 'ts_waiting'), UiStyle.muted),
    };
    return Text(text, style: muted.copyWith(color: color));
  }
}
