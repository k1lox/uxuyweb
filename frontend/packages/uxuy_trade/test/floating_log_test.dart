import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/ui/floating_log.dart';
import 'package:uxuy_trade/src/ui/liquid_log_surface.dart';
import 'package:uxuy_trade/src/ui/theme.dart';

Widget _app(
  ExecutionLog log, {
  bool reducedMotion = false,
  Future<void> Function()? onRefresh,
}) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: uxuyTheme(ThemeData.light()),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: Scaffold(
        body: FloatingLog(log: log, onRefresh: onRefresh),
      ),
    ),
  ),
);

void _inside(Rect rect, Size viewport) {
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(viewport.width));
  expect(rect.bottom, lessThanOrEqualTo(viewport.height));
}

LiquidLogSurface _surface(WidgetTester tester) =>
    tester.widget<LiquidLogSurface>(find.byType(LiquidLogSurface));

void _closed(WidgetTester tester) {
  expect(find.byType(LogWindow), findsOneWidget);
  expect(_surface(tester).contour.progress, 0);
  expect(_surface(tester).interactive, isFalse);
  expect(find.text('清空').hitTestable(), findsNothing);
}

void main() {
  testWidgets('history opens as selectable text and a failed read stays in the log panel', (tester) async {
    final log = ExecutionLog()..readHistory = () async => '本地记录 1';
    addTearDown(log.dispose);
    await tester.pumpWidget(_app(log, reducedMotion: true));
    await tester.tap(find.byType(LogBall));
    await tester.pumpAndSettle();
    final historyButton = find.byTooltip('本机历史日志');
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '本地记录 1'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭弹窗'));
    await tester.pumpAndSettle();

    log.readHistory = () async => throw StateError('历史记录读取失败');
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    expect(find.text('历史记录读取失败'), findsOneWidget);
    expect(find.byTooltip('关闭弹窗'), findsNothing);
  });

  testWidgets('manual wallet refresh remains pinned after clearing the log', (
    tester,
  ) async {
    final log = ExecutionLog();
    addTearDown(log.dispose);
    var reads = 0;
    await tester.pumpWidget(
      _app(
        log,
        reducedMotion: true,
        onRefresh: () async {
          reads++;
        },
      ),
    );
    await tester.tap(find.byType(LogBall));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('refresh-wallet-ledger'));
    expect(find.textContaining('钱包在其他地方操作后').hitTestable(), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(log.entries.last.text, '钱包余额与授权已刷新');
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(log.entries, isEmpty);
    expect(button.hitTestable(), findsOneWidget);
  });
  testWidgets('unmoved log stays next to the right edge when the workspace grows', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final log = ExecutionLog();
    addTearDown(log.dispose);
    tester.view.physicalSize = const Size(390, 740);
    await tester.pumpWidget(_app(log));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1440, 740);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(LogBall)).right, closeTo(1420, 1));
  });

  test(
    'collapsed ball uses its own bounds and opening commits a fitted anchor',
    () {
      const viewport = Size(1280, 720);
      for (final anchor in [
        const Offset(-500, -500),
        const Offset(5000, -500),
        const Offset(-500, 5000),
        const Offset(5000, 5000),
      ]) {
        final free = LogGeometry(viewport, anchor, open: false);
        _inside(free.ballPosition & Size.square(free.diameter), viewport);
        final fitted = LogGeometry(viewport, free.anchor, open: true);
        _inside(fitted.panelPosition & fitted.panelSize, viewport);
        expect(fitted.ballPosition.dy, fitted.panelPosition.dy);
        expect(fitted.ballPosition.dx + fitted.diameter, fitted.anchor.dx);
        expect(
          LogGeometry(viewport, fitted.anchor, open: false).ballPosition,
          fitted.ballPosition,
        );
      }
      final bottomLeft = LogGeometry(
        viewport,
        const Offset(0, 5000),
        open: false,
      );
      expect(bottomLeft.ballPosition, const Offset(12, 660));
      expect(bottomLeft.panelPosition.dx, lessThan(0));
    },
  );

  testWidgets(
    'log toggle exposes one short semantic label within its 48px bounds',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final log = ExecutionLog();
      addTearDown(log.dispose);
      await tester.pumpWidget(_app(log, reducedMotion: true));
      final ball = find.byType(LogBall);
      Finder toggleSemantics(String label) => find.descendant(
        of: ball,
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == label,
        ),
      );
      final closedNode = tester.getSemantics(toggleSemantics('打开日志'));
      expect(closedNode.getSemanticsData().label, '打开日志');
      expect(closedNode.rect.size, const Size(48, 48));
      expect(
        closedNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(closedNode.getSemanticsData().flagsCollection.isButton, isTrue);
      final annotation = tester.widget<Semantics>(toggleSemantics('打开日志'));
      expect(annotation.excludeSemantics, isTrue);
      annotation.properties.onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(LogWindow), findsOneWidget);
      final openedNode = tester.getSemantics(toggleSemantics('收起日志'));
      expect(openedNode.getSemanticsData().label, '收起日志');
      expect(openedNode.rect.size, const Size(48, 48));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(1280, 720), const Size(390, 720)]) {
    testWidgets('touch drag reaches four corners and opens safely at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = ExecutionLog();
      addTearDown(log.dispose);
      await tester.pumpWidget(_app(log));
      await tester.pumpAndSettle();
      final ball = find.byType(LogBall);
      for (final delta in [
        const Offset(-2000, -2000),
        const Offset(2000, -2000),
        const Offset(2000, 2000),
        const Offset(-2000, 2000),
      ]) {
        await tester.drag(ball, delta);
        await tester.pumpAndSettle();
        _closed(tester); // Releasing a drag must not toggle the panel.
        final rect = tester.getRect(ball);
        _inside(rect, size);
        expect(rect.left, delta.dx < 0 ? 12 : size.width - 60);
        expect(rect.top, delta.dy < 0 ? 12 : size.height - 60);
      }
      final beforeOpen = tester.getRect(ball);
      await tester.tap(ball);
      await tester.pump();
      // The ball starts correcting its anchor before content expands.
      _closed(tester);
      expect(tester.getRect(ball), beforeOpen);
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(LogWindow));
      final expandedBall = tester.getRect(ball);
      _inside(panel, size);
      expect(expandedBall.right, panel.right);
      expect(expandedBall.top, panel.top);
      await tester.tap(ball);
      await tester.pumpAndSettle();
      expect(tester.getRect(ball), expandedBall);
      _closed(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('open window drags, resizes, follows logs and retains entries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final log = ExecutionLog()..add('第一条记录');
    addTearDown(log.dispose);
    await tester.pumpWidget(_app(log));
    await tester.tap(find.byType(LogBall));
    await tester.pumpAndSettle();
    final toggle = tester.getRect(find.byType(LogBall));
    expect(toggle.top, tester.getRect(find.byType(LogWindow)).top);
    await tester.drag(
      find.byKey(const ValueKey('log-drag-handle')),
      const Offset(-2000, 2000),
    );
    await tester.pumpAndSettle();
    final moved = tester.getRect(find.byType(LogWindow));
    expect(moved.left, 12);
    expect(moved.bottom, 708);
    await tester.drag(find.byType(LogBall), const Offset(2000, -2000));
    await tester.pumpAndSettle();
    final byBall = tester.getRect(find.byType(LogWindow));
    expect(byBall.right, 1268);
    expect(byBall.top, 12);
    log.add('刚刚追加的记录');
    await tester.pumpAndSettle();
    expect(find.textContaining('刚刚追加的记录'), findsOneWidget);

    tester.view.physicalSize = const Size(320, 480);
    await tester.pumpAndSettle();
    _inside(tester.getRect(find.byType(LogWindow)), const Size(320, 480));
    _inside(tester.getRect(find.byType(LogBall)), const Size(320, 480));
    await tester.tap(find.byType(LogBall));
    await tester.pumpAndSettle();
    log.add('收起期间的记录');
    await tester.tap(find.byType(LogBall));
    await tester.pumpAndSettle();
    expect(find.textContaining('收起期间的记录'), findsOneWidget);
    expect(log.entries.length, 3);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(log.entries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final closing in [false, true]) {
    testWidgets(
      'dragging during ${closing ? 'closing' : 'opening'} keeps the current shape',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final log = ExecutionLog();
        addTearDown(log.dispose);
        await tester.pumpWidget(_app(log));
        final ball = find.byType(LogBall);
        final content = tester.element(find.byType(LogWindow));
        if (closing) {
          await tester.tap(ball);
          await tester.pumpAndSettle();
        }
        await tester.tap(ball);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final beforeDrag = _surface(tester).contour.progress;
        expect(beforeDrag, inExclusiveRange(0, 1));
        final gesture = await tester.startGesture(tester.getCenter(ball));
        await gesture.moveBy(const Offset(-40, 40));
        await tester.pump();
        expect(
          _surface(tester).contour.progress,
          closeTo(beforeDrag, .00001),
          reason: 'drag recognition must not snap an in-flight morph to an endpoint',
        );
        await gesture.moveBy(const Offset(-20, 20));
        await tester.pump();
        expect(_surface(tester).contour.progress, closeTo(beforeDrag, .00001));
        expect(tester.element(find.byType(LogWindow)), same(content));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(_surface(tester).contour.progress, closing ? 0 : 1);
        if (closing) {
          _closed(tester);
          await tester.drag(ball, const Offset(-2000, 2000));
          await tester.pumpAndSettle();
          expect(tester.getRect(ball).topLeft, const Offset(12, 660));
        } else {
          _inside(
            tester.getRect(find.byType(LogWindow)),
            const Size(1280, 720),
          );
        }
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'closing and reopening retain log state without active hidden controls',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final log = ExecutionLog()..add('保留的记录');
      addTearDown(log.dispose);
      await tester.pumpWidget(_app(log));
      final content = tester.element(find.byType(LogWindow));
      final surface = tester.element(find.byType(LiquidLogSurface));
      final initialRect = tester.getRect(find.byType(LogWindow));
      expect(initialRect.size, const Size(560, 380));
      _closed(tester);
      expect(find.semantics.byLabel('日志面板').evaluate(), isEmpty);
      final ball = find.byType(LogBall);
      await tester.tap(ball);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      await tester.tap(ball);
      await tester.pumpAndSettle();
      _closed(tester);
      expect(find.semantics.byLabel('日志面板').evaluate(), isEmpty);
      expect(tester.element(find.byType(LogWindow)), same(content));
      expect(tester.element(find.byType(LiquidLogSurface)), same(surface));
      expect(tester.getRect(find.byType(LogWindow)), initialRect);
      log.add('收起后继续写入');
      await tester.pump();
      await tester.tap(ball);
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(LogWindow)), same(content));
      expect(tester.getRect(find.byType(LogWindow)), initialRect);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.textContaining('收起后继续写入'), findsOneWidget);
      expect(find.text('清空').hitTestable(), findsOneWidget);
      expect(find.semantics.byLabel('日志面板').evaluate(), hasLength(1));
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced motion opens immediately and keyboard can move and close',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = ExecutionLog();
      addTearDown(log.dispose);
      await tester.pumpWidget(_app(log, reducedMotion: true));
      final ball = find.byType(LogBall);
      await tester.drag(ball, const Offset(-2000, 2000));
      await tester.tap(ball);
      await tester.pump();
      expect(find.byType(LogWindow), findsOneWidget);
      _inside(tester.getRect(find.byType(LogWindow)), const Size(1280, 720));
      final ink = tester.widget<InkWell>(
        find.descendant(of: ball, matching: find.byType(InkWell)),
      );
      ink.focusNode!.requestFocus();
      await tester.pump();
      final before = tester.getRect(ball);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(tester.getRect(ball).left, before.left + 16);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      _closed(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
