import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/select.dart';

import 'support/address_visibility.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required ValueChanged<int> onChanged,
    List<(int, String)>? options,
    Alignment alignment = Alignment.topLeft,
    bool enabled = true,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Align(
              alignment: alignment,
              child: SizedBox(
                width: 500,
                child: UiSelect<int>(
                  key: const ValueKey('select'),
                  options:
                      options ??
                      const [(0, 'Alpha'), (1, 'Beta'), (2, 'Gamma')],
                  value: 0,
                  onChanged: enabled ? onChanged : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAllTestValues(),
  );

  testWidgets(
    'opening exposes all menu rows on the first frame without a height reveal delay',
    (tester) async {
      addTearDown(tester.view.reset);
      int? selected;
      await mount(tester, onChanged: (value) => selected = value);
      await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
      // One rendered frame only: no pumpAndSettle or fixed 500ms wait.
      await tester.pump();
      final menu = find.byKey(const ValueKey('ui-select-menu'));
      final initial = tester.getRect(menu);
      expect(initial.height, 104);
      expect(find.text('Gamma').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Gamma'));
      await tester.pump();
      expect(selected, 2);
      expect(menu, findsNothing);
    },
  );

  testWidgets(
    'compact neutral menu anchors below and flips above near bottom',
    (tester) async {
      addTearDown(tester.view.reset);
      int? selected;
      await mount(tester, onChanged: (value) => selected = value);
      final trigger = find.byKey(const ValueKey('ui-select-trigger'));
      final triggerRect = tester.getRect(trigger);
      expect(triggerRect.height, 36);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('ui-select-menu'));
      var menuRect = tester.getRect(menu);
      expect(menuRect.top, greaterThanOrEqualTo(triggerRect.bottom));
      expect(menuRect.width, lessThanOrEqualTo(360));
      expect(menuRect.height, lessThanOrEqualTo(260));
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(menu, findsNothing);
      await mount(tester, alignment: Alignment.bottomRight, onChanged: (_) {});
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      menuRect = tester.getRect(menu);
      expect(menuRect.bottom, lessThanOrEqualTo(tester.getRect(trigger).top));
      expect(menuRect.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('arrow Home End Enter Escape and disabled state are controlled', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    int? selected;
    await mount(tester, onChanged: (value) => selected = value);
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    await mount(
      tester,
      enabled: false,
      onChanged: (_) => fail('disabled select changed'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long lists search and outside tap close without committing', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    int? selected;
    await mount(
      tester,
      options: List.generate(30, (i) => (i, 'Token $i')),
      onChanged: (value) => selected = value,
    );
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Token 24');
    await tester.pumpAndSettle();
    expect(find.text('Token 24'), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 24);
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
    expect(selected, 24);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent scroll closes overlay; accordion keeps child draft', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    final pageScroll = ScrollController();
    final text = TextEditingController();
    addTearDown(pageScroll.dispose);
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: pageScroll,
            children: [
              UiSelect<int>(
                options: const [(1, 'One'), (2, 'Two')],
                value: 1,
                onChanged: (_) {},
              ),
              UiAccordion(
                title: 'Socials',
                child: TextField(controller: text),
              ),
              const SizedBox(height: 900),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    pageScroll.jumpTo(10);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ui-select-menu')), findsNothing);
    await tester.tap(find.text('Socials'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.test');
    await tester.tap(find.text('Socials'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Socials'));
    await tester.pumpAndSettle();
    expect(text.text, 'https://example.test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize and long labels keep menu within the small viewport', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await mount(
      tester,
      alignment: Alignment.bottomRight,
      options: List.generate(
        50,
        (i) => (i, 'A very long option label $i for a pool token'),
      ),
      onChanged: (_) {},
    );
    await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(390, 360);
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('ui-select-menu'));
    // MenuAnchor may close during metrics change; reopening uses the new rect.
    if (menu.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('ui-select-trigger')));
      await tester.pumpAndSettle();
    }
    final rect = tester.getRect(menu);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(360));
    expect(rect.height, lessThanOrEqualTo(260));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'contract addresses wrap in the trigger and scrollable keyboard menu',
    (tester) async {
      addTearDown(tester.view.reset);
      final addresses = [
        for (var i = 1; i <= 8; i++)
          '0x${i.toRadixString(16).padLeft(32, '0')}abcd0000',
      ];
      final options = [
        for (final (i, address) in addresses.indexed) (i, 'Pool · $address'),
      ];
      int? selected;
      await mount(
        tester,
        options: options,
        onChanged: (value) => selected = value,
      );
      tester.view.physicalSize = const Size(320, 500);
      await tester.pumpAndSettle();
      final trigger = find.byKey(const ValueKey('ui-select-trigger'));
      final menu = find.byKey(const ValueKey('ui-select-menu'));
      expectFullAddress(tester, addresses.first, within: trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expectFullAddress(tester, addresses.first, within: menu);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expectFullAddress(tester, addresses.last, within: menu);
      final last = find.text(options.last.$2);
      expect(last.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(tester.getRect(menu).bottom),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, options.last.$1);
      expect(menu, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
