import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/batch_page.dart';
import 'package:uxuy_trade/src/ui/linked_page.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

Widget _app(AppState state, String language) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData(useMaterial3: true)),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: state,
      builder: (_, _) => BatchPage(state: state),
    ),
  ),
);

Future<void> _choose(
  WidgetTester tester,
  BuildContext context,
  String key,
) async {
  final button = find.widgetWithText(TextButton, t(context, key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void _expectCompactControls(WidgetTester tester, double viewportWidth) {
  final choices = find.byWidgetPredicate((widget) => widget is OptionPair);
  for (final choice in choices.evaluate()) {
    final buttons = find.descendant(
      of: find.byWidget(choice.widget),
      matching: find.byType(TextButton),
    );
    for (final button in buttons.evaluate()) {
      final size = tester.getSize(find.byWidget(button.widget));
      expect(size.width, lessThanOrEqualTo(170));
      expect(size.height, greaterThanOrEqualTo(32));
    }
  }
  final ranges = find.byType(RangeRow);
  expect(ranges, findsNWidgets(2));
  expect(tester.getSize(ranges.first).width, lessThanOrEqualTo(360));
  expect(tester.getSize(ranges.last).width, lessThanOrEqualTo(280));
  for (final field in find.byType(TextField).evaluate()) {
    final rect = tester.getRect(find.byWidget(field.widget));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(viewportWidth));
    expect(rect.width, greaterThanOrEqualTo(55));
  }
  final primary = find.byType(PrimaryButton);
  expect(primary, findsOneWidget);
  expect(tester.getSize(primary).width, lessThanOrEqualTo(320));
  // Empty groups still cannot start; this test never invokes execution.
  final action = tester.widget<FilledButton>(
    find.descendant(of: primary, matching: find.byType(FilledButton)),
  );
  expect(action.onPressed, isNull);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final language in ['zh', 'en']) {
    for (final width in [1440.0, 1000.0, 390.0, 320.0]) {
      testWidgets('batch controls $language/$width stay compact and usable', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final backend = FakeBackend();
        final state = AppState(
          BackendClient(Uri.parse('http://isolated.test/'), backend.client()),
          MemoryKeyStore(),
        )..token = const TokenMeta(token, 'PancakeSwap Token', 'CAKE', 18);
        addTearDown(state.dispose);
        await state.init();
        final ordinary = state.addGroup();
        await tester.pumpWidget(_app(state, language));
        await tester.pumpAndSettle();
        _expectCompactControls(tester, width);
        if (width >= 1000) {
          final workspace = tester.widget<TradeColumns>(
            find.byType(TradeColumns),
          );
          final wallets = tester.getRect(find.byWidget(workspace.left));
          final settings = tester.getRect(find.byWidget(workspace.right));
          expect(wallets.width, lessThanOrEqualTo(520));
          expect(settings.left, wallets.left);
          expect(settings.top, greaterThan(wallets.bottom));
        }

        final ordinaryContext = tester.element(find.byType(GroupDetail));
        await _choose(tester, ordinaryContext, 'bundle');
        expect(find.byType(RangeRow), findsOneWidget);
        await _choose(tester, ordinaryContext, 'interval');
        await _choose(tester, ordinaryContext, 'sell');
        await _choose(tester, ordinaryContext, 'random');
        expect(ordinary.buy, isFalse);
        expect(ordinary.ratio, isTrue);
        expect(ordinary.randomOrder, isTrue);
        final ordinaryRange = find.descendant(
          of: find.byType(RangeRow).first,
          matching: find.byType(TextField),
        );
        await tester.enterText(ordinaryRange.first, '17');
        await tester.enterText(ordinaryRange.last, '21');
        expect(ordinary.min, '17');
        expect(ordinary.max, '21');
        _expectCompactControls(tester, width);

        final linked = state.addLinkedGroup();
        await tester.pumpAndSettle();
        _expectCompactControls(tester, width);
        final linkedContext = tester.element(find.byType(LinkedGroupDetail));
        await _choose(tester, linkedContext, 'quantity');
        await _choose(tester, linkedContext, 'random');
        final linkedRange = find.descendant(
          of: find.byType(RangeRow).first,
          matching: find.byType(TextField),
        );
        await tester.enterText(linkedRange.first, '15.5');
        await tester.enterText(linkedRange.last, '20.5');
        expect(linked.ratio, isFalse);
        expect(linked.randomOrder, isTrue);
        expect(linked.min, '15.5');
        expect(linked.max, '20.5');
        _expectCompactControls(tester, width);
        expect(backend.submitted, isEmpty);
        expect(backend.bundles, isEmpty);
        expect(backend.calls, everyElement('config'));
      });
    }
  }
}
