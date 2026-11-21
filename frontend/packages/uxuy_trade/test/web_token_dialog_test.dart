import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/dialogs.dart';
import 'package:uxuy_trade/src/ui/shell.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

const _token = '0x0000000000000000000000000000000000000001';

Widget _app(AppState state) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData.light()),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => openTokenEditor(context, state),
          child: const Text('选择'),
        ),
      ),
    ),
  ),
);

http.Response _json(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  for (final width in [1280.0, 390.0, 320.0]) {
    testWidgets(
      'token editor is centered and invalid input stays inline at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return _json({'ok': false, 'code': 'FIXTURE', 'message': '代币暂时无法加载'});
        });
        final state = AppState(
          BackendClient(Uri.parse('http://fixture.invalid/'), client),
          MemoryKeyStore(),
        );
        addTearDown(state.dispose);
        addTearDown(client.close);
        await tester.pumpWidget(_app(state));
        await tester.tap(find.text('选择'));
        await tester.pumpAndSettle();
        expect(find.byType(UiDialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        final rect = tester.getRect(find.byType(Dialog));
        // Dialog's render box includes its alignment; inspect the material surface.
        final material = find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Material),
            )
            .first;
        final surface = tester.getRect(material);
        expect(surface.center.dx, closeTo(width / 2, 1));
        expect(surface.center.dy, closeTo(360, 1));
        expect(surface.width, lessThanOrEqualTo(width - 32));
        expect(rect.bottom, lessThanOrEqualTo(720));
        final input = find.byKey(const ValueKey('token-address-input'));
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.enterText(input, 'invalid');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text('请输入有效的代币地址'), findsOneWidget);
        expect(find.byType(UiDialog), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(requests, 0);
        await tester.enterText(input, _token);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.textContaining('代币暂时无法加载'), findsOneWidget);
        expect(find.text('请输入有效的代币地址'), findsNothing);
        expect(find.byType(UiDialog), findsOneWidget);
        // Metadata and market are fetched concurrently and committed atomically.
        expect(requests, 2);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(UiDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'busy token load prevents duplicate Enter, Escape, close and barrier dismissal',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pending = Completer<http.Response>();
      var requests = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/tokens/')) {
          requests++;
          return pending.future;
        }
        return _json({
          'ok': true,
          'result': {
            'address': _token,
            'symbol': 'TEST',
            'decimals': 18,
            'platform': 'external',
            'external': true,
            'quote': '0x0000000000000000000000000000000000000000',
            'block': 100,
          },
        });
      });
      final state = AppState(
        BackendClient(Uri.parse('http://fixture.invalid/'), client),
        MemoryKeyStore(),
      );
      addTearDown(state.dispose);
      addTearDown(client.close);
      await tester.pumpWidget(_app(state));
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('token-address-input'));
      await tester.enterText(input, _token);
      final submit = tester.widget<TextField>(input).onSubmitted!;
      submit(_token);
      submit(_token);
      await tester.pump();
      expect(requests, 1);
      expect(tester.widget<TextField>(input).enabled, isFalse);
      expect(tester.widget<UiDialog>(find.byType(UiDialog)).canClose, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(UiDialog), findsOneWidget);
      pending.complete(
        _json({
          'ok': true,
          'token': {
            'token': _token,
            'name': 'Test token',
            'symbol': 'TEST',
            'decimals': 18,
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiDialog), findsNothing);
      expect(state.token?.symbol, 'TEST');
      expect(requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
