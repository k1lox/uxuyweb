import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_business_sdk/uxuy_business_sdk.dart';

import 'src/api/backend_client.dart';
import 'src/api/scoped_client.dart';
import 'src/state/app_state.dart';
import 'src/ui/shell.dart';
import 'src/ui/theme.dart';
import 'src/wallet/wallet.dart';

export 'src/api/backend_client.dart';
export 'src/evm/evm.dart'
    show parseUnits, formatUnits, isAddress, checksumAddress;
export 'src/exec/launch.dart' show Launcher, LaunchState, LaunchSession;
export 'src/exec/executor.dart';
export 'src/state/app_state.dart';
export 'src/wallet/wallet.dart' show TradeWallet, KeyStore, MemoryKeyStore;

/// Default for embedded hosts. Production builds can set UXUY_BACKEND
/// or the host can pass its own [UxuyTradeModule.endpoint].
const uxuyTradeEndpoint = String.fromEnvironment(
  'UXUY_BACKEND',
  defaultValue: 'http://127.0.0.1:3291/',
);

/// UXUY BSC batch trading module. Uses its own wallets, signs locally and talks only to its backend.
/// Minimal host integration: `UxuyTradeModule(imagePicker: ...)`.
class UxuyTradeModule implements BusinessModule {
  const UxuyTradeModule({
    this.endpoint,
    this.clientFactory = http.Client.new,
    this.keyStoreFactory,
    this.imagePicker,
  });

  /// Backend address for this host. Defaults to [uxuyTradeEndpoint].
  final Uri? endpoint;

  /// HTTP client for the module's backend requests; one per session, closed on dispose.
  final http.Client Function() clientFactory;

  /// Wallet storage. Null keeps imported keys in memory only (gone when the session ends).
  final KeyStore Function()? keyStoreFactory;

  /// Token image chooser supplied by the embedding app (launchpads). Bytes stay in memory.
  final Future<LaunchImage?> Function()? imagePicker;

  @override
  ModuleManifest get manifest => const ModuleManifest(
    id: 'uxuy.trade',
    sdkMajor: businessSdkMajor,
    capabilities: {BusinessCapability.dialogs},
  );

  @override
  ModuleSession createSession(BusinessHost host) {
    final client = ScopedClient(host.scope, clientFactory());
    final backend = BackendClient(
      endpoint ?? Uri.parse(uxuyTradeEndpoint),
      client,
    );
    final state = AppState(
      backend,
      (keyStoreFactory ?? MemoryKeyStore.new)(),
      imagePicker: imagePicker,
    );
    return _TradeSession(host, state, client);
  }
}

class _TradeSession implements ModuleSession {
  _TradeSession(this.host, this.state, this.client) {
    // A revoked scope can never be revived: stop any pending sends for this session.
    unawaited(
      host.scope.revoked.then((_) {
        if (!_disposed) state.stopAll();
      }),
    );
    unawaited(state.init());
  }

  final BusinessHost host;
  final AppState state;
  final http.Client client;
  bool _disposed = false;

  @override
  Widget buildEntry() => TradeModuleNavigator(state: state);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.dispose();
    client.close();
  }
}

/// Module-owned nested navigation under the host theme (colors only are overridden).
class TradeModuleNavigator extends StatefulWidget {
  const TradeModuleNavigator({super.key, required this.state});
  final AppState state;
  @override
  State<TradeModuleNavigator> createState() => _TradeModuleNavigatorState();
}

class _TradeModuleNavigatorState extends State<TradeModuleNavigator> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final outer = Navigator.of(context);
    return Theme(
      data: uxuyTheme(Theme.of(context)),
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (result) => _navigator.currentState?.pop(result),
        child: Navigator(
          key: _navigator,
          onGenerateRoute: (settings) {
            if (settings.name != Navigator.defaultRouteName) return null;
            return MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/uxuy_trade/home'),
              builder: (_) => HomePage(
                state: widget.state,
                onExit: outer.canPop() ? () => outer.maybePop() : null,
              ),
            );
          },
        ),
      ),
    );
  }
}
