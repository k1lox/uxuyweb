import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart' show formatPrivateKeyLines;
import '../wallet/wallet.dart';
import '../wallet/wallet_backup.dart';
import 'folder_backup_control.dart';
import 'widgets.dart';

/// Large-list editor using the same scale-modal frame as every other dialog.
class KeyEditorPage extends StatefulWidget {
  const KeyEditorPage({
    super.key,
    required this.title,
    this.initial = '',
    this.onSave,
    this.backup,
    this.backupCategory,
    this.backupScope = '',
    this.singleWallet = false,
    this.keyBeforeAmount = false,
    this.onRestoreTransits,
    this.expectedRecipients = '',
  }) : assert(backup == null || backupCategory != null);
  final String title;
  final String initial;
  final Future<void> Function(String text)? onSave;
  final WalletBackupCoordinator? backup;
  final String? backupCategory;
  final String backupScope;
  final bool keyBeforeAmount, singleWallet;
  final Future<void> Function(String backup, String recipients)?
  onRestoreTransits;
  final String expectedRecipients;
  @override
  State<KeyEditorPage> createState() => _KeyEditorPageState();
}

class _WalletSelectionRequired extends FormatException {
  const _WalletSelectionRequired(this.addresses) : super('请选择本次要导入的钱包');
  final List<String> addresses;
}

