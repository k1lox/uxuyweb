import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/clipboard_feedback.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/ui/tools_page.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/uxuy_trade.dart';

import 'support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('cancel and rejected clipboard keep generated wallets unbacked; retry marks only after success', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeBackend();
    final client = fake.client();
    final state = AppState(BackendClient(Uri.parse('http://fixture.test/'), client), MemoryKeyStore());
    final wallet = (await state.generate(1)).single;
    addTearDown(() { state.dispose(); client.close(); });
    var attempts = 0;
    var reject = true;
    final write = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        attempts++;
        if (reject) throw PlatformException(code: 'NotAllowedError');
        await write.future;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: uxuyTheme(ThemeData()),
      home: Scaffold(body: ListenableBuilder(listenable: state, builder: (_, _) => ToolsPage(state: state))),
    ));
    await tester.pumpAndSettle();
    final copy = find.widgetWithText(SmallButton, '复制所选私钥');
    // Two immediate actions must not stack confirmation dialogs.
    final action = tester.widget<SmallButton>(copy).onPressed!;
    action();
    action();
    await tester.pumpAndSettle();
    expect(find.text('导出私钥'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(attempts, 0);
    expect(wallet.backedUp, isFalse);
    expect(wallet.canReceiveFunds, isFalse);

    await tester.tap(copy);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(wallet.backedUp, isFalse);
    expect(find.text('复制失败，请重试或手动选择文本。'), findsOneWidget);
    expect(find.text('已复制，请妥善保存私钥'), findsNothing);

    reject = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(wallet.backedUp, isFalse);
    expect(find.text('已复制，请妥善保存私钥'), findsNothing);
    // Pending writes cannot open another dialog or produce a second write.
    tester.widget<SmallButton>(copy).onPressed!();
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('导出私钥'), findsNothing);
    write.complete();
    await tester.pumpAndSettle();
    expect(wallet.backedUp, isTrue);
    expect(wallet.canReceiveFunds, isTrue);
    expect(find.text('已复制，请妥善保存私钥'), findsOneWidget);
    expect(fake.submitted, isEmpty);
    expect(fake.bundles, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CA writes await completion, reject repeat click, and ignore disposed UI', (tester) async {
    late BuildContext target;
    var writes = 0;
    final pending = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        writes++;
        await pending.future;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      target = context;
      return const Text('Fixture');
    }))));
    final operation = ClipboardFeedback.copy(target, 'fixture-ca', successLabel: 'Copied');
    await ClipboardFeedback.copy(target, 'duplicate-ca', successLabel: 'Copied');
    await tester.pump();
    expect(writes, 1);
    expect(find.text('Copied'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await operation;
    await tester.pump();
    expect(find.text('Copied'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
