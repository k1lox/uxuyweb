import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api/backend_client.dart';
import 'widgets.dart';

/// Refreshes a read-only transfer preview while its inputs and route are visible.
class TransferWarmup extends StatefulWidget {
  const TransferWarmup({
    super.key,
    required this.identity,
    required this.interval,
    required this.prepare,
  });
  final Object identity;
  final Duration interval;
  final Future<String> Function(void Function() checkCurrent) prepare;

  @override
  State<TransferWarmup> createState() => _TransferWarmupState();
}

class _TransferWarmupState extends State<TransferWarmup>
    with WidgetsBindingObserver {
  Timer? next;
  int revision = 0;
  bool running = false, currentRoute = false, foreground = true;
  String? estimate;

  bool get eligible => mounted && foreground && currentRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final life = WidgetsBinding.instance.lifecycleState;
    foreground = life == null || life == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (visible != currentRoute) {
      currentRoute = visible;
      invalidate();
    }
  }

  @override
  void didUpdateWidget(TransferWarmup old) {
    super.didUpdateWidget(old);
    if (old.identity != widget.identity || old.interval != widget.interval)
      invalidate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible != foreground)
      setState(() {
        foreground = visible;
        invalidate();
      });
  }

  void invalidate() {
    revision++;
    next?.cancel();
    estimate = null;
    if (eligible && !running)
      next = Timer(const Duration(milliseconds: 600), read);
  }

  Future<void> read() async {
    if (!eligible || running) return;
    running = true;
    final started = revision;
    void check() {
      if (!eligible || started != revision) throw StateError('转账预估已过期');
    }

    try {
      final text = await widget.prepare(check);
      check();
      setState(() => estimate = text);
    } on Object catch (error) {
      if (eligible && started == revision)
        setState(
          () => estimate =
              '预估未就绪 · ${error is BackendException ? error.userMessage : uiErrorText(error)}',
        );
    } finally {
      running = false;
      if (eligible)
        next = Timer(
          started == revision
              ? widget.interval
              : const Duration(milliseconds: 600),
          read,
        );
    }
  }

  @override
  void dispose() {
    revision++;
    next?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => estimate == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(estimate!, style: muted),
        );
}
