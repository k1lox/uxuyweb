import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../exec/launch.dart' show Launcher, LaunchState;
import '../state/app_state.dart';
import 'batch_group_help.dart';
import 'batch_page.dart';
import 'node_latency.dart';
import 'clipboard_feedback.dart';
import 'folder_backup_control.dart';
import 'floating_log.dart';

import 'launch_page.dart';
import 'theme.dart';
import 'tools_page.dart';
import 'holding_ratio_page.dart';
import 'widgets.dart';

export 'floating_log.dart' show LogBall, LogWindow;

/// Standalone web workspace. Forms stay mounted when navigating or resizing.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state, this.onExit});
  final AppState state;
  final VoidCallback? onExit;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int page = 0;
  int platform = 0;
  final _tips = List.generate(3, (_) => LaunchTipDraft());
  final _walletTools = GlobalKey<ToolsPageState>();

  WalletTool get selectedTool => _walletTools.currentState?.selectedTool ?? WalletTool.generate;

  @override
  void dispose() {
    for (final tip in _tips) {
      tip.dispose();
    }
    super.dispose();
  }

  void navigate(int target, {int? launch, WalletTool? tool}) {
    final destination = switch (target) {
      0 => [WorkspacePage.four, WorkspacePage.flap, WorkspacePage.genius][launch ?? platform],
      1 => WorkspacePage.batch,
      2 => WorkspacePage.tools,
      3 => WorkspacePage.holding,
      _ => throw RangeError.range(target, 0, 3),
    };
    final reason = widget.state.workspaceBlockReason(destination);
    if (reason != null) {
      UiNotice.show(context, reason);
      return;
    }
    if (tool != null && _walletTools.currentState?.selectTool(tool) != true) {
      UiNotice.show(context, '当前操作进行中，请稍后再切换');
      return;
    }
    setState(() {
      page = target;
      if (launch != null) platform = launch;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return LayoutBuilder(
      builder: (context, box) {
        final desktop = box.maxWidth >= 1000;
        return Scaffold(
          backgroundColor: UxuyColors.background,
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      key: const ValueKey('desktop-sidebar'),
                      width: desktop ? 244 : 0,
                      child: desktop
                          ? _sidebar(context, s)
                          : const SizedBox.shrink(),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _header(context, desktop),
                          if (!desktop) _mobileNav(context),
                          if (!desktop && s.walletBackup != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: FolderBackupControl(
                                backup: s.walletBackup!,
                                pendingOnly: page != 2,
                              ),
                            ),
                          if (!desktop && (page == 1 || page == 2))
                            ListenableBuilder(
                              listenable: s,
                              builder: (_, _) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TokenBar(state: s),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: _launchActions(s),
                                  ),
                                ],
                              ),
                            ),
                          TokenContextNotice(state: s),
                          Expanded(
                            key: const ValueKey('workspace-pages'),
                            child: ListenableBuilder(
                              listenable: s,
                              builder: (context, _) => IndexedStack(
                                index: page,
                                children: [
                                  LaunchPage(
                                    state: s,
                                    active: page == 0,
                                    tips: _tips,
                                    actionsInSidebar: desktop,
                                    selectedPlatform: platform,
                                    onPlatformChanged: (value) => navigate(0, launch: value),
                                    onTrade: () => navigate(1),
                                  ),
                                  BatchPage(state: s, active: page == 1),
                                  ToolsPage(key: _walletTools, state: s, active: page == 2, showTabs: !desktop),
                                  HoldingRatioPage(api: s.api, active: page == 3),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned.fill(
                  child: FloatingLog(
                    log: s.log,
                    onRefresh: s.refreshWalletLedger,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, bool desktop) => Container(
    height: desktop ? 72 : 64,
    padding: EdgeInsets.fromLTRB(desktop ? 28 : 16, 0, desktop ? 84 : 76, 0),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: UiStyle.border)),
    ),
    child: Row(
      children: [
        if (!desktop) ...[
          if (widget.onExit != null)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onExit,
            ),
          Image.asset(
            'assets/images/uxuy_logo_light.png',
            package: 'uxuy_trade',
            width: 82,
          ),
          const SizedBox(width: 16),
        ],
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  !desktop ? 'BSC' : switch (page) {
                    0 => ['Four.meme', 'Flap', 'Genius'][platform],
                    1 => t(context, 'nav_batch'),
                    2 => t(context, selectedTool.name),
                    _ => '控盘率',
                  },
                  style: desktop ? sectionTitle : sectionTitle.copyWith(fontSize: 18),
                ),
              ),
              if (desktop && page == 1) ...[
                const SizedBox(width: 4),
                const BatchGroupHelpButton(),
              ],
            ],
          ),
        ),
        NodeLatency(key: const ValueKey('workspace-node-latency'), api: widget.state.api),
        if (desktop) const SizedBox(width: 12),
        if (desktop)
          ListenableBuilder(
            listenable: widget.state,
            builder: (_, _) {
              final n = widget.state.groups.where((g) => g.running).length;
              const network = 'BSC · BNB · Chain 56';
              return Text(n > 0 ? '$network · $n 组执行中' : network, style: muted);
            },
          ),
      ],
    ),
  );

  Widget _mobileNav(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: SubTabs<int>(
      options: [
        (0, t(context, 'nav_launch')),
        (1, t(context, 'nav_batch')),
        (2, t(context, 'nav_tools')),
        (3, '控盘率'),
      ],
      value: page,
      horizontalPadding: MediaQuery.sizeOf(context).width <= 420 ? 8 : 14,
      selectedAction: page == 1 && MediaQuery.sizeOf(context).width >= 360
          ? const BatchGroupHelpButton()
          : null,
      onChanged: (v) => navigate(v),
    ),
  );

  Widget _sidebar(BuildContext context, AppState s) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: UiStyle.border)),
    ),
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Image.asset(
                    'assets/images/uxuy_logo_light.png',
                    package: 'uxuy_trade',
                    width: 100,
                    height: 30,
                  ),
                ),
                const SizedBox(height: 14),
                const Divider(height: 1, color: UiStyle.border),
                const SizedBox(height: 14),
                Text(t(context, 'nav_launch'), style: muted),
                const SizedBox(height: 6),
                for (var i = 0; i < 3; i++)
                  _item(
                    ['Four.meme', 'Flap', 'Genius'][i],
                    [
                      Icons.rocket_launch_outlined,
                      Icons.bubble_chart_outlined,
                      Icons.auto_awesome_outlined,
                    ][i],
                    page == 0 && platform == i,
                    () => navigate(0, launch: i),
                  ),
                const SizedBox(height: 14),
                const Text('交易工具', style: muted),
                const SizedBox(height: 6),
                _item(
                  t(context, 'nav_batch'),
                  Icons.grid_view_outlined,
                  page == 1,
                  () => navigate(1),
                ),
                for (final tool in WalletTool.values)
                  _item(
                    t(context, tool.name),
                    switch (tool) {
                      WalletTool.generate => Icons.key_outlined,
                      WalletTool.distribute => Icons.call_split_outlined,
                      WalletTool.collect => Icons.call_merge_outlined,
                    },
                    page == 2 && selectedTool == tool,
                    () => navigate(2, tool: tool),
                  ),
                _item(
                  '控盘率',
                  Icons.pie_chart_outline,
                  page == 3,
                  () => navigate(3),
                ),
                if (s.walletBackup != null) ...[
                  const Divider(height: 16, color: UiStyle.border),
                  FolderBackupControl(backup: s.walletBackup!),
                ],
              ],
            ),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 24, color: UiStyle.border),
                ListenableBuilder(
                  listenable: s,
                  builder: (_, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _tokenContext(context, s),
                      _launchActions(s),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _item(String text, IconData icon, bool selected, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected ? UiStyle.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 19,
                    color: selected ? UiStyle.text : UiStyle.muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: 14,
                        color: UiStyle.text,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _launchActions(AppState s) {
    final launchers = <Launcher>[s.four, s.flap, s.genius];
    final selected = launchers[platform];
    final current = s.token?.address.toLowerCase();
    final rounds = (page == 0 ? [selected] : launchers).where((launcher) =>
      launcher.state == LaunchState.launched && launcher.session != null &&
      (page == 0 || launcher.session!.token.toLowerCase() == current),
    ).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (page == 0)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: LaunchTipField(draft: _tips[platform], launcher: selected),
          ),
        for (final launcher in rounds)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LaunchRoundControls(
              state: s,
              launcher: launcher,
              showIdentity: rounds.length > 1 || launcher.session!.token.toLowerCase() != current,
            ),
          ),
      ],
    );
  }

  Widget _tokenContext(BuildContext context, AppState s) {
    final token = s.token;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('当前代币', style: label)),
            IconButton(
              tooltip: s.tokenLockReason != null
                  ? '查看锁定原因'
                  : (token == null ? '选择代币' : '更换代币'),
              visualDensity: VisualDensity.compact,
              icon: Icon(
                s.tokenLockReason != null
                    ? Icons.lock_outline
                    : Icons.edit_outlined,
                size: 17,
                color: s.tokenLockReason != null ? UiStyle.action : null,
              ),
              onPressed: () => openTokenEditor(context, s),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(token?.symbol ?? t(context, 'not_selected'), style: strong),
            if (s.market != null && token != null) Text(s.market!.label, style: muted),
          ],
        ),
        if (token != null) ...[
          if (token.name.trim().isNotEmpty && token.name.trim() != token.symbol.trim()) ...[
            const SizedBox(height: 2),
            Text(token.name, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 4),
          InkWell(
            onTap: () => ClipboardFeedback.copy(
              context,
              token.address,
              successLabel: t(context, 'copied'),
            ),
            child: Text(token.address, style: mono.copyWith(height: 1.5)),
          ),
        ],
      ],
    );
  }
}

