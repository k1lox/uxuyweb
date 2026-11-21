import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests have no real OS clipboard. Successful export scenarios must
/// acknowledge the platform write explicitly instead of relying on a backup
/// flag being set before the write completes. Rejection tests use their own mock.
class ClipboardFixture {
  final writes = <String>[];

  void install() {
    writes.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            writes.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }
}
