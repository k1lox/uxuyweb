import 'package:flutter/material.dart';

import '../wallet/wallet.dart';
import 'clipboard_feedback.dart';
import 'widgets.dart';

/// Per-wallet controls for locally generated keys. Only the revealed row
/// materializes its key in the widget tree.
class GeneratedWalletList extends StatefulWidget {
  const GeneratedWalletList({
    super.key,
    required this.wallets,
    required this.onKeyCopied,
    this.detail,
    this.unchecked,
    this.onCheckChanged,
  }) : assert((unchecked == null) == (onCheckChanged == null));

  final List<TradeWallet> wallets;
  final ValueChanged<TradeWallet> onKeyCopied;
  final String Function(int index)? detail;
  final Set<String>? unchecked;
  final void Function(TradeWallet wallet, bool checked)? onCheckChanged;

  @override
  State<GeneratedWalletList> createState() => _GeneratedWalletListState();
}

class _GeneratedWalletListState extends State<GeneratedWalletList> {
  String? _revealed;
  final _controller = ScrollController(keepScrollOffset: false);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _hide, onHide: _hide);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Visibility.of(context)) _revealed = null;
  }

  void _hide() {
    if (_revealed != null) setState(() => _revealed = null);
  }

  @override
  void dispose() {
    _controller.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView.builder(
        controller: widget.unchecked == null ? null : _controller,
        primary: false,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: widget.wallets.length,
        itemBuilder: (_, index) {
          final wallet = widget.wallets[index];
          final revealed = _revealed == wallet.address;
          final detail = widget.detail?.call(index);
          final unchecked = widget.unchecked;
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: t(context, 'copy_address'),
                iconSize: 17,
                onPressed: () => ClipboardFeedback.copy(
                  context,
                  wallet.address,
                  successLabel: t(context, 'copied'),
                ),
                icon: const Icon(Icons.content_copy_outlined),
              ),
              IconButton(
                tooltip: t(
                  context,
                  revealed ? 'hide_private_key' : 'show_private_key',
                ),
                iconSize: 18,
                onPressed: () => setState(
                  () => _revealed = revealed ? null : wallet.address,
                ),
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
              IconButton(
                tooltip: t(context, 'copy_private_key'),
                iconSize: 17,
                onPressed: () => ClipboardFeedback.copy(
                  context,
                  wallet.exportPrivateKey(),
                  successLabel: t(context, 'exported'),
                  onCopied: () => widget.onKeyCopied(wallet),
                ),
                icon: Icon(Icons.key_outlined),
              ),
            ],
          );
          return Column(
            key: ValueKey(wallet.address),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 360;
                  final row = Row(
                    children: [
                      if (unchecked != null)
                        Checkbox(
                          key: ValueKey('generated-select-${wallet.address}'),
                          semanticLabel: wallet.address,
                          visualDensity: VisualDensity.compact,
                          value: !unchecked.contains(wallet.address),
                          onChanged: (value) =>
                              widget.onCheckChanged!(wallet, value == true),
                        ),
                      SizedBox(
                        width: 28,
                        child: Text('${index + 1}', style: muted),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(wallet.address, style: mono),
                            if (detail != null) Text(detail, style: muted),
                          ],
                        ),
                      ),
                      if (!stacked) controls,
                    ],
                  );
                  if (!stacked) return row;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [row, controls],
                  );
                },
              ),
              if (revealed)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(28, 2, 8, 10),
                  child: SelectableText(wallet.exportPrivateKey(), style: mono),
                ),
            ],
          );
        },
      ),
    );
  }
}
