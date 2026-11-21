import 'dart:convert';

import 'package:uxuy_trade/uxuy_trade.dart';
import 'package:web/web.dart' as web;

class BrowserImpactSettings {
  BrowserImpactSettings({
    String? Function()? read,
    void Function(String)? write,
  }) : _read = read ?? (() => web.window.localStorage.getItem(key)),
       _write = write ?? ((v) => web.window.localStorage.setItem(key, v));

  static const key = 'uxuy_trade.impact_settings.v1';
  final String? Function() _read;
  final void Function(String) _write;

  ImpactSettings? _stored() {
    final raw = _read();
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map) {
      throw const FormatException('设置记录不完整');
    }
    return ImpactSettings.parse(
      '${data['bundle']}',
      '${data['start']}',
      '${data['live']}',
    );
  }

  ImpactSettings load() {
    try {
      return _stored() ?? const ImpactSettings();
    } on Object {
      throw StateError('无法读取或验证浏览器中的价格影响设置');
    }
  }

  void save(ImpactSettings value) {
    try {
      _write(
        jsonEncode({
          'bundle': value.bundle,
          'start': value.intervalStart,
          'live': value.intervalLive,
        }),
      );
      final stored = _stored();
      if (stored == null ||
          stored.bundle != value.bundle ||
          stored.intervalStart != value.intervalStart ||
          stored.intervalLive != value.intervalLive) {
        throw const FormatException('回读的阈值有差异');
      }
    } on Object {
      throw StateError('价格影响设置保存或回查失败，请检查浏览器存储后重试');
    }
  }
}
