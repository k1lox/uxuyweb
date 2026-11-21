import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/ui/transfer_warmup.dart';

void main() {
  for (final seconds in [5, 10]) {
    testWidgets(
      'idle transfer preview refreshes every $seconds seconds without overlapping and discards obsolete input',
      (tester) async {
        final started = <int>[];
        final old = Completer<void>();
        Widget form(int version) => MaterialApp(
          home: Scaffold(
            body: TransferWarmup(
              identity: version,
              interval: Duration(seconds: seconds),
              prepare: (check) async {
                started.add(version);
                if (version == 1) await old.future;
                check();
                return 'estimated $version';
              },
            ),
          ),
        );
        await tester.pumpWidget(form(1));
        await tester.pump(const Duration(milliseconds: 601));
        await tester.pump(Duration(seconds: seconds * 2));
        expect(started, [1]);
        await tester.pumpWidget(form(2));
        old.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 601));
        await tester.pump();
        expect(started, [1, 2]);
        expect(find.text('estimated 2'), findsOneWidget);
        expect(find.text('estimated 1'), findsNothing);
        await tester.pump(Duration(seconds: seconds - 1));
        expect(started, [1, 2]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(started, [1, 2, 2]);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(Duration(seconds: seconds * 2));
        expect(started, [1, 2, 2]);
      },
    );
  }
}
