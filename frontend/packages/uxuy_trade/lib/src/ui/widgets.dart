import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../strings.g.dart';
import 'component_theme.dart';
import 'dialogs.dart';

export 'component_theme.dart';
export 'dialogs.dart';
export 'select.dart';

String t(BuildContext context, String key) => demoText(context, key);

// Match the surrounding font while keeping numerical columns aligned.
const mono = TextStyle(
  fontFeatures: [FontFeature.tabularFigures()],
  fontSize: 12,
);
const muted = TextStyle(color: UiStyle.muted, fontSize: 12, height: 1.5);
const label = TextStyle(color: UiStyle.muted, fontSize: 14);
const strong = TextStyle(
  fontWeight: FontWeight.w600,
  fontSize: 14,
  color: UiStyle.text,
);

const panelTitle = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: UiStyle.text);

/// Keeps a wallet address intact and lets its balance or status move underneath.
class WalletAddressRow extends StatelessWidget {
  const WalletAddressRow({
    super.key,
    required this.number,
    required this.address,
    required this.detail,
    this.leading,
  });

  final int number;
  final String address;
  final Widget detail;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ?leading,
      SizedBox(width: 26, child: Text('$number', style: muted)),
      Expanded(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          runSpacing: 4,
          children: [
            Text(address, style: mono),
            detail,
          ],
        ),
      ),
    ],
  );
}

/// Bold black section title (UXUY "资产管理 / 交易 / 活动").
const sectionTitle = TextStyle(
  fontWeight: FontWeight.w600,
  fontSize: 20,
  color: UiStyle.text,
);

/// Shared panel surface for workspace sections.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: UiStyle.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  if (title != null)
                    Expanded(child: Text(title!, style: panelTitle))
                  else
                    const Spacer(),
                  ?trailing,
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

enum OptionStyle { accent, buy, sell }

/// Short choices stay content-sized and wrap instead of stretching across a form.
class OptionPair<T> extends StatelessWidget {
  const OptionPair({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.styles,
    this.compact = false,
  });
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final List<OptionStyle>? styles;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < options.length; i++)
            _option(context, options[i], styles?[i] ?? OptionStyle.accent),
        ],
      ),
    );
  }

  Widget _option(BuildContext context, (T, String) o, OptionStyle style) {
    final selected = o.$1 == value;
    final color = switch (style) {
      OptionStyle.buy => UiStyle.positive,
      OptionStyle.sell => UiStyle.negative,
      OptionStyle.accent => UiStyle.text,
    };
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Semantics(
      selected: selected,
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: selected ? UiStyle.surface : Colors.transparent,
          foregroundColor: selected ? color : UiStyle.muted,
          disabledForegroundColor: UiStyle.muted,
          minimumSize: Size(compact ? 60 : 76, mobile ? 40 : (compact ? 32 : 38)),
          visualDensity: mobile ? VisualDensity.standard : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onPressed: onChanged == null ? null : () => onChanged!(o.$1),
        child: Text(o.$2),
      ),
    );
  }
}

/// Compact secondary action, adapted from the library action-feedback controls.
class SmallButton extends StatelessWidget {
  const SmallButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: UiStyle.text,
          side: const BorderSide(color: UiStyle.border),
          disabledForegroundColor: UiStyle.muted,
          disabledBackgroundColor: UiStyle.surface,
          minimumSize: Size(0, MediaQuery.sizeOf(context).width < 600 ? 40 : 32),
          visualDensity: MediaQuery.sizeOf(context).width < 600 ? VisualDensity.standard : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.labelLarge!
              .copyWith(fontSize: 14, fontWeight: FontWeight.w400),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// UXUY primary action, using the same size/radius as the library controls.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 112, maxWidth: 320),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).width >= 800 ? 40 : 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              disabledBackgroundColor: UiStyle.surface,
              disabledForegroundColor: UiStyle.muted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              textStyle: Theme.of(context).textTheme.labelLarge!
                  .copyWith(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: busy ? null : onPressed,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: UiStyle.muted,
                    ),
                  )
                : Text(label),
          ),
        ),
      ),
    );
  }
}

