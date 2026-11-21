import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'component_theme.dart';

/// Material MenuAnchor handles viewport collision, overlays and outside taps; values
/// remain controlled by the caller. This component never requests business data.
class UiSelect<T> extends StatelessWidget {
  const UiSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.placeholder = '请选择',
    this.semanticLabel,
    this.maxWidth,
  });

  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String placeholder;
  final String? semanticLabel;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) => _ChoiceMenu<T>(
    options: options,
    value: value,
    onSelected: onChanged,
    placeholder: placeholder,
    semanticLabel: semanticLabel,
    maxWidth: maxWidth,
  );
}

/// The same anchored list for actions such as loading an existing wallet group.
class UiMenu<T> extends StatelessWidget {
  const UiMenu({
    super.key,
    required this.child,
    required this.options,
    required this.onSelected,
    this.enabled = true,
  });

  final Widget child;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => _ChoiceMenu<T>(
    options: options,
    onSelected: enabled ? onSelected : null,
    child: child,
  );
}

class _ChoiceMenu<T> extends StatefulWidget {
  const _ChoiceMenu({
    required this.options,
    required this.onSelected,
    this.value,
    this.placeholder = '请选择',
    this.semanticLabel,
    this.child,
    this.maxWidth,
  });

  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onSelected;
  final String placeholder;
  final String? semanticLabel;
  final Widget? child;
  final double? maxWidth;

  @override
  State<_ChoiceMenu<T>> createState() => _ChoiceMenuState<T>();
}

class _ChoiceMenuState<T> extends State<_ChoiceMenu<T>> {
  final _menu = MenuController();
  final _focus = FocusNode();
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _prefixReset;
  String _prefix = '';
  int _active = 0;
  bool _open = false;
  ScrollPosition? _pageScroll;
  List<String> _measuredLabels = const [];
  TextStyle? _measuredStyle;
  TextScaler? _measuredScaler;
  TextDirection? _measuredDirection;
  double _labelWidth = 0;
  double? _measuredMenuWidth;
  final _rowHeights = <String, double>{};

  void _measureLabels(BuildContext context, double maxMenuWidth) {
    final labels = [
      widget.placeholder,
      for (final option in widget.options) option.$2,
    ];
    final style = DefaultTextStyle.of(context).style.copyWith(fontSize: 14);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    if (listEquals(labels, _measuredLabels) &&
        style == _measuredStyle &&
        scaler == _measuredScaler &&
        direction == _measuredDirection &&
        maxMenuWidth == _measuredMenuWidth) {
      return;
    }
    final painter = TextPainter(textDirection: direction, textScaler: scaler);
    // Menu padding, row padding, and the selected checkmark take 45 px.
    final maxTextWidth = math.max(1.0, maxMenuWidth - 46);
    _rowHeights.clear();
    var longest = 0.0;
    for (final text in labels) {
      painter.text = TextSpan(text: text, style: style);
      painter.layout();
      longest = math.max(longest, painter.width);
      if (painter.width > maxTextWidth) painter.layout(maxWidth: maxTextWidth);
      _rowHeights[text] = math.max(32.0, painter.height.ceilToDouble() + 4);
    }
    painter.dispose();
    _measuredLabels = labels;
    _measuredStyle = style;
    _measuredScaler = scaler;
    _measuredDirection = direction;
    _measuredMenuWidth = maxMenuWidth;
    _labelWidth = longest;
  }

