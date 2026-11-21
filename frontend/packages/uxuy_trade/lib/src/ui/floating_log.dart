import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../exec/executor.dart';
import 'liquid_log_surface.dart';
import 'widgets.dart';

/// The panel and toggle share their top-right corner. A collapsed ball reserves
/// only its own bounds, so it can reach the left and bottom of the viewport.
class LogGeometry {
  LogGeometry(Size viewport, Offset? anchor, {required bool open}) {
    panelSize = Size(
      math.max(1, math.min(560, viewport.width - 24)),
      math.max(1, math.min(380, viewport.height - 24)),
    );
    diameter = math.min(48, math.min(panelSize.width, panelSize.height));
    final extent = open ? panelSize : Size.square(diameter);
    final preferred =
        anchor ?? Offset(viewport.width - (viewport.width < 584 ? 12 : 20),
            viewport.width < 1000 ? 12 : 16);
    final point = Offset(
      _clamp(preferred.dx - extent.width, viewport.width, extent.width),
      _clamp(preferred.dy, viewport.height, extent.height),
    );
    this.anchor = Offset(point.dx + extent.width, point.dy);
  }

  late final Size panelSize;
  late final double diameter;
  late final Offset anchor;
  Offset get panelPosition => anchor - Offset(panelSize.width, 0);
  Offset get ballPosition => anchor - Offset(diameter, 0);

  static double _clamp(double value, double available, double extent) {
    final remaining = math.max(0.0, available - extent);
    final margin = math.min(12.0, remaining / 2);
    return value.clamp(margin, remaining - margin).toDouble();
  }
}

class FloatingLog extends StatefulWidget {
  const FloatingLog({super.key, required this.log, this.onRefresh});
  final Future<void> Function()? onRefresh;
  final ExecutionLog log;

  @override
  State<FloatingLog> createState() => _FloatingLogState();
}