Future<void> openTokenEditor(BuildContext context, AppState state) async {
  if (state.tokenLockReason != null) {
    await showTokenLock(context, state);
    return;
  }
  await showUiDialog<void>(
    context: context,
    builder: (_) => TokenSheet(state: state),
  );
}

Future<void> showTokenLock(BuildContext context, AppState state) =>
    showUiDialog<void>(
      context: context,
      builder: (c) => ListenableBuilder(
        listenable: state,
        builder: (_, _) => UiDialog(
          title: const Text('当前代币已锁定'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('BSC · ${state.token?.symbol ?? '尚未选择'}', style: strong),
              if (state.token != null) ...[
                const SizedBox(height: 6),
                SelectableText(
                  state.token!.address,
                  semanticsLabel: '合约地址：${state.token!.address}',
                  style: mono,
                ),
              ],
              const SizedBox(height: 12),
              Text(
                state.tokenLockReason ?? '当前操作已结束，可以关闭后重新选择代币。',
                style: strong,
              ),
              const SizedBox(height: 8),
              const Text('不要刷新页面或关闭窗口。请先完成确认、查询待确认交易，或结束未完成的组。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );

/// Shared warning stays visible when navigating away from the launch page.
class TokenContextNotice extends StatefulWidget {
  const TokenContextNotice({super.key, required this.state});
  final AppState state;

  @override
  State<TokenContextNotice> createState() => _TokenContextNoticeState();
}

class _TokenContextNoticeState extends State<TokenContextNotice> {
  AppState get state => widget.state;
  Object? _dismissedToken;
  String? _dismissedNotice;

  Future<void> _adopt(BuildContext context, String address) async {
    if (state.tokenLockReason != null) {
      await showTokenLock(context, state);
      return;
    }
    try {
      await state.adoptLaunchToken(address);
    } on Object catch (e) {
      if (context.mounted) await showError(context, e);
    }
  }

  Future<void> _chooseLaunch(BuildContext context) => showUiDialog<void>(
    context: context,
    builder: (c) => ListenableBuilder(
      listenable: state,
      builder: (_, _) => UiDialog(
        title: const Text('已发行的新币'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('请核对地址，再选择要作为当前代币的新币。', style: strong),
            for (final token in state.pendingLaunchTokens)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'BSC · ${token.symbol} · ${token.platform}',
                      style: strong,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      token.address,
                      semanticsLabel: '合约地址：${token.address}',
                      style: mono,
                    ),
                    SmallButton(
                      label: '设为当前代币',
                      onPressed: state.tokenSwitching
                          ? null
                          : () async {
                              await _adopt(c, token.address);
                              if (c.mounted &&
                                  state.token?.address.toLowerCase() ==
                                      token.address.toLowerCase()) {
                                Navigator.of(c).pop();
                              }
                            },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final pending = state.pendingLaunchTokens;
      final lock = state.tokenLockReason;
      final notice = state.tokenNotice;
      final canDismiss = pending.isEmpty && lock == null;
      if (canDismiss && (notice == null ||
          (identical(state.token, _dismissedToken) && notice == _dismissedNotice))) {
        return const SizedBox.shrink();
      }
      final newest = pending.isEmpty ? null : pending.last;
      final heading = newest == null
          ? (lock == null
                ? notice!
                : 'BSC · ${state.token?.symbol ?? '尚未选择'} 已锁定')
          : (state.token == null
                ? '新币已发行，尚未设为当前代币，请先核对。'
                : '新币已发行，当前仍为 ${state.token!.symbol}，请勿误交易旧币。');
      return Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('token-context-notice'),
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: canDismiss ? 5 : 9),
          decoration: const BoxDecoration(
            color: UxuyColors.accentSoft,
            border: Border(
              left: BorderSide(color: UiStyle.action, width: 3),
            ),
          ),
          child: Row(
            crossAxisAlignment: canDismiss ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Icon(
                newest == null && lock != null
                    ? Icons.lock_outline
                    : Icons.info_outline,
                size: 18,
                color: UiStyle.action,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(heading, style: strong),
                    if (newest != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '新币 ${newest.symbol} · BSC · ${newest.platform}',
                        style: label,
                      ),
                      SelectableText(
                        newest.address,
                        semanticsLabel: '合约地址：${newest.address}',
                        style: mono,
                      ),
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SmallButton(
                            label: state.tokenSwitching ? '正在读取新币…' : '切换到新币',
                            onPressed: state.tokenSwitching
                                ? null
                                : () => _adopt(context, newest.address),
                          ),
                          if (pending.length > 1)
                            SmallButton(
                              label: '查看全部 ${pending.length} 个新币',
                              onPressed: () => _chooseLaunch(context),
                            ),
                          if (lock != null && !state.tokenSwitching)
                            const Text('其他操作未结束，暂不切换', style: muted),
                        ],
                      ),
                    ] else if (lock != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        lock,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              if (canDismiss)
                IconButton(
                  tooltip: '收起代币提示',
                  onPressed: () => setState(() {
                    _dismissedToken = state.token;
                    _dismissedNotice = notice;
                  }),
                  constraints: BoxConstraints.tightFor(
                    width: MediaQuery.sizeOf(context).width < 600 ? 40 : 32,
                    height: MediaQuery.sizeOf(context).width < 600 ? 40 : 32,
                  ),
                  icon: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Current token, shared by every page. Changing it re-reads all groups' balances.
class TokenBar extends StatelessWidget {
  const TokenBar({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final token = state.token;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: UiStyle.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(token?.symbol ?? t(context, 'current_token'), style: strong),
                    if (token == null)
                      Text(t(context, 'not_selected'), style: muted)
                    else ...[
                      if (token.name.trim().isNotEmpty && token.name.trim() != token.symbol.trim())
                        Text(token.name, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (state.market != null) Text(state.market!.label, style: muted),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SmallButton(
                label: state.tokenLockReason != null
                    ? '已锁定'
                    : t(context, token == null ? 'select_token' : 'change_token'),
                onPressed: () => openTokenEditor(context, state),
              ),
            ],
          ),
          if (token != null)
            InkWell(
              onTap: () => ClipboardFeedback.copy(
                context, token.address, successLabel: t(context, 'copied'),
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(token.address, style: mono.copyWith(color: UiStyle.muted)),
              ),
            ),
        ],
      ),
    );
  }
}

class TokenSheet extends StatefulWidget {
  const TokenSheet({super.key, required this.state});
  final AppState state;
  @override
  State<TokenSheet> createState() => _TokenSheetState();
}

class _TokenSheetState extends State<TokenSheet> {
  final address = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    address.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (busy) return;
    final lock = widget.state.tokenLockReason;
    if (lock != null) {
      setState(() => error = lock);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.state.loadToken(address.text);
      if (!mounted) return;
      // Release the dialog's busy close guard before completing this action.
      setState(() => busy = false);
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = e is FormatException
            ? e.message
            : e is StateError
            ? e.message
            : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => UiDialog(
    width: 460,
    canClose: !busy,
    title: Text(t(context, 'select_token')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('token-address-input'),
          controller: address,
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.text,
          inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
          autofocus: true,
          enabled: !busy && widget.state.tokenLockReason == null,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _load(),
          onChanged: (_) {
            if (error != null) setState(() => error = null);
          },
          decoration: InputDecoration(hintText: t(context, 'token_hint')),
        ),
        const SizedBox(height: 8),
        Text(t(context, 'token_warning'), style: muted),
        if (!busy && widget.state.tokenLockReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              widget.state.tokenLockReason!,
              style: strong.copyWith(color: UiStyle.action),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error!,
                style: const TextStyle(color: UiStyle.negative),
              ),
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.of(context).pop(),
        child: Text(t(context, 'cancel')),
      ),
      PrimaryButton(
        label: t(context, 'confirm'),
        busy: busy,
        onPressed: widget.state.tokenLockReason != null && !busy ? null : _load,
      ),
    ],
  );
}
