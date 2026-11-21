import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/ui/floating_log.dart';
import 'package:uxuy_trade/src/ui/liquid_log_surface.dart';
import 'package:uxuy_trade/src/ui/theme.dart';

void main() {
  test('liquid outline remains one closed curve and grows independently on each axis', () {
    const panel = Size(560, 380);
    final closed = LiquidLogContour(
      panelSize: panel,
      diameter: 48,
      progress: 0,
    );
    expect(closed.size, const Size.square(48));
    final circleMetric = closed.path.computeMetrics().single;
    for (var i = 0; i < 16; i++) {
      final point = circleMetric
          .getTangentForOffset(circleMetric.length * i / 16)!
          .position;
      expect((point - const Offset(24, 24)).distance, closeTo(23.5, .1));
    }
    final expanded = LiquidLogContour(
      panelSize: panel,
      diameter: 48,
      progress: 1,
    );
    expect(expanded.size, panel);
    for (var i = 0; i <= 100; i++) {
      final shape = LiquidLogContour(
        panelSize: panel,
        diameter: 48,
        progress: i / 100,
      );
      final contours = shape.path.computeMetrics().toList();
      expect(contours.length, 1);
      expect(contours.single.isClosed, isTrue);
      expect(shape.path.getBounds().left, greaterThanOrEqualTo(0));
      expect(shape.path.getBounds().top, greaterThanOrEqualTo(0));
      expect(shape.path.getBounds().right, lessThanOrEqualTo(shape.size.width));
      expect(
        shape.path.getBounds().bottom,
        lessThanOrEqualTo(shape.size.height),
      );
      expect(shape.path.contains(Offset(shape.size.width - 24, 24)), isTrue);
    }
    final bud = LiquidLogContour(panelSize: panel, diameter: 48, progress: .3);
    final widthGrowth = (bud.size.width - 48) / (panel.width - 48);
    final heightGrowth = (bud.size.height - 48) / (panel.height - 48);
    expect(
      heightGrowth,
      greaterThan(widthGrowth + .02),
      reason: 'a round bud grows down before it spreads left, not a scaled rectangle',
    );
    expect(bud.contentOpacity, 0);
    expect(expanded.contentOpacity, 1);
    expect(bud.path.contains(const Offset(1, 1)), isFalse);
  });

  test(
    'content reveals gradually instead of flashing only in the last frames',
    () {
      for (final width in [560.0, 366.0, 296.0]) {
        final panel = Size(width, 380);
        final values = List.generate(
          101,
          (i) => LiquidLogContour(
            panelSize: panel,
            diameter: 48,
            progress: i / 100,
          ).contentOpacity,
        );
        expect(values.first, 0);
        expect(values.last, 1);
        expect(
          values.where((value) => value > 0 && value < 1).length,
          greaterThanOrEqualTo(30),
          reason: 'content should fade across a substantial part of the morph',
        );
        for (var i = 1; i < values.length; i++) {
          expect(values[i], greaterThanOrEqualTo(values[i - 1]));
          expect(
            values[i] - values[i - 1],
            lessThan(.06),
            reason: 'adjacent frames cannot abruptly change content contrast',
          );
        }
      }
    },
  );

  testWidgets(
    'transparent corners pass clicks through while the liquid is forming',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var pageClicks = 0;
      final contour = LiquidLogContour(
        panelSize: const Size(560, 380),
        diameter: 48,
        progress: .4,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => pageClicks++,
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
                Positioned(
                  left: 50,
                  top: 50,
                  width: 560,
                  height: 380,
                  child: LiquidLogSurface(
                    contour: contour,
                    panelSize: const Size(560, 380),
                    interactive: true,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tapAt(const Offset(51, 51));
      expect(
        pageClicks,
        1,
        reason:
            'the transparent part of the bounding box cannot block the page',
      );
      await tester.tapAt(const Offset(65, 150));
      expect(
        pageClicks,
        2,
        reason: 'unused space inside the fixed panel bounds also passes clicks',
      );
      await tester.tapAt(
        Offset(50 + 560 - contour.size.width / 2, 50 + contour.size.height / 2),
      );
      expect(
        pageClicks,
        2,
        reason:
            'the right-aligned painted surface owns only its visible region',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the visible expansion takes several frames without rebuilding the log window',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = ExecutionLog()..add('已有日志');
      addTearDown(log.dispose);
      final oldRebuildCallback = debugOnRebuildDirtyWidget;
      final builds = <Element, int>{};
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        oldRebuildCallback?.call(element, builtOnce);
        if (element.widget is LogWindow) {
          builds.update(element, (count) => count + 1, ifAbsent: () => 1);
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = oldRebuildCallback);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: uxuyTheme(ThemeData.light()),
          home: Scaffold(body: FloatingLog(log: log)),
        ),
      );
      await tester.tap(find.byType(LogBall));
      await tester.pump();
      final logElement = tester.element(find.byType(LogWindow));
      final initialBuilds = builds[logElement]!;
      expect(initialBuilds, greaterThanOrEqualTo(1));
      final initialLayout = tester.getRect(find.byType(LogWindow));
      expect(initialLayout.size, const Size(560, 380));
      LiquidLogContour contour() => tester
          .widget<LiquidLogSurface>(find.byType(LiquidLogSurface))
          .contour;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.element(find.byType(LogWindow)), same(logElement));
        expect(tester.getRect(find.byType(LogWindow)), initialLayout);
        expect(
          tester.getSize(find.byType(LiquidLogSurface)),
          initialLayout.size,
        );
      }
      final at100 = contour().size;
      expect(at100.width, inExclusiveRange(80, 300));
      expect(at100.height, inExclusiveRange(70, 240));
      expect(contour().contentOpacity, 0);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final at200 = contour().size;
      expect(at200.width, greaterThan(at100.width + 100));
      expect(
        at200.width,
        lessThan(530),
        reason: 'the panel cannot already be full after 200ms',
      );
      expect(at200.height, greaterThan(at100.height + 60));
      expect(at200.height, lessThan(370));
      expect(contour().contentOpacity, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(contour().contentOpacity, greaterThan(0));
      expect(contour().contentOpacity, lessThan(1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(contour().size, const Size(560, 380));
      expect(contour().contentOpacity, 1);
      expect(tester.getRect(find.byType(LogWindow)), initialLayout);
      expect(
        builds.length,
        1,
        reason: 'the same window Element survives every frame',
      );
      expect(
        builds[logElement],
        initialBuilds,
        reason:
            'animation paints its contour without rebuilding the log subtree',
      );
      // Caching the window must still allow its original log subscription to update.
      log.add('动画结束后追加');
      await tester.pump();
      expect(find.textContaining('动画结束后追加'), findsOneWidget);
      expect(builds[logElement], initialBuilds);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rapid reversals retain the current contour, keep text unscaled and stop at rest',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = ExecutionLog();
      addTearDown(log.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: uxuyTheme(ThemeData.light()),
          home: Scaffold(body: FloatingLog(log: log)),
        ),
      );
      final ball = find.byType(LogBall);
      final center = tester.getCenter(ball);
      final initialSurface = tester.element(find.byType(LiquidLogSurface));
      final initialContent = tester.element(find.byType(LogWindow));
      expect(
        tester.getSize(find.byType(LiquidLogSurface)),
        const Size(560, 380),
      );
      expect(find.byType(LogWindow), findsOneWidget);
      await tester.tap(ball);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      LiquidLogSurface surface() =>
          tester.widget<LiquidLogSurface>(find.byType(LiquidLogSurface));
      final first = surface().contour;
      expect(first.progress, greaterThan(0));
      expect(first.progress, lessThan(1));
      expect(tester.getSize(find.byType(LogWindow)), const Size(560, 380));
      expect(
        find.descendant(
          of: find.byType(LogWindow),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      await tester.tap(ball);
      await tester.pump();
      expect(surface().contour.progress, closeTo(first.progress, .00001));
      expect(surface().contour.size, first.size);
      await tester.pump(const Duration(milliseconds: 40));
      final beforeReopen = surface().contour.progress;
      await tester.tap(ball);
      await tester.pump();
      expect(surface().contour.progress, closeTo(beforeReopen, .00001));
      await tester.pumpAndSettle();
      expect(surface().contour.size, const Size(560, 380));
      expect(surface().contour.contentReady, isTrue);
      expect(tester.getCenter(ball), center);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.tap(ball);
      await tester.pumpAndSettle();
      expect(find.byType(LiquidLogSurface), findsOneWidget);
      expect(
        tester.element(find.byType(LiquidLogSurface)),
        same(initialSurface),
      );
      expect(surface().contour.size, const Size.square(48));
      expect(surface().contour.progress, 0);
      expect(
        tester.getSize(find.byType(LiquidLogSurface)),
        const Size(560, 380),
      );
      expect(find.byType(LogWindow), findsOneWidget);
      expect(tester.element(find.byType(LogWindow)), same(initialContent));
      expect(tester.getCenter(ball), center);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
