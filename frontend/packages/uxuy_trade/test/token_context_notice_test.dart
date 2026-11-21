import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/shell.dart';
import 'package:uxuy_trade/src/ui/widgets.dart';
import 'package:uxuy_trade/src/ui/theme.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

const oldAddress = '0x0000000000000000000000000000000000000001';
const newAddress = '0x0000000000000000000000000000000000000002';

/// Presentation-only states; no backend, signing or broadcast is reachable.
class NoticeState extends AppState {
  NoticeState(http.Client client)
    : super(
        BackendClient(Uri.parse('http://fixture.invalid/'), client),
        MemoryKeyStore(),
      ) {
    token = const TokenMeta(oldAddress, 'Old token', 'OLD', 18);
  }

  String? reason;
  final launches = <PendingLaunchToken>[];
  final adopted = <String>[];

  @override
  String? get tokenLockReason => reason;
  @override
  List<PendingLaunchToken> get pendingLaunchTokens =>
      List.unmodifiable(launches);

  void changeLock(String? value) {
    reason = value;
    notifyListeners();
  }

  @override
  Future<void> adoptLaunchToken(String address) async {
    if (reason != null) throw StateError(reason!);
    adopted.add(address);
    token = TokenMeta(address, 'New token', 'NEW', 18);
    launches.removeWhere((p) => p.address == address);
    notifyListeners();
  }
}

Widget app(NoticeState state) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: componentTheme(uxuyTheme(ThemeData.light())),
  home: Scaffold(
    body: Column(
      children: [
        TokenContextNotice(state: state),
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openTokenEditor(context, state),
            child: const Text('编辑当前代币'),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  late http.Client client;
  late NoticeState state;
  setUp(() {
    client = MockClient(
      (request) async => throw StateError('Unexpected request'),
    );
    state = NoticeState(client);
  });
  tearDown(() {
    state.dispose();
    client.close();
  });

  testWidgets(
    'locked edit opens a clear reason and pinned identity without address input',
    (tester) async {
      state.reason = '组 01 有交易待确认，请先查询原交易。';
      await tester.pumpWidget(app(state));
      await tester.tap(find.text('编辑当前代币'));
      await tester.pumpAndSettle();
      expect(find.text('当前代币已锁定'), findsOneWidget);
      expect(find.text('BSC · OLD'), findsOneWidget);
      expect(find.text(oldAddress), findsOneWidget);
      expect(find.text(state.reason!), findsNWidgets(2));
      expect(find.byKey(const ValueKey('token-address-input')), findsNothing);
      expect(find.text('知道了'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only a resolved switch notice can be dismissed and new tokens are announced', (tester) async {
    state.tokenNotice = '当前代币已切换';
    await tester.pumpWidget(app(state));
    await tester.tap(find.byTooltip('收起代币提示'));
    await tester.pump();
    expect(find.text('当前代币已切换'), findsNothing);
    state.changeLock('有原交易待核实');
    await tester.pump();
    expect(find.text('有原交易待核实'), findsOneWidget);
    expect(find.byTooltip('收起代币提示'), findsNothing);
    state.token = const TokenMeta(newAddress, 'New token', 'NEW', 18);
    state.changeLock(null);
    await tester.pump();
    expect(find.text('当前代币已切换'), findsOneWidget);
  });

  testWidgets('open editor reacts immediately to a new lock and unlock', (
    tester,
  ) async {
    await tester.pumpWidget(app(state));
    await tester.tap(find.text('编辑当前代币'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('token-address-input'));
    expect(tester.widget<TextField>(field).enabled, isTrue);
    state.changeLock('组 02 正在准备，当前代币不可更换。');
    await tester.pump();
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(find.text(state.reason!), findsNWidgets(2));
    final primary = find.widgetWithText(PrimaryButton, '确认');
    expect(tester.widget<PrimaryButton>(primary).onPressed, isNull);
    state.changeLock(null);
    await tester.pump();
    expect(tester.widget<TextField>(field).enabled, isTrue);
    expect(tester.widget<PrimaryButton>(primary).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1440.0, 390.0, 320.0]) {
    testWidgets(
      'pending launch warning survives a blocked switch and fits $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        state.reason = '组 01 正在执行，请等待结束后切换。';
        state.launches.add(
          const PendingLaunchToken(newAddress, 'NEW', 'Four.meme'),
        );
        await tester.pumpWidget(app(state));
        expect(find.textContaining('请勿误交易旧币'), findsOneWidget);
        expect(find.text(newAddress), findsOneWidget);
        expect(find.text('新币 NEW · BSC · Four.meme'), findsOneWidget);
        await tester.tap(find.text('切换到新币'));
        await tester.pumpAndSettle();
        expect(find.text('当前代币已锁定'), findsOneWidget);
        expect(state.adopted, isEmpty);
        expect(state.token!.address, oldAddress);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(find.textContaining('请勿误交易旧币'), findsOneWidget);
        state.changeLock(null);
        await tester.pump();
        // Finishing another operation does not silently switch the user's context.
        expect(state.token!.address, oldAddress);
        await tester.tap(find.text('切换到新币'));
        await tester.pumpAndSettle();
        expect(state.adopted, [newAddress]);
        expect(state.token!.address, newAddress);
        expect(find.textContaining('请勿误交易旧币'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
