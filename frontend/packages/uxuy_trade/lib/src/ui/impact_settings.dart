import 'package:flutter/material.dart';

import '../exec/executor.dart';
import '../state/app_state.dart';
import 'widgets.dart';

String formatImpact(double percent) => percent == percent.truncateToDouble()
    ? percent.toStringAsFixed(0)
    : percent.toString();

// The ordinary order dialog always comes first. Only the prepared order can
// consume this additional approval, and closing either dialog leaves it unsigned.
Future<bool> confirmImpact(BuildContext context, ImpactReview review) async {
  if (!review.needsConfirmation) return true;
  final known = review.value != null && review.value!.isFinite;
  final compact = known ? review.value!.toStringAsFixed(2) : '';
  final percent = known && double.parse(compact) <= review.threshold
      ? formatImpact(review.value!)
      : compact;
  return await showUiDialog<bool>(
        context: context,
        builder: (c) => UiDialog(
          width: 400,
          title: Text(t(c, 'impact_warning')),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (known) ...[
                Text(
                  '${t(c, review.mode == SendMode.bundle ? 'impact_est_bundle' : 'impact_est_interval')}  ${percent}%',
                  style: strong.copyWith(color: UiStyle.negative),
                ),
                const SizedBox(height: 6),
                Text(
                  '${t(c, 'impact_exceeds')} ${formatImpact(review.threshold)}%',
                ),
              ] else
                Text(t(c, review.v4 ? 'impact_v4' : 'impact_unknown')),
              if (known || !review.v4) ...[
                const SizedBox(height: 8),
                Text(t(c, 'impact_check_pool'), style: muted),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t(c, 'cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t(c, 'impact_accept')),
            ),
          ],
        ),
      ) ==
      true;
}

Future<void> editImpactSettings(BuildContext context, AppState state) async {
  await showUiDialog<void>(
    context: context,
    builder: (_) => _SettingsEditor(state: state),
  );
}

class _SettingsEditor extends StatefulWidget {
  const _SettingsEditor({required this.state});
  final AppState state;
  @override
  State<_SettingsEditor> createState() => _SettingsEditorState();
}

class _SettingsEditorState extends State<_SettingsEditor> {
  late final List<TextEditingController> values;
  String? error;

  @override
  void initState() {
    super.initState();
    final current = widget.state.impactSettings;
    values = [
      for (final n in [
        current.bundle,
        current.intervalStart,
        current.intervalLive,
      ])
        TextEditingController(text: formatImpact(n)),
    ];
  }

  @override
  void dispose() {
    for (final c in values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const keys = [
      'impact_bundle_setting',
      'impact_interval_setting',
      'impact_live_setting',
    ];
    return UiDialog(
      width: 420,
      title: Text(t(context, 'impact_settings')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keys.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(child: Text(t(context, keys[i]), style: label)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: Semantics(
                      label: t(context, keys[i]),
                      child: InputBox(
                        controller: values[i],
                        number: true,
                        suffix: '%',
                        onChanged: (_) {
                          if (error != null) setState(() => error = null);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (error != null)
            Text(error!, style: const TextStyle(color: UiStyle.negative)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t(context, 'cancel')),
        ),
        TextButton(
          onPressed: () {
            try {
              widget.state.setImpactSettings(
                ImpactSettings.parse(
                  values[0].text,
                  values[1].text,
                  values[2].text,
                ),
              );
              Navigator.pop(context);
            } on Object catch (e) {
              setState(
                () => error = uiErrorText(e),
              );
            }
          },
          child: Text(t(context, 'confirm')),
        ),
      ],
    );
  }
}

class QuoteWaitNotice extends StatelessWidget {
  const QuoteWaitNotice({super.key, required this.cancel});
  final VoidCallback cancel;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(t(context, 'quote_wait'), style: muted),
      TextButton(onPressed: cancel, child: Text(t(context, 'cancel'))),
    ],
  );
}
