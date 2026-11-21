import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Check the painted first and last characters. Merely finding the address
/// string would also match a paragraph truncated with an ellipsis.
void expectFullAddress(WidgetTester tester, String address, {Finder? within}) {
  final matches = find.textContaining(address, findRichText: true);
  final finder = within == null
      ? matches
      : find.descendant(of: within, matching: matches);
  expect(finder, findsOneWidget);

  final widget = tester.widget(finder);
  final RenderBox box;
  final List<TextBox> Function(TextSelection) boxes;
  final String text;
  if (widget is EditableText) {
    final render = tester.state<EditableTextState>(finder).renderEditable;
    box = render;
    boxes = render.getBoxesForSelection;
    text = widget.controller.text;
  } else {
    final render = tester.renderObject<RenderParagraph>(finder);
    box = render;
    boxes = render.getBoxesForSelection;
    text = render.text.toPlainText();
  }
  final start = text.indexOf(address);
  final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (final index in [start, start + address.length - 1]) {
    final glyph = boxes(
      TextSelection(baseOffset: index, extentOffset: index + 1),
    );
    expect(
      glyph,
      isNotEmpty,
      reason: 'Character ${index - start + 1} was truncated',
    );
    final rect = glyph.first.toRect();
    expect(rect.left, greaterThanOrEqualTo(-0.5));
    expect(rect.right, lessThanOrEqualTo(box.size.width + 0.5));
    expect(rect.top, greaterThanOrEqualTo(-0.5));
    expect(rect.bottom, lessThanOrEqualTo(box.size.height + 0.5));
    expect(box.localToGlobal(rect.topLeft).dx, greaterThanOrEqualTo(-0.5));
    expect(
      box.localToGlobal(rect.topRight).dx,
      lessThanOrEqualTo(screen + 0.5),
    );
  }
}
