import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../exec/flap_vault.dart';
import '../exec/flap_vault_catalog.dart';
import '../exec/flap_vault_adapters.dart';
import '../exec/market.dart' show zeroAddress;
import 'widgets.dart';

/// A local editor only: loading a Factory never uploads keys or submits a transaction.
/// The execution layer revalidates the captured selection against live contract state.
class FlapVaultEditor extends StatefulWidget {
  const FlapVaultEditor({
    super.key,
    required this.api,
    required this.quoteToken,
    required this.quoteSymbol,
    this.quoteDecimals = 18,
    this.service,
    this.nonTax = false,
    this.holderSettings,
    this.locked = false,
  });

  final BackendClient api;
  final String quoteToken;
  final String quoteSymbol;
  final int quoteDecimals;
  final FlapVaultService? service;
  final bool nonTax;
  final Widget? holderSettings;
  final bool locked;

  @override
  State<FlapVaultEditor> createState() => FlapVaultEditorState();
}

class FlapVaultEditorState extends State<FlapVaultEditor> {
  final _customAddress = TextEditingController();
  final _rows = <Map<String, TextEditingController>>[];
  final _cache = <String, (DateTime, FlapVaultInfo)>{};
  bool _enabled = false;
  bool _custom = false;
  bool _loading = false;
  String? _curatedFactory;
  String? _modeFactory;
  FlapVaultInfo? _info;
  String? _error;
  bool _schemaChanged = false;
  int _readEpoch = 0;

  String get _factory => _custom
      ? _customAddress.text.trim()
      : (_modeFactory ?? _curatedFactory ?? '');

  Iterable<FlapCuratedVault> get _catalog => widget.nonTax
      ? const [
          FlapCuratedVault(
            factory: flapV7GiftFactory,
            name: '礼物金库',
            officialName: 'gift',
          ),
        ]
      : flapCuratedVaults;

  FlapCuratedVault? get _curated {
    for (final vault in _catalog) {
      if (vault.factory.toLowerCase() == _curatedFactory?.toLowerCase()) {
        return vault;
      }
    }
    return null;
  }

  /// Snapshot is created before the confirmation dialog; mutable field controllers
  /// and late requests cannot change what the user is about to confirm.
  FlapVaultSelection? capture() {
    if (!_enabled) return null;
    if (_loading) throw StateError('金库参数正在读取，请稍候');
    if (_error != null) throw StateError(_error!);
    final info = _info;
    if (info == null) throw StateError('请先选择并读取金库参数');
    if (info.factory.toLowerCase() != _factory.toLowerCase() ||
        info.quoteToken.toLowerCase() != widget.quoteToken.toLowerCase()) {
      throw StateError('底池或金库已改变，请重新读取金库参数');
    }
    if (!info.supportsQuote) throw StateError('该金库不支持所选底池代币');
    final rows = [
      for (final row in _rows)
        {for (final field in row.entries) field.key: field.value.text.trim()},
    ];
    final selection = _custom
        ? FlapVaultSelection(info: info, rows: rows)
        : buildFlapCuratedSelection(info: info, rows: rows);
    selection.encode();
    return selection;
  }

