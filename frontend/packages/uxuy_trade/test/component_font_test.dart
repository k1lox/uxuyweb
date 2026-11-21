import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';

void main() {
  for (final family in ['UXUYSans', 'HostFixtureSans']) {
    testWidgets(
      'component buttons, dialog and tooltip retain $family and its fallback',
      (tester) async {
        final theme = componentTheme(
          uxuyTheme(
            ThemeData(
              useMaterial3: true,
              fontFamily: family,
              fontFamilyFallback: const ['FixtureFallback'],
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    FilledButton(onPressed: () {}, child: const Text('全局主按钮')),
                    TextButton(onPressed: () {}, child: const Text('全局次按钮')),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('全局边框按钮'),
                    ),
                    const Text('0x0123456789', style: mono),
                    SmallButton(label: '紧凑按钮', onPressed: () {}),
                    PrimaryButton(label: '页面主按钮', onPressed: () {}),
                    OptionPair<int>(
                      options: const [(0, '选项一'), (1, '选项二')],
                      value: 0,
                      onChanged: (_) {},
                    ),
                    SubTabs<int>(
                      options: const [(0, '页签一'), (1, '页签二')],
                      value: 0,
                      onChanged: (_) {},
                    ),
                    Tooltip(
                      key: const ValueKey('font-tooltip'),
                      message: '本地字体提示',
                      child: const Icon(Icons.info_outline),
                    ),
                    TextButton(
                      onPressed: () => showUiDialog<void>(
                        context: context,
                        builder: (c) => UiDialog(
                          title: const Text('确认标题'),
                          content: const Text('确认内容'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('确认操作'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('打开确认'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        void expectFont(String text) {
          final rich = find.byWidgetPredicate(
            (widget) => widget is RichText && widget.text.toPlainText() == text,
          );
          expect(rich, findsOneWidget, reason: text);
          final style = tester.widget<RichText>(rich).text.style!;
          expect(
            style.fontFamily,
            family,
            reason: '$text must retain the loaded local/host font',
          );
          expect(
            style.fontFamilyFallback,
            contains('FixtureFallback'),
            reason: text,
          );
        }

        for (final text in [
          '全局主按钮',
          '全局次按钮',
          '全局边框按钮',
          '0x0123456789',
          '紧凑按钮',
          '页面主按钮',
          '选项一',
          '选项二',
          '页签一',
          '页签二',
        ]) {
          expectFont(text);
        }
        await tester.tap(find.text('打开确认'));
        await tester.pumpAndSettle();
        expectFont('确认标题');
        expectFont('确认内容');
        expectFont('确认操作');
        await tester.tap(find.text('确认操作'));
        await tester.pumpAndSettle();

        tester
            .state<TooltipState>(find.byKey(const ValueKey('font-tooltip')))
            .ensureTooltipVisible();
        await tester.pumpAndSettle();
        expectFont('本地字体提示');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
