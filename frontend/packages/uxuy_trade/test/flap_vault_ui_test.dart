import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';
import 'package:uxuy_trade/src/ui/flap_vault_editor.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';

const _zero = '0x0000000000000000000000000000000000000000';
const _factory = '0x889C64Ba9fe1A0E371EDe0579098E0bd71135232';
const _secondFactory = '0x0000000000000000000000000000000000000022';
const _bncb = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';

class _Reader extends FlapVaultService {
  _Reader(super.api, this.result);
  Future<FlapVaultInfo> Function(
    String factory,
    String quote,
    FlapVaultSchema? legacy,
  )
  result;
  int reads = 0;

  @override
  Future<FlapVaultInfo> read(
    String factory, {
    required String quoteToken,
    FlapVaultSchema? legacySchema,
  }) {
    reads++;
    return result(factory, quoteToken, legacySchema);
  }
}

FlapVaultInfo _info(
  String factory,
  String quote, {
  String fieldName = 'receiver',
  bool array = false,
}) => FlapVaultInfo(
  factory: factory,
  quoteToken: quote,
  schema: FlapVaultSchema(
    isArray: array,
    fields: [
      FlapVaultField(name: fieldName, type: 'address', description: '收款地址'),
    ],
  ),
  // Custom factories may be open without being listed as curated.
  registered: false,
  permission: 0,
);

final _stockSchema = FlapVaultSchema(
  description: 'StockVault 标准参数',
  fields: [
    FlapVaultField(
      name: 'creatorWallet',
      type: 'address',
      description: 'Creator wallet (blank = launcher)',
    ),
    for (final name in [
      'creatorBps',
      'ownBurnBps',
      'thirdBurnBps',
      'fissionBps',
    ])
      FlapVaultField(name: name, type: 'uint16', description: '$name (bps)'),
    FlapVaultField(
      name: 'burnToken',
      type: 'address',
      description: 'Third-party token to burn (needs a WBNB pool)',
    ),
    FlapVaultField(
      name: 'intervalSeconds',
      type: 'uint256',
      description: 'Round interval in seconds, 1-3600, default 10',
    ),
    FlapVaultField(
      name: 'spendBps',
      type: 'uint16',
      description: 'Spend per round (bps), 100-10000',
    ),
    FlapVaultField(
      name: 'fissionRecipients',
      type: 'uint16',
      description: 'Fission addresses per round, 1-10',
    ),
  ],
);

