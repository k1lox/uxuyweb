import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'widgets.dart';

Future<void> withWalletUse(
  BuildContext context,
  AppState state, {
  required Object owner,
  required String label,
  required Iterable<String> addresses,
  required Future<void> Function() action,
}) async {
  try {
    await state.withWalletUse(
      owner: owner,
      label: label,
      addresses: addresses,
      action: () async {
        if (context.mounted) await action();
      },
    );
  } on WorkspaceConflict catch (conflict) {
    if (context.mounted) await _showConflict(context, conflict);
  }
}

Future<void> resumeGroupWithWalletCheck(
  BuildContext context,
  AppState state,
  GroupBase group,
  VoidCallback resume,
) async {
  try {
    if (state.api.requireFeeFreeService) await state.verifyFinancialService();
    if (!context.mounted) return;
    state.checkWalletUse(group, state.groupWallets(group));
    if (group.status == GroupStatus.paused) resume();
  } on WorkspaceConflict catch (conflict) {
    await _showConflict(context, conflict);
  }
}

Future<void> _showConflict(BuildContext context, WorkspaceConflict conflict) async {
  if (!context.mounted) return;
  if (conflict.wallets.isEmpty) {
    await showError(context, conflict.reason);
    return;
  }
  final entries = conflict.wallets.entries.toList();
  await showUiDialog<void>(
        context: context,
        builder: (c) => UiDialog(
          width: 440,
          scrollable: false,
          title: Text(t(c, 'wallet_overlap')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(c, 'wallet_overlap_detail')),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 12),
                  itemBuilder: (_, index) {
                    final entry = entries[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.value.join(' · '), style: strong),
                        SelectableText(
                          entry.key,
                          semanticsLabel: entry.key,
                          style: mono,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(t(c, 'close_dialog')),
            ),
          ],
        ),
      );
}
