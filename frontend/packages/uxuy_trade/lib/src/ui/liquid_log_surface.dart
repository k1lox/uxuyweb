import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Independent Flutter contour, informed by the local liquid-dropdown and
/// gooey-tooltip stage timing and shape-morph's single closed outline approach.
/// No SVG filter, source path sampler, or third-party morph code is included.
class LiquidLogContour {
  LiquidLogContour({
    required Size panelSize,
    required double diameter,
    required double progress,
  }) : progress = progress.clamp(0.0, 1.0) {
    final p = this.progress;
    final width = diameter + (panelSize.width - diameter) * phase(.02, .84, p);
    final height = diameter + (panelSize.height - diameter) * phase(0, .80, p);
    size = Size(width, height);

    // A round bud grows vertically first, then spreads left. Its far corners
    // relax later than the fixed toggle corner, giving it a soft droplet body.
    final round = math.min(width, height) / 2;
    final corner = math.min(8.0, round);
    final topLeft = math.max(0.0, _mix(round, corner, phase(.24, .88, p)) - .5);
    final topRight = math.max(
      0.0,
      _mix(diameter / 2, corner, phase(.36, .88, p)) - .5,
    );
    final bottomRight = math.max(
      0.0,
      _mix(round, corner, phase(.30, .88, p)) - .5,
    );
    final bottomLeft = math.max(
      0.0,
      _mix(round, corner, phase(.44, .88, p)) - .5,
    );
    // Keep the outline convex throughout the transition. Concave shoulders
    // switch CanvasKit path pipelines on the first expansion and add jank.
    final inset = .5;
    final left = inset;
    final top = inset;
    final right = width - inset;
    final bottom = height - inset;
    const k = .5522847498307936;
    path = Path()
      ..moveTo(left + topLeft, top)
      ..cubicTo(
        left + topLeft + (width - 1 - topLeft - topRight) / 3,
        top,
        right - topRight - (width - 1 - topLeft - topRight) / 3,
        top,
        right - topRight,
        top,
      )
      ..cubicTo(
        right - topRight * (1 - k),
        top,
        right,
        top + topRight * (1 - k),
        right,
        top + topRight,
      )
      ..cubicTo(
        right,
        top + topRight + (height - 1 - topRight - bottomRight) / 3,
        right,
        bottom - bottomRight - (height - 1 - topRight - bottomRight) / 3,
        right,
        bottom - bottomRight,
      )
      ..cubicTo(
        right,
        bottom - bottomRight * (1 - k),
        right - bottomRight * (1 - k),
        bottom,
        right - bottomRight,
        bottom,
      )
      ..lineTo(left + bottomLeft, bottom)
      ..cubicTo(
        left + bottomLeft * (1 - k),
        bottom,
        left,
        bottom - bottomLeft * (1 - k),
        left,
        bottom - bottomLeft,
      )
      ..lineTo(left, top + topLeft)
      ..cubicTo(
        left,
        top + topLeft * (1 - k),
        left + topLeft * (1 - k),
        top,
        left + topLeft,
        top,
      )
      ..close();
  }

  final double progress;
  late final Size size;
  late final Path path;
  // Reveal the retained, unscaled content through the growing contour. A broad
  // fade avoids flashing a large empty panel when reversing the animation.
  double get contentOpacity => phase(.35, .92, progress);
  bool get contentReady => progress >= .98;

  static double phase(double start, double end, double value) {
    final t = ((value - start) / (end - start)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _mix(double from, double to, double progress) =>
      from + (to - from) * progress;
}

/// Painting and hit testing share the exact contour. Areas outside the liquid
/// remain transparent to the page beneath, including during an interrupted morph.
class LiquidLogSurface extends StatelessWidget {
  const LiquidLogSurface({
    super.key,
    required this.contour,
    required this.panelSize,
    required this.interactive,
    required this.child,
  });

  final LiquidLogContour contour;
  final Size panelSize;
  final bool interactive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Keep the layout and log text fixed. Only the painted/clipped contour
    // changes, so an animation frame cannot lay out the entire log list again.
    final path = contour.path.shift(
      Offset(panelSize.width - contour.size.width, 0),
    );
    return RepaintBoundary(
      child: CustomPaint(
        painter: _LiquidLogPainter(contour, path),
        child: ClipPath(
          clipper: _LiquidLogClipper(path),
          clipBehavior: Clip.antiAlias,
          child: ExcludeSemantics(
            excluding: !interactive || !contour.contentReady,
            child: ExcludeFocus(
              excluding: !interactive || !contour.contentReady,
              child: IgnorePointer(
                ignoring: !interactive || !contour.contentReady,
                child: Opacity(opacity: contour.contentOpacity, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidLogClipper extends CustomClipper<Path> {
  const _LiquidLogClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_LiquidLogClipper oldClipper) => oldClipper.path != path;
}

class _LiquidLogPainter extends CustomPainter {
  const _LiquidLogPainter(this.contour, this.path);
  final LiquidLogContour contour;
  final Path path;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
      path,
      Paint()
        ..color = UxuyColors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool hitTest(Offset position) => path.contains(position);
  @override
  bool shouldRepaint(_LiquidLogPainter oldDelegate) =>
      oldDelegate.contour != contour;
}