class _FloatingLogState extends State<FloatingLog>
    with TickerProviderStateMixin {
  late final AnimationController movement = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final AnimationController expansion = AnimationController(
    vsync: this,
    value: 0,
  );
  final toggleFocus = FocusNode();
  Offset? anchor;
  Offset? movementStart;
  Size viewport = Size.zero;
  bool open = false;
  bool wantedOpen = false;
  bool dragging = false;
  bool positionedByUser = false;
  int transition = 0;

  bool get reduceMotion => MediaQuery.disableAnimationsOf(context);
  Offset? get visibleAnchor => anchor == null || movementStart == null
      ? anchor
      : Offset.lerp(
          movementStart,
          anchor,
          Curves.easeOutCubic.transform(movement.value),
        );
  LogGeometry get geometry => LogGeometry(viewport, visibleAnchor, open: open);

  @override
  void dispose() {
    movement.dispose();
    expansion.dispose();
    toggleFocus.dispose();
    super.dispose();
  }

  void _stopMovement() {
    final current = geometry.anchor;
    movement.stop();
    anchor = current;
    movementStart = current;
  }

  Future<void> _toggle() async {
    final id = ++transition;
    _stopMovement();
    if (wantedOpen) {
      setState(() => wantedOpen = false);
      if (reduceMotion) {
        expansion.value = 0;
      } else {
        try {
          await _animateExpansion(0);
        } on TickerCanceled {
          return;
        }
      }
      if (!mounted || id != transition) return;
      setState(() => open = false);
      toggleFocus.requestFocus();
      return;
    }

    final target = LogGeometry(viewport, anchor, open: true).anchor;
    setState(() {
      wantedOpen = true;
      movementStart = anchor;
      anchor = target;
    });
    // Move the small ball into a position that fits the window before expanding.
    if (!reduceMotion && movementStart != target) {
      try {
        await movement.forward(from: 0).orCancel;
      } on TickerCanceled {
        return;
      }
    } else {
      movement.value = 1;
    }
    if (!mounted || id != transition) return;
    setState(() {
      anchor = movementStart = LogGeometry(viewport, anchor, open: true).anchor;
      open = true;
    });
    if (reduceMotion) {
      expansion.value = 1;
    } else {
      try {
        await _animateExpansion(1);
      } on TickerCanceled {
        return;
      }
    }
  }

  Future<void> _animateExpansion(double target) async {
    // Shape easing lives in the contour. A bounded, evenly paced timeline keeps
    // the expansion visible instead of spending most of a spring on its tail.
    // Reversing starts from the current shape, never from an endpoint.
    final distance = (target - expansion.value).abs();
    await expansion
        .animateTo(
          target,
          duration: Duration(
            milliseconds: ((target == 1 ? 360 : 300) * distance).round(),
          ),
          curve: Curves.linear,
        )
        .orCancel;
  }

  void _settleForMovement() {
    _stopMovement();
    // Dragging must not snap an in-flight contour to a circle or full window.
    // Only cancel the pre-opening edge adjustment (the surface is still a ball).
    // An existing morph keeps its timeline and latest requested endpoint.
    if (!open && wantedOpen) {
      ++transition;
      wantedOpen = false;
    }
  }

  void _dragStart(DragStartDetails details) => setState(() {
    _settleForMovement();
    dragging = true;
  });

  void _dragUpdate(DragUpdateDetails details) {
    final next = LogGeometry(
      viewport,
      geometry.anchor + details.delta,
      open: open,
    );
    setState(() {
      positionedByUser = true;
      anchor = next.anchor;
      movementStart = anchor;
    });
  }

  void _dragEnd() => setState(() => dragging = false);

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && wantedOpen) {
      _toggle();
      return KeyEventResult.handled;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 40.0 : 16.0;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step),
      LogicalKeyboardKey.arrowDown => Offset(0, step),
      _ => null,
    };
    if (delta == null && key != LogicalKeyboardKey.home) {
      return KeyEventResult.ignored;
    }
    _settleForMovement();
    final next = LogGeometry(
      viewport,
      key == LogicalKeyboardKey.home ? null : anchor! + delta!,
      open: open,
    );
    setState(() {
      positionedByUser = key != LogicalKeyboardKey.home;
      anchor = movementStart = next.anchor;
    });
    return KeyEventResult.handled;
  }

  Widget _dragHandle(Widget child, {Key? key}) => MouseRegion(
    cursor: dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: _dragStart,
      onPanUpdate: _dragUpdate,
      onPanEnd: (_) => _dragEnd(),
      onPanCancel: _dragEnd,
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final nextViewport = constraints.biggest;
      if (nextViewport != viewport) {
        // Commit the clamped position so growing the viewport cannot resurrect
        // a stale off-screen anchor. Layout already excludes keyboard insets.
        final oldAnchor = positionedByUser ? visibleAnchor : null;
        viewport = nextViewport;
        final fitted = LogGeometry(viewport, oldAnchor, open: open).anchor;
        anchor = movementStart = fitted;
      }
      return AnimatedBuilder(
        animation: Listenable.merge([movement, expansion]),
        child: RepaintBoundary(
          child: LogWindow(
            log: widget.log,
            onRefresh: widget.onRefresh,
            onClose: _toggle,
            framed: false,
            dragHandle: (child) => _dragHandle(
              Focus(onKeyEvent: _key, child: child),
              key: const ValueKey('log-drag-handle'),
            ),
          ),
        ),
        builder: (context, content) {
          final layout = geometry;
          final contour = LiquidLogContour(
            panelSize: layout.panelSize,
            diameter: layout.diameter,
            progress: expansion.value,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: layout.panelPosition.dx,
                top: layout.anchor.dy,
                width: layout.panelSize.width,
                height: layout.panelSize.height,
                child: IgnorePointer(
                  ignoring: !wantedOpen,
                  child: LiquidLogSurface(
                    key: const ValueKey('liquid-log-surface'),
                    contour: contour,
                    panelSize: layout.panelSize,
                    interactive: open && wantedOpen,
                    child: content!,
                  ),
                ),
              ),
              Positioned(
                left: layout.ballPosition.dx,
                top: layout.ballPosition.dy,
                width: layout.diameter,
                height: layout.diameter,
                child: _dragHandle(
                  Focus(
                    onKeyEvent: _key,
                    child: LogBall(
                      open: wantedOpen,
                      onTap: _toggle,
                      focusNode: toggleFocus,
                      // The same painter draws both the circle and the panel,
                      // so the first click does not introduce a new path pipeline.
                      surfaceProvided: true,
                      morphProgress: contour.progress,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class LogBall extends StatelessWidget {
  const LogBall({
    super.key,
    required this.open,
    required this.onTap,
    this.focusNode,
    this.surfaceProvided = false,
    this.morphProgress,
  });
  final bool open;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool surfaceProvided;
  final double? morphProgress;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: open ? '收起日志 · 可拖动' : '打开日志 · 可拖动',
    excludeFromSemantics: true,
    child: Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      focusable: true,
      onFocus: focusNode?.requestFocus,
      onTap: onTap,
      expanded: open,
      label: open ? '收起日志' : '打开日志',
      child: Material(
        color: surfaceProvided ? Colors.transparent : Colors.white,
        shape: CircleBorder(
          side: surfaceProvided
              ? BorderSide.none
              : const BorderSide(color: UiStyle.text),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          onTap: onTap,
          // The morph itself is the tap feedback; avoid a competing ripple and
          // its first-use shader work on the same opening frame.
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity:
                      1 -
                      LiquidLogContour.phase(
                        .08,
                        .32,
                        morphProgress ?? (open ? 1 : 0),
                      ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.description_outlined,
                        color: UiStyle.muted,
                        size: 18,
                      ),
                      Text(
                        t(context, 'log_short'),
                        style: const TextStyle(
                          color: UiStyle.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Opacity(
                  opacity: LiquidLogContour.phase(
                    .32,
                    .72,
                    morphProgress ?? (open ? 1 : 0),
                  ),
                  child: const Icon(
                    Icons.remove,
                    size: 20,
                    color: UiStyle.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A non-modal viewer of the existing ExecutionLog; opening never starts or
/// stops an execution. The same subscription handles appended lines and clear.
class LogWindow extends StatefulWidget {
  const LogWindow({
    super.key,
    required this.log,
    required this.onClose,
    this.dragHandle,
    this.framed = true,
    this.onRefresh,
  });
  final bool framed;
  final Future<void> Function()? onRefresh;
  final ExecutionLog log;
  final VoidCallback onClose;
  final Widget Function(Widget)? dragHandle;

  @override
  State<LogWindow> createState() => _LogWindowState();
}

class _LogWindowState extends State<LogWindow> {
  final scroll = ScrollController();
  bool follow = true;
  bool refreshing = false;

  Future<void> _refresh() async {
    if (refreshing || widget.onRefresh == null) return;
    setState(() => refreshing = true);
    try {
      await widget.onRefresh!();
      if (mounted)
        widget.log.add(t(context, 'ledger_refreshed'), level: LogLevel.success);
    } catch (e) {
      if (mounted) widget.log.add('$e', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_onLog);
    _onLog();
  }

  @override
  void didUpdateWidget(LogWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      oldWidget.log.removeListener(_onLog);
      widget.log.addListener(_onLog);
      _onLog();
    }
  }

  @override
  void dispose() {
    widget.log.removeListener(_onLog);
    scroll.dispose();
    super.dispose();
  }

  void _onLog() {
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 54),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            t(context, 'log'),
            style: panelTitle,
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '日志面板',
      child: Material(
        color: widget.framed ? Colors.white : Colors.transparent,
        elevation: widget.framed ? 3 : 0,
        shadowColor: Colors.black.withValues(alpha: .12),
        shape: widget.framed
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: UiStyle.border),
              )
            : null,
        clipBehavior: widget.framed ? Clip.antiAlias : Clip.none,
        child: Column(
          children: [
            widget.dragHandle?.call(title) ?? title,
            if (widget.onRefresh != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(t(context, 'ledger_notice'), style: muted),
                    ),
                    TextButton(
                      key: const ValueKey('refresh-wallet-ledger'),
                      onPressed: refreshing ? null : _refresh,
                      child: Text(
                        t(context, refreshing ? 'reading' : 'refresh'),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: follow,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      setState(() => follow = v ?? true);
                      _onLog();
                    },
                  ),
                  Text(t(context, 'follow_latest'), style: muted),
                  const Spacer(),
                  if (widget.log.readHistory != null)
                    IconButton(
                      tooltip: '本机历史日志',
                      icon: const Icon(Icons.history, size: 18),
                      onPressed: () async {
                        String history;
                        try {
                          history = await widget.log.readHistory!();
                        } catch (error) {
                          if (context.mounted) await showError(context, error);
                          return;
                        }
                        if (!context.mounted) return;
                        await showUiDialog<void>(
                          context: context,
                          builder: (_) => UiDialog(
                            title: const Text('本机历史日志'),
                            width: 580,
                            content: history.isEmpty
                                ? const Text('尚无日志', style: muted)
                                : SelectableText(history, style: mono.copyWith(height: 1.5)),
                          ),
                        );
                      },
                    ),
                  TextButton(
                    onPressed: widget.log.clear,
                    child: Text(t(context, 'clear')),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: UiStyle.border),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.log,
                builder: (context, _) {
                  final items = widget.log.entries;
                  if (items.isEmpty) {
                    return Center(
                      child: Text(t(context, 'log_empty'), style: muted),
                    );
                  }
                  return ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final e = items[i];
                      final time = [
                        e.time.hour,
                        e.time.minute,
                        e.time.second,
                      ].map((v) => v.toString().padLeft(2, '0')).join(':');
                      final color = switch (e.level) {
                        LogLevel.error => UiStyle.negative,
                        LogLevel.success => UiStyle.positive,
                        LogLevel.info => UiStyle.text,
                      };
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '$time  ${e.text}',
                          style: mono.copyWith(color: color, height: 1.5),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
