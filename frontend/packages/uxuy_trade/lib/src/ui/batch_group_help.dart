import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'widgets.dart';

/// Read-only comparison anchored to the batch-trading title.
class BatchGroupHelpButton extends StatefulWidget {
  const BatchGroupHelpButton({super.key});

  @override
  State<BatchGroupHelpButton> createState() => _BatchGroupHelpButtonState();
}

class _BatchGroupHelpButtonState extends State<BatchGroupHelpButton> {
  final _menu = MenuController();
  final _focus = FocusNode();
  Timer? _timer;

  void _enter() {
    _timer?.cancel();
    if (!_menu.isOpen) {
      _timer = Timer(const Duration(milliseconds: 140), _menu.open);
    }
  }

  void _leave() {
    _timer?.cancel();
    if (_menu.isOpen) {
      // Give the pointer time to cross from the question mark to the table.
      _timer = Timer(const Duration(milliseconds: 180), _menu.close);
    }
  }

  void _toggle() {
    _timer?.cancel();
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(600.0, MediaQuery.sizeOf(context).width - 24);
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _focus,
      animated: false,
      useRootOverlay: true,
      reservedPadding: const EdgeInsets.all(8),
      onClose: () => _timer?.cancel(),
      style: const MenuStyle(
        alignment: AlignmentDirectional.bottomStart,
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Color(0x29000000)),
        elevation: WidgetStatePropertyAll(5),
        side: WidgetStatePropertyAll(BorderSide(color: UiStyle.border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
      ),
      menuChildren: [
        MouseRegion(
          onEnter: (_) => _timer?.cancel(),
          onExit: (_) => _leave(),
          child: SizedBox(
            width: width,
            child: width < 478
                ? ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .6),
                    child: const SingleChildScrollView(primary: false, child: _Comparison(compact: true)),
                  )
                : const _Comparison(compact: false),
          ),
        ),
      ],
      builder: (context, controller, _) => MouseRegion(
        onEnter: (_) => _enter(),
        onExit: (_) => _leave(),
        child: MergeSemantics(
          child: Semantics(
            label: t(context, 'group_help'),
            expanded: MenuController.maybeIsOpenOf(context),
            child: IconButton(
              focusNode: _focus,
              onPressed: _toggle,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(
                Icons.help_outline,
                size: 17,
                color: UiStyle.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Comparison extends StatelessWidget {
  const _Comparison({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final groups = [
      (
        t(context, 'normal_group'),
        t(context, 'group_help_normal_usage'),
        t(context, 'group_help_normal_example'),
      ),
      (
        t(context, 'linked_group'),
        t(context, 'group_help_linked_usage'),
        t(context, 'group_help_linked_example'),
      ),
      (
        t(context, 'rapid_group_name'),
        t(context, 'rapid_group_help'),
        t(context, 'rapid_group_example'),
      ),
    ];
    final example = t(context, 'group_help_example');
    const body = TextStyle(fontSize: 14, height: 1.5, color: UiStyle.text);
    const heading = TextStyle(
      fontSize: 14,
      height: 1.5,
      fontWeight: FontWeight.w600,
      color: UiStyle.text,
    );
    Widget cell(String value, TextStyle style) => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(0, 9, 10, 9),
      child: Text(value, style: style),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final group in groups) ...[
                  if (group != groups.first) const Divider(height: 1),
                  const SizedBox(height: 10),
                  Text(group.$1, style: heading),
                  const SizedBox(height: 4),
                  Text(group.$2, style: body),
                  const SizedBox(height: 6),
                  Text(example, style: label),
                  Text(group.$3, style: body),
                  const SizedBox(height: 10),
                ],
              ],
            )
          : Table(
              columnWidths: const {
                0: FixedColumnWidth(82),
                1: FlexColumnWidth(1.08),
                2: FlexColumnWidth(),
              },
              border: const TableBorder(
                horizontalInside: BorderSide(color: UiStyle.border),
              ),
              children: [
                TableRow(
                  children: [
                    cell(t(context, 'group_help_type'), label),
                    cell(t(context, 'group_help_usage'), label),
                    cell(example, label),
                  ],
                ),
                for (final group in groups)
                  TableRow(
                    children: [
                      cell(group.$1, heading),
                      cell(group.$2, body),
                      cell(group.$3, body),
                    ],
                  ),
              ],
            ),
    );
  }
}
