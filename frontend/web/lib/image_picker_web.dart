import 'dart:async';
import 'dart:js_interop';

import 'package:uxuy_trade/uxuy_trade.dart';
import 'package:web/web.dart' as web;

/// Browser-owned chooser. Only the current file's bytes are kept in memory.
/// Closing the app or opening a replacement chooser resolves the old one with null.
class BrowserImagePicker {
  static const maxBytes = 10_000_000; // Four / Flap limit; Genius checks its own 2 MiB limit on upload.
  static const _types = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
  bool _disposed = false;
  void Function()? _cancelPending;

  Future<LaunchImage?> pick() {
    if (_disposed) return Future.value(null);
    _cancelPending?.call();
    final done = Completer<LaunchImage?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = _types.join(',')
      ..setAttribute('hidden', '');
    web.FileReader? reader;
    Timer? focusTimer;
    Timer? readTimer;
    var reading = false;
    var lostFocus = false;
    late final JSFunction onChange;
    late final JSFunction onCancel;
    late final JSFunction onBlur;
    late final JSFunction onFocus;

    void finish({LaunchImage? image, Object? error}) {
      if (done.isCompleted) return;
      focusTimer?.cancel();
      readTimer?.cancel();
      input.removeEventListener('change', onChange);
      input.removeEventListener('cancel', onCancel);
      web.window.removeEventListener('blur', onBlur);
      web.window.removeEventListener('focus', onFocus);
      final activeReader = reader;
      if (activeReader != null) {
        activeReader.onload = null;
        activeReader.onerror = null;
        activeReader.onabort = null;
        if (activeReader.readyState == web.FileReader.LOADING) {
          activeReader.abort();
        }
      }
      input.remove();
      _cancelPending = null;
      if (error != null && !_disposed) {
        done.completeError(error);
      } else {
        done.complete(_disposed ? null : image);
      }
    }

    onChange = ((web.Event _) {
      if (done.isCompleted || reading) return;
      final file = input.files?.item(0);
      if (file == null) {
        finish();
        return;
      }
      if (file.size <= 0 || file.size > maxBytes) {
        finish(error: const FormatException('请选择不超过 10 MB 的图片'));
        return;
      }
      final mime = file.type.isNotEmpty
          ? file.type.toLowerCase()
          : switch (file.name.split('.').last.toLowerCase()) {
              'png' => 'image/png',
              'jpg' || 'jpeg' => 'image/jpeg',
              'webp' => 'image/webp',
              'gif' => 'image/gif',
              _ => '',
            };
      if (!_types.contains(mime)) {
        finish(error: const FormatException('请选择 PNG、JPEG、WebP 或 GIF 图片'));
        return;
      }
      reading = true;
      focusTimer?.cancel();
      final activeReader = reader = web.FileReader();
      activeReader.onload = ((web.Event _) {
        if (done.isCompleted) return;
        try {
          final bytes = (activeReader.result as JSArrayBuffer).toDart
              .asUint8List();
          finish(image: LaunchImage(bytes, file.name, mime));
        } on Object {
          finish(error: const FormatException('图片读取失败，请重新选择'));
        }
      }).toJS;
      activeReader.onerror = ((web.Event _) {
        finish(error: const FormatException('图片读取失败，请重新选择'));
      }).toJS;
      activeReader.onabort = ((web.Event _) => finish()).toJS;
      readTimer = Timer(const Duration(seconds: 30), () {
        finish(error: const FormatException('图片读取超时，请重新选择'));
      });
      try {
        activeReader.readAsArrayBuffer(file);
      } on Object {
        finish(error: const FormatException('图片读取失败，请重新选择'));
      }
    }).toJS;
    onCancel = ((web.Event _) {
      if (!reading) finish();
    }).toJS;
    onBlur = ((web.Event _) => lostFocus = true).toJS;
    onFocus = ((web.Event _) {
      // Older browsers may omit "cancel". Wait for their change event after the
      // native chooser returns; never cancel an in-progress FileReader.
      if (!lostFocus || reading) return;
      focusTimer?.cancel();
      focusTimer = Timer(const Duration(milliseconds: 600), () {
        if (!reading && (input.files?.length ?? 0) == 0) finish();
      });
    }).toJS;
    input.addEventListener('change', onChange);
    input.addEventListener('cancel', onCancel);
    web.window.addEventListener('blur', onBlur);
    web.window.addEventListener('focus', onFocus);
    _cancelPending = () => finish();
    web.document.body?.append(input);
    try {
      input.click();
    } on Object {
      finish(error: const FormatException('无法打开文件选择器，请重试'));
    }
    return done.future;
  }

  void dispose() {
    _disposed = true;
    _cancelPending?.call();
  }
}
