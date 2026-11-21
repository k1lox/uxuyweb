import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/batch_group_help.dart';

void main() {
  Future<void> mount(WidgetTester tester, Size size, Locale locale) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topRight,
              child: BatchGroupHelpButton(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Both the hover delay and the overlay animation run on the widget clock.
  Future<void> settleHover(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'hover opens the table, moving into it keeps it open, leaving or Escape closes it',
    (tester) async {
      await mount(tester, const Size(1280, 800), const Locale('zh'));
      final trigger = find.byType(BatchGroupHelpButton);
      final ordinary = find.text('普通组');
      final linked = find.text('关联组');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(4, 700));
      addTearDown(mouse.removePointer);
      expect(ordinary, findsNothing);

      await mouse.moveTo(tester.getCenter(trigger));
      await settleHover(tester);
      expect(ordinary, findsOneWidget);
      expect(linked, findsOneWidget);
      expect(find.textContaining('1,000'), findsWidgets);
      expect(find.textContaining('0.2 BNB'), findsWidgets);

      await mouse.moveTo(tester.getCenter(linked));
      await settleHover(tester);
      expect(ordinary, findsOneWidget);
      await mouse.moveTo(const Offset(4, 700));
      await settleHover(tester);
      expect(ordinary, findsNothing);

      await mouse.moveTo(tester.getCenter(trigger));
      await settleHover(tester);
      expect(ordinary, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleHover(tester);
      expect(ordinary, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow touch screen opens the English comparison, toggles it and dismisses outside',
    (tester) async {
      const size = Size(320, 700);
      await mount(tester, size, const Locale('en'));
      final trigger = find.byType(BatchGroupHelpButton);
      final linked = find.text('Linked group');
      final namedButton = find.bySemanticsLabel('Group types explained');
      expect(namedButton, findsOneWidget);
      expect(
        tester
            .getSemantics(namedButton)
            .getSemanticsData()
            .flagsCollection
            .isButton,
        isTrue,
      );
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('Normal group'), findsOneWidget);
      expect(linked, findsOneWidget);
      final example = find.textContaining('0.2 BNB');
      expect(example, findsWidgets);
      for (final element in [linked, example.first]) {
        final rect = tester.getRect(element);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(linked, findsNothing);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(linked, findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(linked, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