  @override
  void didUpdateWidget(covariant FlapVaultEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nonTax != widget.nonTax ||
        (widget.nonTax &&
            oldWidget.quoteToken.toLowerCase() !=
                widget.quoteToken.toLowerCase() &&
            widget.quoteToken.toLowerCase() != zeroAddress)) {
      _enabled = false;
      _custom = false;
      _curatedFactory = null;
      _modeFactory = null;
      _customAddress.clear();
      _invalidate();
      return;
    }
    if (oldWidget.api != widget.api ||
        oldWidget.quoteToken.toLowerCase() != widget.quoteToken.toLowerCase()) {
      _invalidate();
      if (_enabled && isAddress(_factory)) {
        // Run after the parent's build so no async result updates an old quote.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.locked) _read();
        });
      }
    }
  }

  @override
  void dispose() {
    _readEpoch++;
    _customAddress.dispose();
    _disposeRows();
    super.dispose();
  }

  void _disposeRows({bool afterFrame = false}) {
    final controllers = _rows.expand((row) => row.values).toList();
    _rows.clear();
    void release() {
      for (final controller in controllers) {
        controller.dispose();
      }
    }
    if (afterFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    } else {
      release();
    }
  }

  void _invalidate() {
    _readEpoch++;
    _info = null;
    _error = null;
    _loading = false;
    _schemaChanged = false;
    _disposeRows(afterFrame: true);
  }

  Map<String, TextEditingController> _newRow(FlapVaultSchema schema) {
    final defaults = _custom
        ? <String, String>{}
        : Map<String, String>.of(flapCuratedDefaults(_factory));
    if (!_custom && _factory.toLowerCase() == flapMyxFactory.toLowerCase()) {
      final native = widget.quoteToken.toLowerCase() == zeroAddress;
      defaults['minProcessAmount'] = parseUnits(
        native ? '0.1' : '1',
        widget.quoteDecimals,
      ).toString();
      defaults['gasThreshold'] = native ? '0' : '0.005';
      defaults['gasRefillAmount'] = native ? '0' : '0.01';
    }
    return {
      for (final field in schema.fields)
        field.name: TextEditingController(
          text: defaults[field.name] ?? (field.type == 'bool' ? 'false' : ''),
        ),
    };
  }

  Future<void> _read({bool refresh = false}) async {
    if (widget.locked || !_enabled) return;
    final factory = _factory;
    if (!isAddress(factory) || factory.toLowerCase() == zeroAddress) {
      setState(() {
        _invalidate();
        _error = '金库格式有误';
      });
      return;
    }
    if (widget.nonTax && !isFlapV7GiftFactory(factory)) {
      setState(() {
        _invalidate();
        _error = 'Flap V7 仅接受官方指定的礼物金库 Factory';
      });
      return;
    }
    final epoch = ++_readEpoch;
    final quote = widget.quoteToken;
    final key =
        '${_custom ? 'custom' : 'curated'}:${factory.toLowerCase()}:${quote.toLowerCase()}';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = _cache[key];
      final info =
          !refresh &&
              cached != null &&
              DateTime.now().difference(cached.$1) < const Duration(minutes: 1)
          ? cached.$2
          : await (widget.service ?? FlapVaultService(widget.api)).read(
              factory,
              quoteToken: quote,
              legacySchema: _custom ? null : flapCuratedSchema(factory),
            );
      if (!mounted || epoch != _readEpoch) return;
      if (info.factory.toLowerCase() != factory.toLowerCase() ||
          info.quoteToken.toLowerCase() != quote.toLowerCase()) {
        throw StateError('金库或底池地址与本次读取不一致');
      }
      if (_cache.length >= 16) _cache.remove(_cache.keys.first);
      _cache[key] = (DateTime.now(), info);
      setState(() {
        _schemaChanged = _info != null && _info!.schemaFingerprint != info.schemaFingerprint;
        if (_info == null || _schemaChanged) {
          _disposeRows(afterFrame: true);
          _rows.add(_newRow(info.schema));
        }
        _info = info;
        _loading = false;
        if (!info.supportsQuote) _error = '该金库不支持 ${widget.quoteSymbol} 底池';
      });
    } on Object catch (e) {
      if (!mounted || epoch != _readEpoch) return;
      setState(() {
        _loading = false;
        _error = e is FormatException
            ? '金库格式有误'
            : e is BackendException
            ? '金库读取失败，请重试'
            : e is StateError
            ? e.message
            : '金库读取失败，请重试';
      });
    }
  }

  String _fieldLabel(FlapVaultField field) {
    final parts = field.description.split('/');
    for (final part in parts.reversed) {
      if (RegExp(r'[\u4e00-\u9fff]').hasMatch(part) &&
          part.trim().length <= 45) {
        return part.trim();
      }
    }
    return field.description.trim().isNotEmpty && field.description.length <= 65
        ? field.description.trim()
        : field.name;
  }

  Widget _input(FlapVaultField field, TextEditingController controller) {
    final title = _fieldLabel(field);
    final address = field.type == 'address';
    return SizedBox(
      width: address || field.type.endsWith('[]') ? 420 : 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: field.description.isEmpty ? field.name : field.description,
            child: Text(
              title,
              style: label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
          if (field.type == 'bool')
            OptionPair<bool>(
              compact: true,
              options: const [(false, '否'), (true, '是')],
              value: controller.text == 'true',
              onChanged: widget.locked
                  ? null
                  : (value) => setState(() => controller.text = '$value'),
            )
          else
            TextField(
              key: ValueKey(
                'vault-input-${_rows.indexWhere((row) => row[field.name] == controller)}-${field.name}',
              ),
              controller: controller,
              enabled: !widget.locked,
              style: const TextStyle(fontSize: 14),
              minLines: 1,
              maxLines: address ? null : (field.type.endsWith('[]') ? 3 : 1),
              keyboardType: address ? TextInputType.text : null,
              textInputAction: address ? TextInputAction.done : null,
              inputFormatters: address
                  ? [FilteringTextInputFormatter.singleLineFormatter]
                  : null,
              decoration: InputDecoration(
                hintText: field.type.endsWith('[]') ? '每行一个值' : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _parameters(FlapVaultInfo info) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _rows.length; i++) ...[
        if (info.schema.isArray)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Row(
              children: [
                Text('参数组 ${i + 1}', style: label),
                const SizedBox(width: 12),
                if (_rows.length > 1)
                  SmallButton(
                    label: '移除',
                    onPressed: widget.locked
                        ? null
                        : () => setState(() {
                            final row = _rows.removeAt(i);
                            // Keep controllers alive until the removed fields unmount.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              for (final controller in row.values) {
                                controller.dispose();
                              }
                            });
                          }),
                  ),
              ],
            ),
          ),
        Wrap(
          spacing: 14,
          runSpacing: 12,
          children: [
            for (final field in info.schema.fields)
              _input(field, _rows[i][field.name]!),
          ],
        ),
      ],
      if (info.schema.isArray)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SmallButton(
            label: '添加一组',
            onPressed: widget.locked || _rows.length >= 128
                ? null
                : () => setState(() => _rows.add(_newRow(info.schema))),
          ),
        ),
      if (info.schema.fields.isEmpty) const Text('此金库无需填写额外参数。', style: muted),
    ],
  );

  List<Widget> _curatedRequirements() {
    final constraints = _curated?.constraints ?? const <String, Object?>{};
    final text = <String>[];
    final fixed = constraints['fixedVaultBps'];
    if (fixed is num) text.add('创作者/金库分配需设为 ${fixed / 100}%。');
    if (constraints['maxDividendBps'] == 0) text.add('直接分红比例需设为 0%。');
    if (constraints['requiresErc20QuoteToken'] == true) text.add('需要使用代币底池。');
    if (constraints['requiredQuoteTokenSymbol'] case final String symbol)
      text.add('底池需为 $symbol。');
    if (constraints['excludedQuoteTokenSymbols'] case final List symbols)
      text.add('不支持底池：${symbols.join('、')}。');
    return [
      for (final line in text)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(line, style: muted),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Switch(
            key: const ValueKey('flap-vault-enabled'),
            value: _enabled,
            onChanged:
                widget.locked ||
                    (widget.nonTax &&
                        widget.quoteToken.toLowerCase() != zeroAddress)
                ? null
                : (value) => setState(() {
                    _enabled = value;
                    if (value && widget.nonTax && !_custom) {
                      _curatedFactory ??= flapV7GiftFactory;
                    }
                    _invalidate();
                    if (value && isAddress(_factory)) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _read();
                      });
                    }
                  }),
          ),
          const SizedBox(width: 6),
          const Text('使用金库', style: strong),
        ],
      ),
      if (!_enabled && widget.holderSettings != null) widget.holderSettings!,
      if (widget.nonTax && widget.quoteToken.toLowerCase() != zeroAddress)
        const Text('V7 礼物金库仅支持 BNB 底池。', style: muted),
      if (_enabled) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            widget.nonTax
                ? '可分配的 LP 手续费全部归礼物金库。最近链上模拟被 Flap 拒绝，提交前将重新模拟。'
                : '金库使用创作者分配部分的收入执行策略。',
            style: muted,
          ),
        ),
        OptionPair<bool>(
          options: const [(false, '精选金库'), (true, '自定义 Factory')],
          value: _custom,
          onChanged: widget.locked
              ? null
              : (value) => setState(() {
                  _custom = value;
                  _invalidate();
                  if (isAddress(_factory)) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _read();
                    });
                  }
                }),
        ),
        const SizedBox(height: 12),
        if (_custom)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: TextField(
              key: const ValueKey('flap-vault-factory'),
              controller: _customAddress,
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                FilteringTextInputFormatter.singleLineFormatter,
              ],
              enabled: !widget.locked,
              style: const TextStyle(fontSize: 14),
              onChanged: (_) => setState(_invalidate),
              onSubmitted: (_) => _read(),
              decoration: const InputDecoration(
                hintText: 'Factory 地址，非金库实例地址',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: UiSelect<String>(
              semanticLabel: '精选金库',
              value: _curatedFactory,
              options: [
                for (final vault in _catalog) (vault.factory, vault.name),
              ],
              onChanged: widget.locked
                  ? null
                  : (value) {
                      setState(() {
                        _curatedFactory = value;
                        _modeFactory = null;
                        _invalidate();
                      });
                      _read();
                    },
            ),
          ),
        if (!_custom && (_curated?.modes.isNotEmpty ?? false)) ...[
          const SizedBox(height: 10),
          OptionPair<String>(
            compact: true,
            options: [
              for (final mode in _curated!.modes) (mode.factory, mode.name),
            ],
            value: _factory,
            onChanged: widget.locked
                ? null
                : (factory) {
                    setState(() {
                      _modeFactory = factory;
                      _invalidate();
                    });
                    _read();
                  },
          ),
        ],
        if (!_custom && (_curated?.summary.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_curated!.summary, style: muted),
          ),
        if (_custom || _factory.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SmallButton(
                  label: _loading
                      ? '读取中…'
                      : _info == null
                      ? '读取金库参数'
                      : '刷新参数',
                  onPressed: widget.locked || _loading
                      ? null
                      : () => _read(refresh: true),
              ),
            ),
          ),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('flap-vault-error'),
            style: const TextStyle(color: UiStyle.negative, fontSize: 14),
          ),
        if (_info case final info?) ...[
          if (_schemaChanged) const Text('金库参数格式已变更，请重新填写并核对。', style: muted),
          if (!_custom)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SelectableText(
                info.factory,
                semanticsLabel: info.factory,
                style: mono,
              ),
            ),
          if (info.supportsQuote) _parameters(info),
          const SizedBox(height: 10),
          UiAccordion(
            title: '金库要求与说明',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_custom) ..._curatedRequirements(),
                if (info.schema.description.isNotEmpty)
                  Text(info.schema.description, style: muted),
                for (final policy in info.policies)
                  if (policy.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(policy.description, style: muted),
                    ),
                const SizedBox(height: 6),
                const Text('金库由独立合约运行，请核对收益分配和接收者。', style: muted),
              ],
            ),
          ),
        ],
      ],
    ],
  );
}