class _KeyEditorPageState extends State<KeyEditorPage> {
  late final TextEditingController text = TextEditingController(
    text: widget.initial,
  );
  late final recipients = TextEditingController(
    text: widget.expectedRecipients,
  );
  bool busy = false;
  String? error;
  List<BackupUsageGroup> _sourceGroups = const [];
  BackupUsageGroup? _source;
  List<String> _addresses = const [];
  String? _address;
  BackupUsageGroup? get _importGroup =>
      _source ??
      (widget.backupCategory == null
          ? null
          : (category: widget.backupCategory!, scope: widget.backupScope));
  Timer? _debounce;
  late int _previousLength = widget.initial.length;
  final _seen = <String>{};
  bool _draftChanged = false;
  Future<void>? _lastWrite;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    if (widget.backup != null) {
      _lifecycle = AppLifecycleListener(
        onHide: () => unawaited(_captureDraft()),
      );
    }
  }

  void _changed(String value) {
    _source = null;
    _sourceGroups = const [];
    _address = null;
    _addresses = const [];
    if (widget.backup != null) {
      _draftChanged = true;
      _debounce?.cancel();
      // Stage a pasted block or newly completed key in the current input event.
      // For a normal keystroke only inspect the line being edited.
      if ((value.length - _previousLength).abs() != 1 ||
          _completedAtCursor(value)) {
        unawaited(_captureDraft());
      } else {
        _debounce = Timer(const Duration(milliseconds: 250), _captureDraft);
      }
      _previousLength = value.length;
    }
    setState(() => error = null);
  }

  bool _completedAtCursor(String value) {
    final caret = text.selection.extentOffset;
    final offset = caret >= 0 && caret <= value.length ? caret : value.length;
    bool isNewline(int i) =>
        value.codeUnitAt(i) == 10 || value.codeUnitAt(i) == 13;
    var start = offset, end = offset;
    while (start > 0 && !isNewline(start - 1)) {
      start--;
    }
    while (end < value.length && !isNewline(end)) {
      end++;
    }
    final key = _keyInLine(value.substring(start, end));
    return key != null && !_seen.contains(key);
  }

  String? _keyInLine(String line) {
    if (line.length < 64) return null;
    try {
      final token = parseWalletKeyLine(
        line,
        allowAmount: widget.keyBeforeAmount,
      ).key;
      return (token.startsWith('0x') ? token.substring(2) : token)
          .toLowerCase();
    } on FormatException {
      // The draft can contain an unfinished line while the user is typing.
      return null;
    }
  }

  List<TradeWallet> _ordinaryFromFile(String value) {
    final file = parseWalletFile(value, target: _importGroup);
    final wallets = file.ordinaryWallets;
    var selected = wallets;
    if (file.isArchive && widget.singleWallet && wallets.length > 1) {
      selected = wallets.where((w) => w.address == _address).toList();
      if (selected.isEmpty) {
        throw _WalletSelectionRequired(wallets.map((w) => w.address).toList());
      }
    }
    for (final w in selected) {
      widget.backup?.rememberOriginalCategory(
        w.address,
        file.originalCategoryFor(w),
      );
    }
    return selected;
  }

  List<TradeWallet> _walletsIn(String value, Set<String> seen) {
    if (isWalletFileInput(value)) {
      try {
        return _ordinaryFromFile(value)
            .where((w) => seen.add(w.exportPrivateKey().replaceFirst('0x', '')))
            .toList();
      } on FormatException {
        // Do not stage any records from an incomplete or damaged structured file.
        return [];
      }
    }
    final wallets = <TradeWallet>[];
    var lineNumber = 0;
    for (final line in value.split(RegExp(r'[\r\n]+'))) {
      lineNumber++;
      final key = _keyInLine(line);
      if (key == null || !seen.add(key)) continue;
      try {
        wallets.add(TradeWallet.import('W$lineNumber', key));
      } on FormatException {
        // An exact-length hex string can still be outside the curve's range.
      }
    }
    return wallets;
  }

  Future<void>? _captureDraft() {
    _debounce?.cancel();
    final backup = widget.backup;
    if (!_draftChanged || backup == null) return _lastWrite;
    _draftChanged = false;
    final wallets = _walletsIn(text.text, _seen);
    if (wallets.isNotEmpty) {
      final category = widget.backupCategory!;
      final scope = widget.backupScope;
      // Flutter may dispose this route while rebuilding its parent. Stage the
      // detached snapshot outside that build, before its disk write is awaited.
      _lastWrite = Future.microtask(
        () => backup.capture(category, wallets, scope: scope),
      );
    }
    return _lastWrite;
  }

  @override
  void dispose() {
    unawaited(_captureDraft());
    _lifecycle?.dispose();
    _seen.clear();
    text.clear();
    text.dispose();
    recipients.dispose();
    super.dispose();
  }

  int get _lines => text.text
      .split(RegExp(r'[\r\n]+'))
      .where((l) => l.trim().isNotEmpty)
      .length;

  Future<void> _save() async {
    final backup = widget.backup;
    if (busy || backup?.selecting == true) return;
    final value = text.text;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.onRestoreTransits case final restore?) {
        await restore(value, recipients.text);
        if (mounted) Navigator.of(context).pop('');
        return;
      }
      final normalized = isWalletFileInput(value)
          ? formatPrivateKeyLines(_ordinaryFromFile(value))
          : value;
      await _captureDraft();
      final wallets = backup == null
          ? const <TradeWallet>[]
          : _walletsIn(value, {});
      if (backup != null) {
        await backup.requireStoredIfConnected(
          widget.backupCategory!,
          wallets,
          scope: widget.backupScope,
        );
      }
      if (!mounted) return;
      await widget.onSave?.call(normalized);
      // Some host callbacks capture the wallets again while applying a form.
      // A failure in that last capture must also keep this editor open.
      if (backup != null && backup.hasError) {
        await backup.requireStoredIfConnected(
          widget.backupCategory!,
          wallets,
          scope: widget.backupScope,
        );
      }
      if (mounted) Navigator.of(context).pop(normalized);
    } on _WalletSelectionRequired catch (e) {
      if (mounted)
        setState(() {
          _addresses = e.addresses;
          error = e.message;
        });
    } on BackupUsageSelectionRequired catch (e) {
      if (mounted)
        setState(() {
          _sourceGroups = e.groups;
          error = e.message;
        });
    } on Object catch (e) {
      if (mounted) setState(() => error = uiErrorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    return PopScope<String>(
      onPopInvokedWithResult: (popped, _) {
        if (popped) unawaited(_captureDraft());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        },
        child: UiDialog(
          width: 760,
          title: Text(widget.title),
          canClose: !busy,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('${t(context, 'lines')} $_lines', style: label),
                  ),
                  TextButton(
                    onPressed: busy || text.text.isEmpty
                        ? null
                        : () => setState(() {
                            unawaited(_captureDraft());
                            text.clear();
                            _sourceGroups = const [];
                            _source = null;
                            _addresses = const [];
                            _address = null;
                            _previousLength = 0;
                            error = null;
                          }),
                    child: Text(t(context, 'clear')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height:
                    (height - (widget.onRestoreTransits == null ? 340 : 475))
                        .clamp(90, widget.singleWallet ? 118 : 400),
                child: TextField(
                  controller: text,
                  autofocus: true,
                  readOnly: busy,
                  expands: true,
                  maxLines: null,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Flutter Web selects the native textarea from keyboardType.
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  enableIMEPersonalizedLearning: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  spellCheckConfiguration:
                      const SpellCheckConfiguration.disabled(),
                  autofillHints: null,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: _changed,
                  style: mono.copyWith(height: 1.5),
                  decoration: InputDecoration(
                    hintText: _inputHint(context),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (widget.onRestoreTransits != null) ...[
                TextField(
                  controller: recipients,
                  readOnly: busy,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '核对接收地址',
                    hintText: '填写本文件对应的接收地址，每行一个',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (_sourceGroups.isNotEmpty)
                UiSelect<BackupUsageGroup>(
                  value: _source,
                  placeholder: '选择备份用途或组别',
                  options: [
                    for (final group in _sourceGroups)
                      (
                        group,
                        [
                          WalletBackupCategory.labels[group.category]!,
                          if (group.scope.isNotEmpty) group.scope,
                        ].join(' · '),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (group) => setState(() {
                          _source = group;
                          _address = null;
                          _addresses = const [];
                          error = null;
                        }),
                ),
              if (_addresses.isNotEmpty)
                UiSelect<String>(
                  value: _address,
                  placeholder: '选择钱包地址',
                  options: [
                    for (final address in _addresses) (address, address),
                  ],
                  onChanged: busy
                      ? null
                      : (address) => setState(() {
                          _address = address;
                          error = null;
                        }),
                ),
              if (error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error!,
                    style: muted.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (widget.onRestoreTransits == null)
                Text(
                  t(
                    context,
                    widget.backup == null ? 'memory_only' : 'key_draft_backup',
                  ),
                  style: muted,
                ),
              if (widget.backup case final backup?) ...[
                const SizedBox(height: 6),
                IgnorePointer(
                  ignoring: busy,
                  child: FolderBackupControl(backup: backup),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).maybePop(),
              child: Text(t(context, 'cancel')),
            ),
            if (widget.backup case final backup?)
              ListenableBuilder(
                listenable: backup,
                builder: (context, _) => _saveButton(
                  backup.hasSelectedDirectory || backup.selecting
                      ? t(context, 'save')
                      : '仅暂存',
                  selecting: backup.selecting,
                ),
              )
            else
              _saveButton(
                widget.onRestoreTransits == null ? t(context, 'save') : '恢复',
              ),
          ],
        ),
      ),
    );
  }

  String _inputHint(BuildContext context) {
    if (widget.onRestoreTransits != null) {
      return '粘贴 BotAI 中转备份 TXT 或 UXUY 中转备份 JSON';
    }
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    if (widget.singleWallet) {
      if (!widget.keyBeforeAmount) return zh ? '请输入一把私钥' : 'Enter one private key';
      return zh
          ? '输入一把私钥，可在空格后填写首买金额'
          : 'Enter one private key, optionally followed by a space and the buy amount';
    }
    if (!widget.keyBeforeAmount) return t(context, 'keys_hint');
    return zh
        ? '每行一把私钥，可在空格后填写该钱包的首买金额'
        : 'One private key per line, optionally followed by a space and the buy amount';
  }

  Widget _saveButton(String label, {bool selecting = false}) => TextButton(
    onPressed: busy || selecting ? null : _save,
    child: busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label),
  );
}

/// The editor is centered on every screen, and the modal barrier never saves or discards a draft.
class KeyEditorRoute<T> extends PageRouteBuilder<T> {
  KeyEditorRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    super.settings,
  }) : super(
         opaque: false,
         barrierColor: const Color(0x33000000),
         barrierDismissible: false,
         transitionDuration: MediaQuery.disableAnimationsOf(context)
             ? Duration.zero
             : UiStyle.motion,
         reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
             ? Duration.zero
             : UiStyle.motion,
         pageBuilder: (context, _, _) => SafeArea(child: builder(context)),
         transitionsBuilder: uiDialogTransition,
       );
}
