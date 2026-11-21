import 'package:flutter/material.dart';

import '../wallet/wallet_backup.dart';
import 'widgets.dart';

/// Private keys go only into a directory explicitly selected by this user.
class FolderBackupControl extends StatelessWidget {
  const FolderBackupControl({
    super.key,
    required this.backup,
    this.pendingOnly = false,
  });

  final WalletBackupCoordinator backup;
  final bool pendingOnly;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // The coordinator exposes a sanitized, persistent status for retry.
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([backup, backup.walletLoadProgress]),
    builder: (context, _) {
      final pending = backup.pendingCount;
      if (pendingOnly && pending == 0 && !backup.hasError)
        return const SizedBox.shrink();
      final supported = backup.supported;
      final connected = backup.connected;
      final folder = backup.directoryName;
      final counts = backup.walletLoadProgress.value;
      final progress = counts != null && counts.total > 0 ? counts : null;
      final percent = progress == null ? null : '${progress.checked * 100 ~/ progress.total}%';
      final buttonLabel = connected && folder != null
          ? folder
          : backup.hasError || folder != null
          ? '重新连接文件夹'
          : '连接本地文件夹';
      final String hint;
      if (!supported) {
        hint = '本地备份需要桌面 Google Chrome，请通过 HTTPS 或本机地址打开。';
      } else if (progress != null) {
        hint = '正在载入钱包';
      } else if (backup.loadingWalletArchive) {
        hint = '正在读取钱包列表…';
      } else if (backup.selecting) {
        hint = '正在验证文件夹是否可写…';
      } else if (backup.hasError) {
        final reason = backup.errorMessage!;
        hint = pending > 0 ? '$pending 项待保存 · $reason' : reason;
      } else if (pending > 0) {
        hint = '$pending 项待保存';
      } else if (connected) {
        hint = '已连接 · UAgent-wallets';
      } else {
        hint = '输入和生成的私钥将明文保存，请勿共享。';
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: backup.selecting
                      ? ''
                      : connected
                      ? '更换本地备份文件夹 · $folder'
                      : '选择私人文件夹，明文备份到 UAgent-wallets/wallets.json',
                  child: TextButton(
                    onPressed: supported && !backup.busy
                        ? () => _run(backup.connect)
                        : null,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: UiStyle.text,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size(0, MediaQuery.sizeOf(context).width < 600 ? 40 : 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          connected
                              ? Icons.folder_open_outlined
                              : Icons.create_new_folder_outlined,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            buttonLabel,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (backup.canRetry)
                TextButton(
                  onPressed: backup.busy ? null : () => _run(backup.retry),
                  child: const Text('重试'),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 4, 2),
            child: backup.selecting
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(hint, style: muted.copyWith(color: UiStyle.text)),
                          ),
                          if (percent != null) Text(percent, style: mono),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: progress == null ? null : progress.checked / progress.total,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                        color: UiStyle.action,
                        backgroundColor: UiStyle.surface,
                        semanticsLabel: hint,
                        semanticsValue: percent,
                      ),
                      if (progress != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('已核对 ${progress.checked} / ${progress.total}', style: muted),
                        ),
                    ],
                  )
                : Semantics(
                    liveRegion: backup.hasError,
                    child: Text(
                      hint,
                      style: muted.copyWith(
                        color: backup.hasError ? UiStyle.negative : pending > 0 ? UiStyle.text : UiStyle.muted,
                      ),
                    ),
                  ),
          ),
        ],
      );
    },
  );
}