void main() {
  late http.Client client;
  late BackendClient api;
  late _Reader reader;
  late GlobalKey<FlapVaultEditorState> key;

  setUp(() {
    client = MockClient(
      (_) async => throw StateError(
        'UI test must not send transactions or network requests',
      ),
    );
    api = BackendClient(Uri.parse('http://fixture.invalid/'), client);
    reader = _Reader(api, (factory, quote, _) async => _info(factory, quote));
    key = GlobalKey<FlapVaultEditorState>();
  });
  tearDown(() => client.close());

  Future<void> mount(
    WidgetTester tester, {
    String quote = _zero,
    bool locked = false,
    bool nonTax = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: componentTheme(uxuyTheme(ThemeData())),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FlapVaultEditor(
                key: key,
                api: api,
                service: reader,
                nonTax: nonTax,
                holderSettings: nonTax ? const Text('持有人收益') : null,
                quoteToken: quote,
                quoteSymbol: quote == _zero ? 'BNB' : 'BNCB',
                locked: locked,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('V7 allows its BNB Gift factory and resets incompatible drafts', (tester) async {
    reader.result = (factory, quote, _) async => FlapVaultInfo(
      factory: factory, quoteToken: quote,
      schema: FlapVaultSchema(fields: [FlapVaultField(name: 'xHandle', type: 'string')]),
    );
    await mount(tester, nonTax: true);
    expect(find.text('持有人收益'), findsOneWidget);
    final toggle = find.byKey(const ValueKey('flap-vault-enabled'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('持有人收益'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('vault-input-0-xHandle')), 'UXUY');
    expect(key.currentState!.capture()!.factory.toLowerCase(), flapV7GiftFactory.toLowerCase());
    await mount(tester, nonTax: true, quote: _bncb);
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(key.currentState!.capture(), isNull);
    expect(find.text('持有人收益'), findsOneWidget);
    await mount(tester, quote: _bncb);
    expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
  });

  Future<void> custom(WidgetTester tester, String address) async {
    await tester.tap(find.byKey(const ValueKey('flap-vault-enabled')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '自定义 Factory'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('flap-vault-factory')),
      address,
    );
    await tester.pump();
  }

  Future<void> read(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text('读取金库参数'));
    await tester.pump();
  }

  testWidgets(
    'disabled vault makes no request; invalid custom format blocks capture',
    (tester) async {
      await mount(tester);
      expect(reader.reads, 0);
      expect(key.currentState!.capture(), isNull);
      await custom(tester, 'not-a-factory');
      await read(tester);
      expect(find.text('金库格式有误'), findsOneWidget);
      expect(reader.reads, 0);
      expect(key.currentState!.capture, throwsStateError);
    },
  );

  testWidgets(
    'the user reference standard factory renders all nine parameters and captures immutable values',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      reader.result = (factory, quote, legacy) async {
        expect(
          legacy,
          isNull,
          reason: 'Custom factories must never inherit a curated ABI adapter',
        );
        return FlapVaultInfo(
          factory: factory,
          quoteToken: quote,
          schema: _stockSchema,
          specVersion: 'v2.3',
          permission: 0,
          registered: false,
        );
      };
      await mount(tester);
      await custom(tester, _factory);
      await read(tester);
      await tester.pumpAndSettle();
      final values = <String, String>{
        'creatorWallet': _secondFactory,
        'creatorBps': '3300',
        'ownBurnBps': '6600',
        'thirdBurnBps': '0',
        'fissionBps': '100',
        'burnToken': _zero,
        'intervalSeconds': '10',
        'spendBps': '100',
        'fissionRecipients': '10',
      };
      for (final entry in values.entries) {
        final field = find.byKey(ValueKey('vault-input-0-${entry.key}'));
        expect(field, findsOneWidget);
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
        await tester.pump();
      }
      final snapshot = key.currentState!.capture()!;
      expect(snapshot.rows.single, values);
      expect(snapshot.encode().isNotEmpty, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('vault-input-0-fissionRecipients')),
        '3',
      );
      expect(snapshot.rows.single['fissionRecipients'], '10');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stale factory response cannot overwrite a newer factory', (
    tester,
  ) async {
    final old = Completer<FlapVaultInfo>();
    reader.result = (factory, quote, _) =>
        factory.toLowerCase() == _factory.toLowerCase()
        ? old.future
        : Future.value(_info(factory, quote, fieldName: 'newReceiver'));
    await mount(tester);
    await custom(tester, _factory);
    await read(tester);
    expect(key.currentState!.capture, throwsStateError);
    await tester.enterText(
      find.byKey(const ValueKey('flap-vault-factory')),
      _secondFactory,
    );
    await read(tester);
    await tester.pumpAndSettle();
    old.complete(_info(_factory, _zero, fieldName: 'oldReceiver'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('vault-input-0-newReceiver')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('vault-input-0-oldReceiver')),
      findsNothing,
    );
  });

  testWidgets(
    'quote changes invalidate previous parameters even when the old request completes late',
    (tester) async {
      final old = Completer<FlapVaultInfo>();
      reader.result = (factory, quote, _) => quote == _zero
          ? old.future
          : Future.value(_info(factory, quote, fieldName: 'quoteReceiver'));
      await mount(tester);
      await custom(tester, _factory);
      await read(tester);
      await mount(tester, quote: _bncb);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('vault-input-0-quoteReceiver')),
        _secondFactory,
      );
      old.complete(_info(_factory, _zero, fieldName: 'oldReceiver'));
      await tester.pumpAndSettle();
      expect(key.currentState!.capture()!.info.quoteToken, _bncb);
      expect(reader.reads, 2);
      expect(
        find.byKey(const ValueKey('vault-input-0-oldReceiver')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'schema error and network failure have distinct inline messages',
    (tester) async {
      reader.result = (_, _, _) async =>
          throw const FormatException('unsupported schema');
      await mount(tester);
      await custom(tester, _factory);
      await read(tester);
      await tester.pumpAndSettle();
      expect(find.text('金库格式有误'), findsOneWidget);
      reader.result = (_, _, _) async => throw StateError('金库读取失败，请重试');
      await read(tester);
      await tester.pumpAndSettle();
      expect(find.text('金库读取失败，请重试'), findsOneWidget);
      expect(find.text('金库格式有误'), findsNothing);
    },
  );

  testWidgets('refresh preserves all recipients across a transient failure, clears an incompatible schema', (tester) async {
    reader.result = (factory, quote, _) async => _info(factory, quote, array: true);
    await mount(tester);
    await custom(tester, _factory);
    await read(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加一组'));
    await tester.pumpAndSettle();
    for (final (index, owner) in [_factory, _secondFactory].indexed) {
      await tester.enterText(find.byKey(ValueKey('vault-input-$index-receiver')), owner);
    }
    Future<void> refresh() async {
      final button = find.text('刷新参数');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    reader.result = (_, _, _) async => throw StateError('读取失败');
    await refresh();
    expect(() => key.currentState!.capture(), throwsStateError);
    reader.result = (factory, quote, _) async => _info(factory, quote, array: true);
    await refresh();
    expect(key.currentState!.capture()!.rows.map((r) => r['receiver']), [_factory, _secondFactory]);
    reader.result = (factory, quote, _) async => _info(factory, quote, fieldName: 'newReceiver');
    await refresh();
    expect(find.text('金库参数格式已变更，请重新填写并核对。'), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-input-0-newReceiver')), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-input-0-receiver')), findsNothing);
    expect(() => key.currentState!.capture(), throwsFormatException);
  });

  testWidgets('array form supports rows and locks inputs while preparing', (
    tester,
  ) async {
    reader.result = (factory, quote, _) async =>
        _info(factory, quote, array: true);
    await mount(tester);
    await custom(tester, _factory);
    await read(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加一组'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('vault-input-0-receiver')),
      _factory,
    );
    await tester.enterText(
      find.byKey(const ValueKey('vault-input-1-receiver')),
      _secondFactory,
    );
    expect(key.currentState!.capture()!.rows.length, 2);
    await mount(tester, locked: true);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('vault-input-0-receiver')),
          )
          .enabled,
      isFalse,
    );
    final add = tester.widget<SmallButton>(
      find.widgetWithText(SmallButton, '添加一组'),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('compact editor fits a narrow viewport without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    reader.result = (factory, quote, _) async => FlapVaultInfo(
      factory: factory,
      quoteToken: quote,
      schema: _stockSchema,
    );
    await mount(tester);
    await custom(tester, _factory);
    await read(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(10));
    expect(tester.takeException(), isNull);
  });
}
