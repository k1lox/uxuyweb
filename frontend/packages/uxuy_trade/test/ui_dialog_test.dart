import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/dialogs.dart';
import 'package:uxuy_trade/src/ui/key_editor.dart';
import 'package:uxuy_trade/src/ui/theme.dart';

Widget _app(WidgetBuilder builder) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData.light()),
  home: Builder(builder: (context) => Scaffold(body: builder(context))),
);

Finder _surface(Finder child) =>
    find.ancestor(of: child, matching: find.byType(Material)).first;

void main() {
  for (final width in [1280.0, 320.0]) {
    testWidgets(
      'notice stays compact and replacement owns its timeout at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late BuildContext context;
        await tester.pumpWidget(
          _app((c) {
            context = c;
            return const SizedBox.expand();
          }),
        );
        UiNotice.show(context, '第一条提示');
        await tester.pumpAndSettle();
        final noticeRect = tester.getRect(_surface(find.text('第一条提示')));
        expect(noticeRect.width, lessThanOrEqualTo(420));
        expect(noticeRect.width, lessThanOrEqualTo(width - 32));
        expect(noticeRect.center.dx, closeTo(width / 2, 1));
        expect(noticeRect.top, 16);
        expect(find.byType(SnackBar), findsNothing);
        await tester.pump(const Duration(seconds: 1));
        UiNotice.show(context, '新的错误提示', error: true);
        await tester.pumpAndSettle();
        expect(find.text('第一条提示'), findsNothing);
        expect(find.text('新的错误提示'), findsOneWidget);
        expect(
          find.byTooltip('关闭提示'),
          findsOneWidget,
          reason: 'notices replace one another instead of stacking',
        );
        // Cross the old notice's deadline. Its disposed timer must not close the replacement.
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('新的错误提示'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('新的错误提示'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'unmount cancels the notice timer and a new overlay can show notices',
    (tester) async {
      late BuildContext context;
      Widget application() => _app((c) {
        context = c;
        return const SizedBox.expand();
      });
      await tester.pumpWidget(application());
      UiNotice.show(context, '卸载前提示', error: true);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      // The test framework also fails on any pending Timer at test completion.
      // Remounting exercises the static overlay entry after its old overlay is gone.
      await tester.pumpWidget(application());
      UiNotice.show(context, '新页面提示');
      await tester.pumpAndSettle();
      expect(find.text('卸载前提示'), findsNothing);
      expect(find.text('新页面提示'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(1280, 720), const Size(320, 568)]) {
    testWidgets(
      'long dialog keeps header and actions fixed and restores focus at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final openerFocus = FocusNode();
        addTearDown(openerFocus.dispose);
        final field = TextEditingController();
        var returned = false;
        await tester.pumpWidget(
          _app(
            (context) => Center(
              child: TextButton(
                focusNode: openerFocus,
                onPressed: () async {
                  await showUiDialog<void>(
                    context: context,
                    builder: (dialogContext) => UiDialog(
                      title: const Text('长内容弹窗'),
                      content: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(controller: field, autofocus: true),
                          for (var i = 0; i < 40; i++)
                            SizedBox(height: 36, child: Text('内容行 $i')),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).maybePop(),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  );
                  // The public Future must outlive the exit transition so callers can
                  // safely dispose their controllers as soon as it returns.
                  field.dispose();
                  returned = true;
                },
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        );
        openerFocus.requestFocus();
        await tester.pump();
        await tester.tap(find.text('打开弹窗'));
        await tester.pumpAndSettle();
        final header = tester.getRect(find.text('长内容弹窗'));
        final footer = tester.getRect(find.widgetWithText(TextButton, '完成'));
        final surface = tester.getRect(_surface(find.text('长内容弹窗')));
        expect(surface.left, greaterThanOrEqualTo(16));
        expect(surface.right, lessThanOrEqualTo(size.width - 16));
        expect(surface.top, greaterThanOrEqualTo(24));
        expect(surface.bottom, lessThanOrEqualTo(size.height - 24));
        final scroll = find.descendant(
          of: find.byType(UiDialog),
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(scroll, const Offset(0, -600));
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
        );
        expect(scrollable.position.pixels, greaterThan(0));
        expect(tester.getRect(find.text('长内容弹窗')), header);
        expect(tester.getRect(find.widgetWithText(TextButton, '完成')), footer);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(
          returned,
          isFalse,
          reason: 'exit animation still owns the content',
        );
        await tester.pumpAndSettle();
        expect(find.byType(UiDialog), findsNothing);
        expect(returned, isTrue);
        expect(openerFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'key editor retains failed input and blocks cancellation or repeated save while busy',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pending = Completer<void>();
      final submitted = <String>[];
      String? saved;
      // Synthetic text only. This fixture does not create wallets or contact a backend.
      const draft = 'synthetic-line-one\nsynthetic-line-two';
      await tester.pumpWidget(
        _app(
          (context) => Center(
            child: TextButton(
              onPressed: () async {
                saved = await Navigator.of(context).push<String>(
                  KeyEditorRoute<String>(
                    context: context,
                    builder: (_) => KeyEditorPage(
                      title: '编辑测试内容',
                      onSave: (value) async {
                        submitted.add(value);
                        if (submitted.length == 1)
                          throw const FormatException('格式需要修正');
                        await pending.future;
                      },
                    ),
                  ),
                );
              },
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开编辑器'));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(KeyEditorPage),
        matching: find.byType(TextField),
      );
      await tester.tap(input);
      await tester.pump();
      // Web creates a textarea only when the editing client requests multiline.
      final config = tester.testTextInput.setClientArgs!;
      expect(config['inputType']['name'], 'TextInputType.multiline');
      expect(config['inputAction'], 'TextInputAction.newline');
      expect(config['autocorrect'], isFalse);
      expect(config['enableIMEPersonalizedLearning'], isFalse);
      await tester.enterText(input, 'synthetic-line-one');
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      expect(submitted, isEmpty);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.enterText(input, draft);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('格式需要修正'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, draft);
      expect(find.byType(SnackBar), findsNothing);
      final corrected = '$draft\nsynthetic-line-three';
      await tester.enterText(input, corrected);
      await tester.pump();
      expect(find.text('格式需要修正'), findsNothing);
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(submitted, [draft, corrected]);
      expect(tester.widget<TextField>(input).readOnly, isTrue);
      expect(tester.widget<UiDialog>(find.byType(UiDialog)).canClose, isFalse);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed,
        isNull,
      );
      // Try the save shortcut again while its first request is unresolved.
      await tester.tap(input);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(KeyEditorPage), findsOneWidget);
      expect(submitted, [draft, corrected]);
      expect(saved, isNull);
      pending.complete();
      await tester.pumpAndSettle();
      expect(saved, corrected);
      expect(find.byType(KeyEditorPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
