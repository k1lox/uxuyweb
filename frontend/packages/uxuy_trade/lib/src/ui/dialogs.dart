import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'component_theme.dart';

/// Centered dialog with a fixed header and footer,
/// content-only scroll, focus return, Escape cancellation and reduced-motion support.
Future<T?> showUiDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final focus = FocusManager.instance.primaryFocus;
  final route = RawDialogRoute<T>(
    pageBuilder: (c, _, _) => themes.wrap(SafeArea(child: builder(c))),
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x33000000),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    transitionBuilder: uiDialogTransition,
  );
  final value = await navigator.push<T>(route);
  // Callers may dispose field controllers after awaiting us. Keep them alive during exit.
  await route.completed;
  if (focus?.context != null) focus!.requestFocus();
  return value;
}

Widget uiDialogTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final curve = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: curve,
    child: ScaleTransition(
      scale: Tween<double>(begin: .97, end: 1).animate(curve),
      child: child,
    ),
  );
}

class UiDialog extends StatelessWidget {
  const UiDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.width = 480,
    this.canClose = true,
    this.contentPadding,
    this.scrollable = true,
  });
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final double width;
  final bool canClose;
  final EdgeInsetsGeometry? contentPadding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final padding = screen.width < 600 ? 18.0 : 24.0;
    return PopScope(
      canPop: canClose,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                if (canClose) Navigator.of(context).maybePop();
                return null;
              },
            ),
          },
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 16,
            shadowColor: const Color(0x22000000),
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: UiStyle.border),
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: width,
                maxHeight: (screen.height - insets.bottom - insets.top - 48)
                    .clamp(80, double.infinity),
              ),
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(padding, 16, 12, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: DefaultTextStyle.merge(
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: UiStyle.text,
                              ),
                              child: title ?? const SizedBox.shrink(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            tooltip: '关闭弹窗',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: canClose
                                ? () => Navigator.of(context).maybePop()
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: UiStyle.border),
                    if (content != null)
                      Flexible(
                        child: scrollable
                            ? SingleChildScrollView(
                                padding:
                                    contentPadding ?? EdgeInsets.all(padding),
                                child: DefaultTextStyle.merge(
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.5,
                                    color: UiStyle.text,
                                  ),
                                  child: content!,
                                ),
                              )
                            : Padding(
                                padding:
                                    contentPadding ?? EdgeInsets.all(padding),
                                child: content!,
                              ),
                      ),
                    if (actions.isNotEmpty) ...[
                      const Divider(height: 1, color: UiStyle.border),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: padding,
                          vertical: 14,
                        ),
                        child: OverflowBar(
                          spacing: 8,
                          overflowSpacing: 8,
                          alignment: MainAxisAlignment.end,
                          overflowAlignment: OverflowBarAlignment.end,
                          children: [
                            for (var i = 0; i < actions.length; i++)
                              TextButtonTheme(
                                data: TextButtonThemeData(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(76, 36),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    backgroundColor: i == actions.length - 1
                                        ? UiStyle.action
                                        : Colors.transparent,
                                    foregroundColor: i == actions.length - 1
                                        ? Colors.white
                                        : UiStyle.text,
                                    disabledBackgroundColor: UiStyle.surface,
                                    disabledForegroundColor: UiStyle.muted,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge!
                                        .copyWith(
                                          fontSize: 14,
                                          fontWeight: i == actions.length - 1
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                  ),
                                ),
                                child: actions[i],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String uiErrorText(Object error) => error is FormatException
    ? error.message
    : error is StateError
    ? error.message
    : '$error';

/// A compact notice that replaces the previous one.
class UiNotice {
  static OverlayEntry? _entry;
  static void show(
    BuildContext context,
    String text, {
    bool error = false,
    IconData icon = Icons.info_outline,
  }) {
    _close();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (c) => _NoticeLifetime(
        duration: Duration(seconds: error ? 7 : 3),
        onTimeout: _close,
        child: Positioned(
          top: MediaQuery.paddingOf(c).top + 16,
          left: 16,
          right: 16,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: MediaQuery.disableAnimationsOf(c)
                    ? Duration.zero
                    : UiStyle.motion,
                builder: (_, value, child) =>
                    Opacity(opacity: value, child: child),
                child: Material(
                  color: Colors.white,
                  elevation: 6,
                  shadowColor: const Color(0x22000000),
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: UiStyle.border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                      child: Row(
                        children: [
                          Icon(
                            error ? Icons.error_outline : icon,
                            size: 18,
                            color: error ? UiStyle.negative : UiStyle.muted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    (MediaQuery.sizeOf(c).height -
                                            MediaQuery.paddingOf(c).vertical -
                                            MediaQuery.viewInsetsOf(c).bottom -
                                            56)
                                        .clamp(24.0, 240.0),
                              ),
                              child: SingleChildScrollView(
                                primary: false,
                                child: Text(
                                  text,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.5,
                                    color: UiStyle.text,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭提示',
                            onPressed: _close,
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void _close() {
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }
}

class _NoticeLifetime extends StatefulWidget {
  const _NoticeLifetime({
    required this.duration,
    required this.onTimeout,
    required this.child,
  });
  final Duration duration;
  final VoidCallback onTimeout;
  final Widget child;
  @override
  State<_NoticeLifetime> createState() => _NoticeLifetimeState();
}

class _NoticeLifetimeState extends State<_NoticeLifetime> {
  late final Timer timer = Timer(widget.duration, widget.onTimeout);
  @override
  void initState() {
    super.initState();
    timer;
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
