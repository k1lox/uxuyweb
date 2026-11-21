import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dialogs.dart';

/// Show completion only after the clipboard operation succeeds.
/// A shared in-flight guard also prevents two visible CA controls from racing.
abstract final class ClipboardFeedback {
  static bool _busy = false;

  static Future<void> copy(
    BuildContext context,
    String text, {
    required String successLabel,
    VoidCallback? onCopied,
  }) => _copy(
    context,
    () => text,
    successLabel: successLabel,
    onCopied: onCopied,
  );

  /// Ask once before producing sensitive text. Nothing is written or marked
  /// backed up on cancellation, rejection, or an unavailable clipboard.
  static Future<void> confirmed(
    BuildContext context, {
    required Future<bool?> Function() confirm,
    required String Function() text,
    required String successLabel,
    VoidCallback? onCopied,
  }) => _copy(
    context,
    text,
    confirm: confirm,
    successLabel: successLabel,
    onCopied: onCopied,
  );

  static Future<void> _copy(
    BuildContext context,
    String Function() text, {
    required String successLabel,
    Future<bool?> Function()? confirm,
    VoidCallback? onCopied,
  }) async {
    if (_busy || !context.mounted) return;
    _busy = true;
    try {
      if (confirm != null) {
        final approved = await confirm();
        if (approved != true || !context.mounted) return;
      }
      await Clipboard.setData(ClipboardData(text: text()));
      if (context.mounted) {
        onCopied?.call();
        UiNotice.show(context, successLabel, icon: Icons.check_circle_outline);
      }
    } on Object {
      if (context.mounted) {
        UiNotice.show(context, '复制失败，请重试或手动选择文本。', error: true);
      }
    } finally {
      _busy = false;
    }
  }
}