  bool get _enabled => widget.onSelected != null && widget.options.isNotEmpty;
  bool get _searchable => widget.options.length > 8;
  List<(T, String)> get _visible {
    final query = _search.text.trim().toLowerCase();
    return query.isEmpty
        ? widget.options
        : widget.options
              .where((item) => item.$2.toLowerCase().contains(query))
              .toList();
  }

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _keys;
    _searchFocus.onKeyEvent = _keys;
    _focus.addListener(_focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_pageScroll != position) {
      _pageScroll?.removeListener(_closeForScroll);
      _pageScroll = position;
      _pageScroll?.addListener(_closeForScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _ChoiceMenu<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _menu.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _menu.close();
      });
    }
    _active = _active.clamp(0, math.max(0, _visible.length - 1));
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  // Close on parent scrolling rather than leaving an unrelated floating list.
  // The list's own controller is independent and remains fully scrollable.
  void _closeForScroll() {
    if (_menu.isOpen) _menu.close();
  }

  @override
  void dispose() {
    _pageScroll?.removeListener(_closeForScroll);
    _prefixReset?.cancel();
    _focus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_enabled) return;
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _search.clear();
      _active = math.max(
        0,
        widget.options.indexWhere((o) => o.$1 == widget.value),
      );
      _focus.requestFocus();
      _menu.open();
      _revealActive();
    }
  }

  void _choose(int index) {
    final options = _visible;
    if (!_enabled || index < 0 || index >= options.length) return;
    final value = options[index].$1;
    _menu.close();
    _focus.requestFocus();
    widget.onSelected?.call(value);
  }

  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final visible = _visible;
      if (_active >= visible.length) return;
      final top = visible
          .take(_active)
          .fold<double>(
            0,
            (height, option) => height + _rowHeights[option.$2]!,
          );
      final bottom = top + _rowHeights[visible[_active].$2]!;
      final viewport = _scroll.position.viewportDimension;
      final target = top < _scroll.offset
          ? top
          : bottom > _scroll.offset + viewport
          ? bottom - viewport
          : _scroll.offset;
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  KeyEventResult _keys(FocusNode node, KeyEvent event) {
    if (!_enabled || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (!_menu.isOpen) return KeyEventResult.ignored;
      _menu.close();
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      if (_menu.isOpen) _menu.close();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        (key == LogicalKeyboardKey.space && node != _searchFocus)) {
      if (_menu.isOpen) {
        _choose(_active);
      } else {
        _toggle();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        (node != _searchFocus &&
            (key == LogicalKeyboardKey.home ||
                key == LogicalKeyboardKey.end))) {
      final alreadyOpen = _menu.isOpen;
      if (!alreadyOpen) _toggle();
      final options = _visible;
      if (options.isEmpty) return KeyEventResult.handled;
      setState(() {
        if (key == LogicalKeyboardKey.home) {
          _active = 0;
        } else if (key == LogicalKeyboardKey.end) {
          _active = options.length - 1;
        } else if (alreadyOpen) {
          _active =
              (_active + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
              options.length;
        }
      });
      _revealActive();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (node != _searchFocus &&
        character != null &&
        character.length == 1 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      if (!_menu.isOpen) _toggle();
      _prefix += character.toLowerCase();
      _prefixReset?.cancel();
      _prefixReset = Timer(
        const Duration(milliseconds: 600),
        () => _prefix = '',
      );
      final index = _visible.indexWhere(
        (o) => o.$2.toLowerCase().startsWith(_prefix),
      );
      if (index >= 0) {
        setState(() => _active = index);
        _revealActive();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.options
        .where((o) => o.$1 == widget.value)
        .firstOrNull;
    final visible = _visible;
    final view = MediaQuery.sizeOf(context);
    final maxMenuWidth = widget.maxWidth ?? 360.0;
    _measureLabels(context, math.min(view.width - 24, maxMenuWidth));
    final rowHeights = [for (final option in visible) _rowHeights[option.$2]!];
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          math.min(
            view.width - 24,
            constraints.hasBoundedWidth
                ? constraints.maxWidth
                : view.width - 24,
          ),
        );
        // Size from the longest option, not the surrounding form. Keep the
        // trigger stable when selecting another token and cache text metrics.
        final triggerWidth = math.min(
          available,
          (_labelWidth + 47).clamp(112.0, widget.maxWidth ?? 280.0),
        );
        final width = math.max(
          0.0,
          math.min(
            view.width - 24,
            (_labelWidth + 48).clamp(_searchable ? 180.0 : 120.0, maxMenuWidth),
          ),
        );
        final listHeight = math
            .min(
              math.min(260.0, view.height - 48),
              math.max(
                    32.0,
                    rowHeights.fold<double>(0, (sum, height) => sum + height),
                  ) +
                  (_searchable ? 44 : 0) +
                  8,
            )
            .clamp(40.0, 260.0);
        return Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          heightFactor: 1,
          child: SizedBox(
            width: widget.child == null ? triggerWidth : null,
            child: MenuAnchor(
              controller: _menu,
              childFocusNode: _focus,
              consumeOutsideTap: true,
              useRootOverlay: true,
              // Flutter's animated MenuAnchor reveals height over 500ms. A dense
              // trading selector must be fully usable on its first painted frame;
              // keep the small chevron transition without delaying the menu rows.
              animated: false,
              alignmentOffset: const Offset(0, 4),
              onOpen: () => setState(() => _open = true),
              onClose: () {
                _prefixReset?.cancel();
                _prefix = '';
                if (mounted) setState(() => _open = false);
              },
              style: MenuStyle(
                alignment: AlignmentDirectional.bottomStart,
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                elevation: const WidgetStatePropertyAll(5),
                shadowColor: const WidgetStatePropertyAll(Color(0x14000000)),
                surfaceTintColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                backgroundColor: const WidgetStatePropertyAll(Colors.white),
                side: const WidgetStatePropertyAll(
                  BorderSide(color: UiStyle.border),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              menuChildren: [
                SizedBox(
                  key: const ValueKey('ui-select-menu'),
                  width: width,
                  height: listHeight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      children: [
                        if (_searchable)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SizedBox(
                              height: 36,
                              child: TextField(
                                controller: _search,
                                focusNode: _searchFocus,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: UiStyle.text,
                                ),
                                decoration: const InputDecoration(
                                  hintText: '搜索',
                                  prefixIcon: Icon(Icons.search, size: 16),
                                  prefixIconConstraints: BoxConstraints(
                                    minWidth: 30,
                                  ),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                ),
                                onChanged: (_) {
                                  setState(() => _active = 0);
                                  _revealActive();
                                },
                              ),
                            ),
                          ),
                        Expanded(
                          child: visible.isEmpty
                              ? const Center(
                                  child: Text(
                                    '无匹配项',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: UiStyle.muted,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scroll,
                                  padding: EdgeInsets.zero,
                                  itemExtentBuilder: (index, _) =>
                                      index < rowHeights.length
                                      ? rowHeights[index]
                                      : null,
                                  itemCount: visible.length,
                                  itemBuilder: (context, index) {
                                    final option = visible[index];
                                    final checked = widget.value == option.$1;
                                    return Semantics(
                                      selected: checked,
                                      button: true,
                                      child: MouseRegion(
                                        onEnter: (_) =>
                                            setState(() => _active = index),
                                        child: Material(
                                          color: _active == index
                                              ? UiStyle.hover
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: InkWell(
                                            canRequestFocus: false,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            onTap: () => _choose(index),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      option.$2,
                                                      style: _measuredStyle!
                                                          .copyWith(
                                                            color:
                                                                UiStyle.text,
                                                          ),
                                                    ),
                                                  ),
                                                  if (checked)
                                                    const Padding(
                                                      padding: EdgeInsets.only(
                                                        left: 6,
                                                      ),
                                                      child: Icon(
                                                        Icons.check,
                                                        size: 15,
                                                        color: UiStyle.text,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              builder: (context, controller, child) => Focus(
                focusNode: _focus,
                onKeyEvent: _keys,
                canRequestFocus: _enabled,
                child: Semantics(
                  key: const ValueKey('ui-select-trigger'),
                  button: true,
                  enabled: _enabled,
                  expanded: _open,
                  label: widget.semanticLabel,
                  child: Material(
                    color: _enabled ? Colors.white : UiStyle.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(UiStyle.radius),
                      side: BorderSide(
                        color: _focus.hasFocus || _open
                            ? UiStyle.action
                            : UiStyle.border,
                      ),
                    ),
                    child: InkWell(
                      onTap: _enabled ? _toggle : null,
                      canRequestFocus: false,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 36),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: widget.child == null ? MainAxisSize.max : MainAxisSize.min,
                            children: [
                              Flexible(
                                fit: widget.child == null ? FlexFit.tight : FlexFit.loose,
                                child: DefaultTextStyle.merge(
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: _enabled ? UiStyle.text : UiStyle.muted,
                                  ),
                                  child: widget.child ?? Text(selected?.$2 ?? widget.placeholder),
                                ),
                              ),
                              const SizedBox(width: 10),
                              AnimatedRotation(
                                turns: _open ? .5 : 0,
                                duration: MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero : UiStyle.motion,
                                child: const Icon(Icons.expand_more, size: 17, color: UiStyle.muted),
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
      },
    );
  }
}

/// Descendants remain mounted while closed to preserve form drafts.
class UiAccordion extends StatefulWidget {
  const UiAccordion({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<UiAccordion> createState() => _UiAccordionState();
}

class _UiAccordionState extends State<UiAccordion> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextButton(
        onPressed: () => setState(() => _expanded = !_expanded),
        style: TextButton.styleFrom(
          foregroundColor: UiStyle.muted,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 36),
        ),
        child: Semantics(
          expanded: _expanded,
          child: Row(
            children: [
              Expanded(
                child: Text(widget.title, style: const TextStyle(fontSize: 14)),
              ),
              AnimatedRotation(
                turns: _expanded ? .5 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more, size: 16),
              ),
            ],
          ),
        ),
      ),
      ClipRect(
        child: AnimatedAlign(
          alignment: Alignment.topCenter,
          heightFactor: _expanded ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: IgnorePointer(
            ignoring: !_expanded,
            child: ExcludeFocus(
              excluding: !_expanded,
              child: ExcludeSemantics(
                excluding: !_expanded,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
