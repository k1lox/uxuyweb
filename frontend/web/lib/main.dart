import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/uxuy_trade.dart';
import 'package:uxuy_trade/web_workspace.dart';
import 'package:web/web.dart' as web;

import 'browser_impact_settings.dart';
import 'browser_wallet_backup.dart';
import 'image_picker_web.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UxuyWeb());
}

/// Browser entry, no Mock host and no host wallet. Uses the unchanged trading core.
class UxuyWeb extends StatefulWidget {
  const UxuyWeb({super.key});
  @override
  State<UxuyWeb> createState() => _UxuyWebState();
}

class _UxuyWebState extends State<UxuyWeb> {
  final http.Client client = http.Client();
  final imagePicker = BrowserImagePicker();
  late final AppState state;
  late final JSFunction beforeUnload;
  late final JSFunction onBackupPageActive;
  late final Timer _backupAccessTimer;

  @override
  void initState() {
    super.initState();
    const configured = String.fromEnvironment('UXUY_BACKEND');
    final endpoint = configured.isEmpty
        ? Uri.base.resolve('/')
        : Uri.parse(configured);
    final backup = BrowserWalletBackup();
    final settings = BrowserImpactSettings();
    String? settingsError;
    late final ImpactSettings initial;
    try {
      initial = settings.load();
    } on StateError catch (e) {
      initial = const ImpactSettings(bundle: 0, intervalStart: 0, intervalLive: 0);
      settingsError = '${e.message}，本次按 0% 提醒，请重新保存设置';
    }
    state = AppState(
      BackendClient(endpoint, client, requireFeeFreeService: true),
      MemoryKeyStore(),
      backupDirectory: backup,
      imagePicker: imagePicker.pick,
      downloadText: (filename, content) {
        final blob = web.Blob([content.toJS].toJS, web.BlobPropertyBag(type: 'text/plain;charset=utf-8'));
        final url = web.URL.createObjectURL(blob);
        try {
          final link = web.HTMLAnchorElement()..href=url..download=filename;
          web.document.body!.append(link);
          try { link.click(); } finally { link.remove(); }
        } finally {Timer(const Duration(minutes:1),()=>web.URL.revokeObjectURL(url));}
      },
      impactSettings: initial,
      persistImpactSettings: settings.save,
    );
    state.log.readHistory = backup.history;
    state.log.onRecord = (entry) {
      unawaited(backup.recordLog(entry.text, entry.level.name, entry.time)
          .catchError((Object _) => state.walletBackup!.checkAccess()));
    };
    if (settingsError != null) state.log.add(settingsError);
    beforeUnload = ((web.BeforeUnloadEvent event) {
      // Form drafts can live only in the current tab. Chrome supplies the prompt.
      if (!web.window.navigator.userActivation.hasBeenActive) return;
      event.preventDefault();
      event.returnValue = 'true';
    }).toJS;
    web.window.addEventListener('beforeunload', beforeUnload);
    unawaited(state.walletBackup!.restore());
    onBackupPageActive = ((web.Event _) {
      if (web.document.hidden) {
        if (backup.hasPendingLogs) unawaited(backup.flushHistory().catchError((Object _) {}));
      } else {
        unawaited(state.walletBackup!.checkAccess());
      }
    }).toJS;
    web.window.addEventListener('focus', onBackupPageActive);
    web.document.addEventListener('visibilitychange', onBackupPageActive);
    _backupAccessTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(state.walletBackup!.checkAccess()),
    );
    unawaited(state.init());
  }

  @override
  void dispose() {
    web.window.removeEventListener('beforeunload', beforeUnload);
    web.window.removeEventListener('focus', onBackupPageActive);
    web.document.removeEventListener('visibilitychange', onBackupPageActive);
    _backupAccessTimer.cancel();
    imagePicker.dispose();
    state.stopAll();
    state.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'UXUY',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: componentTheme(
      uxuyTheme(
        ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          fontFamily: 'UXUYSans',
        ),
      ),
    ),
    home: HomePage(state: state),
  );
}