/// Compact input. [suffix] is shown inside the field (unit).
class InputBox extends StatelessWidget {
  const InputBox({
    super.key,
    required this.controller,
    this.hint,
    this.suffix,
    this.number = false,
    this.enabled = true,
    this.address = false,
    this.onChanged,
    this.align = TextAlign.start,
    this.fill,
  });
  final Color? fill;
  final TextEditingController controller;
  final String? hint;
  final String? suffix;
  final bool number;
  final bool enabled;
  final bool address;
  final ValueChanged<String>? onChanged;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final longUnit = suffix != null && suffix!.length > 7;
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      textAlign: align,
      minLines: 1,
      maxLines: address ? null : 1,
      textInputAction: address ? TextInputAction.done : null,
      inputFormatters: address
          ? [FilteringTextInputFormatter.singleLineFormatter]
          : null,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: fill ?? (enabled ? Colors.white : UiStyle.surface),
        hintStyle: const TextStyle(color: UiStyle.muted, fontSize: 14),
        suffixText: longUnit ? null : suffix,
        suffix: longUnit
            ? Tooltip(
                message: suffix!,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 56),
                  child: Text(suffix!, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              )
            : null,
        suffixStyle: muted,
        contentPadding: UiStyle.fieldPadding,
        border: UiStyle.fieldBorder,
        enabledBorder: UiStyle.fieldBorder,
        focusedBorder: UiStyle.fieldBorder.copyWith(
          borderSide: const BorderSide(color: UiStyle.action),
        ),
      ),
    );
  }
}

/// "min — max unit" on one line.
class RangeRow extends StatelessWidget {
  const RangeRow({
    super.key,
    required this.min,
    required this.max,
    required this.unit,
    this.onMin,
    this.onMax,
  });
  final TextEditingController min;
  final TextEditingController max;
  final String unit;
  final ValueChanged<String>? onMin;
  final ValueChanged<String>? onMax;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: InputBox(
            controller: min,
            number: true,
            hint: t(context, 'min'),
            onChanged: onMin,
            align: TextAlign.end,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('—', style: label),
        ),
        Expanded(
          child: InputBox(
            controller: max,
            number: true,
            hint: t(context, 'max'),
            onChanged: onMax,
            align: TextAlign.end,
          ),
        ),
        if (unit.isNotEmpty) ...[
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 64),
            child: Tooltip(
              message: unit,
              excludeFromSemantics: true,
              child: Text(unit, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ],
    );
  }
}

/// Label on the left, control on the right.
class Labeled extends StatelessWidget {
  const Labeled({super.key, required this.text, required this.child});
  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text(text, style: label)),
          Expanded(child: child),
        ],
      ),
    );
  }
}

Future<void> showError(BuildContext context, Object e) async {
  UiNotice.show(context, uiErrorText(e), error: true);
}

void showNotice(BuildContext context, String text) =>
    UiNotice.show(context, text);

/// Underlined navigation tabs with arrow-key support.
class SubTabs<T> extends StatelessWidget {
  const SubTabs({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.selectedAction,
    this.horizontalPadding = 14,
  });
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onChanged;
  final Widget? selectedAction;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    void move(int direction, {int? edge}) {
      if (onChanged == null || options.isEmpty) return;
      final current = options.indexWhere((o) => o.$1 == value);
      onChanged!(options[edge ?? ((current + direction) % options.length)].$1);
    }

    final mobile = MediaQuery.sizeOf(context).width < 600;
    Widget tab(T v, String text) => Semantics(
      selected: v == value,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: v == value ? UiStyle.text : UiStyle.muted,
          minimumSize: Size(0, mobile ? 40 : 36),
          visualDensity: mobile ? VisualDensity.standard : null,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontSize: 14,
            fontWeight: v == value ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onPressed: onChanged == null ? null : () => onChanged!(v),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(
              color: v == value ? UiStyle.text : Colors.transparent,
              width: 2,
            )),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(text),
          ),
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(1),
        const SingleActivator(LogicalKeyboardKey.home): () => move(0, edge: 0),
        const SingleActivator(LogicalKeyboardKey.end): () =>
            move(0, edge: options.length - 1),
      },
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final (v, text) in options)
            if (v == value && selectedAction != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: tab(v, text)),
                  selectedAction!,
                ],
              )
            else
              tab(v, text),
        ],
      ),
    );
  }
}

/// Quiet empty state; no decorative gradient competing with the primary action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
  });
  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
    child: Column(
      children: [
        Icon(icon, color: UiStyle.muted, size: 24),
        const SizedBox(height: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: UiStyle.text,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: UiStyle.muted),
          ),
        ],
      ],
    ),
  );
}

/// Kept for callers using the original helper: always a bounded centered modal.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
}) => showUiDialog<T>(
  context: context,
  builder: (c) => UiDialog(content: builder(c)),
);
