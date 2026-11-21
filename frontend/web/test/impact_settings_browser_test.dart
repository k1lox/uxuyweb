@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/uxuy_trade.dart';
import 'package:uxuy_web/browser_impact_settings.dart';
import 'package:web/web.dart' as web;

void main() {
  test('Chrome persists three thresholds including zero and rereads them in a new instance', () {
    final storage = web.window.localStorage;
    storage.removeItem(BrowserImpactSettings.key);
    addTearDown(() => storage.removeItem(BrowserImpactSettings.key));
    const value = ImpactSettings(
      bundle: 0,
      intervalStart: 0.125,
      intervalLive: 0,
    );
    final session = BrowserImpactSettings();
    expect(session.load().bundle, 20);
    session.save(value);
    final reloaded = BrowserImpactSettings().load();
    expect(
      [reloaded.bundle, reloaded.intervalStart, reloaded.intervalLive],
      [0, .125, 0],
    );
    storage.setItem(
      BrowserImpactSettings.key,
      '{"bundle":0,"start":0,"live":null}',
    );
    expect(() => BrowserImpactSettings().load(), throwsStateError);
  });
  test('write errors, missing data and changed thresholds never acknowledge a save', () {
    const value = ImpactSettings(bundle: 0, intervalStart: 0, intervalLive: 0);
    for (final raw in [
      null,
      '{"bundle":0,"start":0,"live":1}',
      '{"bundle":0}',
      'invalid',
    ]) {
      final changed = BrowserImpactSettings(read: () => raw, write: (_) {});
      expect(() => changed.save(value), throwsStateError);
    }
    final denied = BrowserImpactSettings(
      read: () => null,
      write: (_) => throw StateError('denied'),
    );
    expect(() => denied.save(value), throwsStateError);
  });
}
