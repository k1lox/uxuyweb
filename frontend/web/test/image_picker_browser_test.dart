@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:uxuy_web/image_picker_web.dart';

web.HTMLInputElement get input =>
    web.document.querySelector('input[type="file"]')! as web.HTMLInputElement;

void choose(
  Uint8List bytes, {
  String name = 'test.png',
  String mime = 'image/png',
}) {
  final transfer = web.DataTransfer();
  transfer.items.add(
    web.File([bytes.toJS].toJS, name, web.FilePropertyBag(type: mime)),
  );
  input.files = transfer.files;
  input.dispatchEvent(web.Event('change'));
}

void main() {
  test(
    'cancel resolves, removes DOM input, and the next selection reads bytes',
    () async {
      final picker = BrowserImagePicker();
      addTearDown(picker.dispose);
      final cancelled = picker.pick();
      input.dispatchEvent(web.Event('cancel'));
      expect(await cancelled, isNull);
      expect(web.document.querySelector('input[type="file"]'), isNull);
      final selected = picker.pick();
      choose(Uint8List.fromList([137, 80, 78, 71]));
      final result = await selected;
      expect(result?.bytes, [137, 80, 78, 71]);
      expect(result?.mime, 'image/png');
      expect(result?.filename, 'test.png');
      expect(web.document.querySelector('input[type="file"]'), isNull);
    },
  );

  test(
    'replacement and dispose resolve pending requests without late images',
    () async {
      final picker = BrowserImagePicker();
      final first = picker.pick();
      final next = picker.pick();
      expect(await first, isNull);
      choose(Uint8List(1024));
      picker.dispose();
      expect(await next, isNull);
      expect(await picker.pick(), isNull);
      expect(web.document.querySelector('input[type="file"]'), isNull);
    },
  );

  test(
    'oversize and unsupported files fail before retaining file bytes',
    () async {
      final picker = BrowserImagePicker();
      addTearDown(picker.dispose);
      final tooLarge = expectLater(picker.pick(), throwsFormatException);
      choose(Uint8List(BrowserImagePicker.maxBytes + 1));
      await tooLarge;
      expect(web.document.querySelector('input[type="file"]'), isNull);
      final wrongType = expectLater(picker.pick(), throwsFormatException);
      choose(Uint8List.fromList([1]), name: 'test.txt', mime: 'text/plain');
      await wrongType;
      expect(web.document.querySelector('input[type="file"]'), isNull);
    },
  );

  test('older-browser focus return cancels an empty chooser', () async {
    final picker = BrowserImagePicker();
    addTearDown(picker.dispose);
    final selected = picker.pick();
    web.window.dispatchEvent(web.Event('blur'));
    web.window.dispatchEvent(web.Event('focus'));
    expect(await selected.timeout(const Duration(seconds: 2)), isNull);
    expect(web.document.querySelector('input[type="file"]'), isNull);
  });
}
