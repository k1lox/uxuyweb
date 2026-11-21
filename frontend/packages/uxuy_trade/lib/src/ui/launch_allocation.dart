import 'package:flutter/material.dart';

import '../api/backend_client.dart';
import '../evm/evm.dart';
import '../exec/launch.dart' show launchBundleGas;
import 'widgets.dart';

enum LaunchAllocationPlatform { four, flap, genius }

/// The BotAI allocation control keeps a BNB reserve for the selected launch
/// phase. Paying in the pool token leaves the BNB balance untouched.
BigInt launchBuyerMaximum({
  required LaunchAllocationPlatform platform,
  required BigInt balance,
  required BigInt gasPrice,
  required bool payNative,
  required bool nativePool,
  required bool migrate,
  required bool outside,
  required bool lastInner,
}) {
  if (balance.isNegative) throw StateError('钱包余额无效');
  if (!payNative) return balance;
  if (platform != LaunchAllocationPlatform.genius &&
      (gasPrice <= BigInt.zero || gasPrice > BigInt.from(100000000000))) {
    throw StateError('BSC Gas 单价无效或超过 100 Gwei，请重新读取');
  }
  BigInt reserve;
  switch (platform) {
    case LaunchAllocationPlatform.four:
      final buy = outside
          ? 2500000
          : migrate && lastInner
          ? 8000000
          : 2000000;
      final sell = migrate ? 2500000 : 2000000;
      final approvals = !nativePool && !migrate ? 3 : 2;
      reserve = gasPrice * BigInt.from(buy + sell + 150000 * approvals);
    case LaunchAllocationPlatform.flap:
      final buy = outside
          ? 5000000
          : migrate && lastInner
          ? 8000000
          : 3000000;
      reserve = gasPrice * BigInt.from(buy + 5000000 + 150000);
    case LaunchAllocationPlatform.genius:
      reserve = BigInt.from(5000000000000000); // 0.005 BNB, as in BotAI.
  }
  return balance > reserve ? balance - reserve : BigInt.zero;
}

typedef LaunchAllocationRow = ({String address, BigInt maximum, String amount});

Future<List<LaunchAllocationRow>> loadLaunchAllocation(
  BackendClient api, {
  required List<({String address, String amount})> buyers,
  required LaunchAllocationPlatform platform,
  required String? paymentToken,
  required bool nativePool,
  required bool migrate,
  required bool outside,
}) async {
  final gasPrice =
      paymentToken == null && platform != LaunchAllocationPlatform.genius
      ? (await launchBundleGas(api)).gasPrice
      : BigInt.zero;
  final states = <String, WalletState>{};
  for (var offset = 0; offset < buyers.length; offset += 100) {
    final addresses = [
      for (final b in buyers.skip(offset).take(100)) b.address,
    ];
    final rows = await api.transferWalletStates(
      addresses,
      token: paymentToken,
      refresh: true,
    );
    for (final row in rows) {
      states[row.wallet.toLowerCase()] = row;
    }
  }
  return [
    for (final (index, buyer) in buyers.indexed)
      (
        address: buyer.address,
        amount: buyer.amount,
        maximum: launchBuyerMaximum(
          platform: platform,
          balance:
              (paymentToken == null
                  ? states[buyer.address.toLowerCase()]?.native
                  : states[buyer.address.toLowerCase()]?.tokenBalance) ??
              (throw StateError('${buyer.address} 余额读取不完整，请重试')),
          gasPrice: gasPrice,
          payNative: paymentToken == null,
          nativePool: nativePool,
          migrate: migrate,
          outside: outside,
          lastInner: !outside && index == buyers.length - 1,
        ),
      ),
  ];
}

class LaunchAllocationDialog extends StatefulWidget {
  const LaunchAllocationDialog({
    super.key,
    required this.title,
    required this.rows,
    required this.decimals,
    required this.symbol,
  });
  final String title;
  final List<LaunchAllocationRow> rows;
  final int decimals;
  final String symbol;

  @override
  State<LaunchAllocationDialog> createState() => _LaunchAllocationDialogState();
}

class _LaunchAllocationDialogState extends State<LaunchAllocationDialog> {
  final changes = <String, String>{};
  int? percent;

  String amount(BigInt value) =>
      formatUnits(value, widget.decimals, maxFraction: widget.decimals);

  void setPercent(int value) => setState(() {
    percent = value;
    for (final row in widget.rows) {
      changes[row.address] = amount(
        row.maximum * BigInt.from(value) ~/ BigInt.from(100),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    const label = Text('可用余额比例');
    final reading = Text(percent == null ? '自定义' : '$percent%');
    final slider = Slider(
      value: (percent ?? 0).toDouble(),
      max: 100,
      divisions: 100,
      semanticFormatterCallback: (v) => '${v.round()}%',
      onChanged: (v) => setPercent(v.round()),
    );
    return UiDialog(
      title: Text(widget.title),
      width: 560,
      scrollable: false,
      content: SizedBox(
        height:
            ((narrow ? 72.0 : 48.0) +
                    widget.rows.length * (narrow ? 101.0 : 82.0))
                .clamp(0.0, 390.0)
                .toDouble(),
        child: Column(
          children: [
            if (narrow) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [label, reading],
              ),
              slider,
            ] else
              Row(
                children: [
                  label,
                  Expanded(child: slider),
                  reading,
                ],
              ),
            Expanded(
              child: ListView.separated(
                itemCount: widget.rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final row = widget.rows[i];
                  final current = changes[row.address] ?? row.amount;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(row.address, style: mono),
                        Text('可用 ${amount(row.maximum)} ${widget.symbol}'),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '买入 ${current.isEmpty ? '—' : current} ${widget.symbol}',
                              ),
                            ),
                            SmallButton(
                              label: '最大',
                              onPressed: () => setState(() {
                                changes[row.address] = amount(row.maximum);
                                percent = null;
                              }),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: changes.isEmpty
              ? null
              : () => Navigator.pop(context, changes),
          child: const Text('应用金额'),
        ),
      ],
    );
  }
}
