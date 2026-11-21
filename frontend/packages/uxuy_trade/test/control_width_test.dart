import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';

void main() {
  testWidgets(
    'short controls remain content-sized inside a wide stretched form',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UiSelect<int>(
                    options: const [(0, 'BNB'), (1, 'BNCB')],
                    value: 0,
                    onChanged: (_) {},
                  ),
                  OptionPair<bool>(
                    options: const [(false, '普通币'), (true, '税币')],
                    value: false,
                    onChanged: (_) {},
                  ),
                  SmallButton(label: '读取配置', onPressed: () {}),
                  PrimaryButton(label: '准备发币', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      final trigger = find.byKey(const ValueKey('ui-select-trigger'));
      expect(tester.getSize(trigger).width, inInclusiveRange(100, 180));
      for (final text in ['普通币', '税币', '读取配置']) {
        final button = find.ancestor(
          of: find.text(text),
          matching: find.byType(TextButton),
        );
        expect(tester.getSize(button).width, lessThan(160));
      }
      expect(
        tester.getSize(find.byType(FilledButton)).width,
        inInclusiveRange(100, 220),
      );
      await tester.tap(trigger);
      await tester.pump();
      expect(find.text('BNCB').hitTestable(), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('ui-select-menu'))).width,
        lessThan(200),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact choices wrap and long selectors stay bounded with larger text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UiSelect<int>(
                        options: const [
                          (0, 'A considerably longer token option'),
                          (1, 'BNB'),
                        ],
                        value: 0,
                        onChanged: (_) {},
                      ),
                      OptionPair<int>(
                        options: const [(0, '按固定金额分发'), (1, '按钱包比例分发')],
                        value: 0,
                        onChanged: (_) {},
                      ),
                      PrimaryButton(label: '准备执行', onPressed: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final trigger = find.byKey(const ValueKey('ui-select-trigger'));
      expect(tester.getSize(trigger).width, lessThanOrEqualTo(288));
      final first = tester.getRect(find.text('按固定金额分发'));
      final second = tester.getRect(find.text('按钱包比例分发'));
      expect(second.top, greaterThan(first.bottom));
      await tester.tap(trigger);
      await tester.pump();
      final menu = tester.getRect(find.byKey(const ValueKey('ui-select-menu')));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}
