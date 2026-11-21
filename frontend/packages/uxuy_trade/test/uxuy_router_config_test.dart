import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

void main() {
  final valid = {
    'router': router,
    'approvalSpender': pool,
    'routeSource': 'uxuy',
    'routeEnabled': true,
    'maxPriceImpactPercent': 10,
  };
  test('route execution requires an active UXUY configuration and both nonzero pinned addresses', () {
    final config = ModuleConfig.fromJson(valid);
    config.requireUxuySwap();
    expect(config.approvalSpender, pool);
    for (final bad in [
      {...valid, 'routeSource': 'okx'},
      {...valid, 'routeEnabled': false},
      {...valid, 'router': '0x${'0' * 40}'},
      {...valid}..remove('approvalSpender'),
      {...valid}..remove('routeSource'),
    ]) {
      expect(
        () => ModuleConfig.fromJson(bad).requireUxuySwap(),
        throwsA(isA<BackendException>()),
      );
    }
  });

  test('public website refuses the old charging backend before signing or submission', () async {
    var configuration = <String, Object?>{
      'ok': true, 'chainId': 56, 'router': router, 'maxPriceImpactPercent': 7,
      'fastPreflightVersion': 1, 'feeDenominator': 1000000,
      'feeRate': 3000, 'launchServiceFeeWei': '10000000000000000',
    };
    final requests = <String>[];
    var configOffline = false;
    final api = BackendClient(Uri.parse('https://example.invalid/'), MockClient((request) async {
      final path = request.url.path;
      requests.add(path);
      if (path == '/api/v1/config' && configOffline) {
        return http.Response('{"ok":false,"code":"UNAVAILABLE"}', 503);
      }
      if (path == '/api/v1/config') return http.Response(jsonEncode(configuration), 200);
      if (path == '/api/v1/rpc-latency') return http.Response('{"ok":true,"ms":15}', 200);
      fail('Unexpected network operation: $path');
    }), requireFeeFreeService: true);
    final state = AppState(api, MemoryKeyStore());
    addTearDown(state.dispose);
    var signed = false;
    Future<void> visitLaunch() => state.withWalletUse(
      owner: state.four, label: 'Four', addresses: [],
      action: () async { signed = true; },
    );
    final charging = throwsA(isA<WorkspaceConflict>()
        .having((e) => e.reason, 'message', contains('仍配置了本站收费')));

    expect(() => state.four.checkWorkspace!(), throwsA(isA<WorkspaceConflict>()));
    await state.init();
    await expectLater(visitLaunch(), charging);
    for (final engine in [state.four, state.flap, state.genius]) {
      expect(() => engine.checkWorkspace!(), charging);
    }
    expect(() => state.transfers.checkWorkspace!(), charging);
    expect(() => state.checkWalletUse(state.addGroup(), []), charging);
    expect(signed, false);
    final blocked = throwsA(isA<BackendException>()
        .having((e) => e.code, 'code', 'LEGACY_SERVICE_FEE')
        .having((e) => e.notSubmitted, 'notSubmitted', true));
    await expectLater(api.bundle(['0x00'], 12), blocked);
    await expectLater(api.submit('0x00'), blocked);
    expect((await api.nodeLatency()).ms, 15);
    expect(requests.every((p) => p.endsWith('/config') || p.endsWith('/rpc-latency')), true);

    // A rollout can change the service while the tab is open. Official launches
    // remain available with the regular UXUY routing feature disabled.
    configuration = {...valid, 'ok': true, 'routeEnabled': false};
    await visitLaunch();
    expect(signed, true);
    expect(api.financialConfigError, isNull);
    expect(() => state.flap.checkWorkspace!(), returnsNormally);
    for (final override in [{'feeRate': 3}, {'launchServiceFeeWei': '1'}]) {
      configuration = {...valid, 'ok': true, ...override};
      signed = false;
      await expectLater(visitLaunch(), charging);
      expect(signed, false);
    }
    for (final override in [{'feeRate': 'unknown'}, {'routeSource': 'unknown'}]) {
      configuration = {...valid, 'ok': true, ...override};
      await expectLater(visitLaunch(), throwsA(isA<WorkspaceConflict>()));
      expect(api.financialConfigError?.code, 'UNVERIFIED_SERVICE');
      expect(signed, false);
    }
    configuration = {...valid, 'ok': true, 'feeRate': 0, 'launchServiceFeeWei': '0'};
    await visitLaunch();
    expect(signed, true);
    configOffline = true;
    signed = false;
    await expectLater(visitLaunch(), throwsA(isA<WorkspaceConflict>()));
    expect(signed, false);
    await expectLater(api.submit('0x00'), throwsA(isA<BackendException>()
        .having((e) => e.code, 'code', 'UNVERIFIED_SERVICE')
        .having((e) => e.notSubmitted, 'notSubmitted', true)));
    configOffline = false;
    await visitLaunch();
    expect(signed, true);
    expect(requests.every((p) => p.endsWith('/config') || p.endsWith('/rpc-latency')), true);
  });
}
