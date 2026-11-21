import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_configurable.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart' show FakeBackend, gasPrice;
import 'support/launch_purchase_receipt.dart';

const _created = '0x1000000000000000000000000000000000000011';
const _bncb = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';
const _nvdab = '0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436';
String _words(List<BigInt> values) =>
    '0x${values.map((v) => v.toRadixString(16).padLeft(64, '0')).join()}';

class _LaunchNode extends BackendClient {
  _LaunchNode(this.fake)
    : super(Uri.parse('http://fixture.invalid'), fake.client());
  final FakeBackend fake;
  String? failSelector;
  bool approved = true, validPreview = true;
  final signed = <(String, LegacyTx)>[];
  final positions = <String, int>{};
  var reportedPhase = 0;
  List<Map>? simulated;
  String? previewData;

  @override
  SignedTx sign(TradeWallet wallet, LegacyTx tx) {
    signed.add((wallet.address, tx));
    final signature = super.sign(wallet, tx);
    positions[signature.hash] = signed.length - 1;
    return signature;
  }

  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    const okGas = {'status': '0x1', 'gasUsed': '0x186a0'};
    final policy = List<BigInt>.filled(23, BigInt.zero)
      ..[1] = BigInt.from(1000)
      ..[4] = BigInt.from(10)
      ..[5] = BigInt.from(32)
      ..[12] = BigInt.from(2500)
      ..[13] = BigInt.from(3000);
    final factory = {
      'launchFee()': [BigInt.from(17)],
      'launchEnabled()': [BigInt.one],
      'approvedPairTokens(address)': [approved ? BigInt.one : BigInt.zero],
      'getLaunchConfig(uint256)': [
        parseUnits('1000000000', 18),
        ...List.filled(5, BigInt.zero),
        BigInt.one,
      ],
    };
    final replies = {
      for (final entry in factory.entries)
        bytesToHex(AbiFunction.parse(entry.key).selector): entry.value,
      bytesToHex(geniusPlatformPolicy.selector): policy,
      bytesToHex(geniusPreview.selector): [
        BigInt.parse(_created),
        BigInt.two,
        validPreview ? BigInt.one : BigInt.zero,
      ],
    };
    final results = <Object?>[];
    for (final (method, params) in calls) {
      if (method == 'eth_call') {
        final data = (params.first as Map)['data'] as String;
        final selector = data.substring(0, 10);
        if (selector == bytesToHex(geniusPreview.selector)) previewData = data;
        results.add(
          _words(
            replies[selector] ??
                (throw StateError('Unexpected selector $selector')),
          ),
        );
      } else if (method == 'eth_getBlockByNumber') {
        results.add({'gasLimit': '0x3938700'});
      } else if (method == 'eth_getTransactionReceipt') {
        final hash = params.single as String;
        final position = positions[hash] ?? 0;
        results.add(
          launchReceipt(hash, position, [
            purchaseTransfer(_created, signed[position].$1),
          ]),
        );
      } else if (method == 'eth_simulateV1') {
        simulated =
            ((params.first as Map)['blockStateCalls'].single['calls'] as List)
                .cast<Map>();
        results.add([
          {
            'calls': [
              for (final call in simulated!)
                if (failSelector != null &&
                    (call['data'] as String).startsWith(failSelector!))
                  {
                    'status': '0x0',
                    'error': {'message': 'PoolCreationPaused'},
                  }
                else if ((call['data'] as String).startsWith(
                  AbiFunction.parse('getLaunchedToken(address)')
                      .encodeHex([_created])
                      .substring(0, 10),
                ))
                  {
                    ...okGas,
                    'returnData': _words([
                      BigInt.parse(_created),
                      BigInt.two,
                      BigInt.parse(simulated!.first['from'] as String),
                      BigInt.zero,
                      BigInt.zero,
                      ...List.filled(5, BigInt.zero),
                      BigInt.from(reportedPhase),
                      ...List.filled(3, BigInt.zero),
                      BigInt.one,
                    ]),
                  }
                else if ((call['to'] as String).toLowerCase() ==
                    '0x${'0' * 39}2')
                  {
                    ...okGas,
                    'logs': [
                      purchaseTransfer(_created, call['from'] as String),
                    ],
                  }
                else if ((call['data'] as String).startsWith(
                  bytesToHex(geniusCreateAndBuy.selector),
                ))
                  {
                    ...okGas,
                    'returnData': _words([BigInt.parse(_created)]),
                    'logs': [
                      purchaseTransfer(_created, call['from'] as String),
                    ],
                  }
                else
                  okGas,
            ],
          },
        ]);
      } else {
        throw StateError('Unexpected RPC method $method');
      }
    }
    return results;
  }
}

void main() {
  final wallets = [
    for (var i = 0; i < 3; i++)
      TradeWallet.import(
        'Synthetic $i',
        (119000 + i).toRadixString(16).padLeft(64, '0'),
      ),
  ];
  late FakeBackend fake;
  late _LaunchNode node;
  late GeniusLauncher launcher;
  setUp(() {
    fake = FakeBackend();
    for (final w in wallets) {
      fake.wallets[w.address.toLowerCase()] = {
        'native': '${parseUnits('1000', 18)}',
        'nonce': 9,
      };
    }
    node = _LaunchNode(fake);
    launcher = GeniusLauncher(node, ExecutionLog(), sleep: (_) async {});
  });
  tearDown(() {
    launcher.dispose();
    node.http_.close();
  });

  Future<void> launch(
    String quote, {
    bool taxed = false,
    bool migration = false,
    String devBuy = '0',
    BigInt? tip,
    List<LaunchBuyer>? internal,
  }) => launcher.launch(
    GeniusLaunchForm(
      name: '模拟代币',
      tip: tip,
      symbol: 'T',
      logo: 'ipfs://test',
      quote: quote,
      creatorFeeRecipient: wallets.first.address,
      external: migration,
      exemptInternal: true,
      policy: taxed
          ? const GeniusConfigurablePolicy(
              buyBps: 200,
              sellBps: 350,
              burnBps: 10000,
            )
          : const GeniusConfigurablePolicy(lpRewards: true),
    ),
    dev: LaunchBuyer(wallets.first, parseUnits(devBuy, 18)),
    internal: internal ?? const [],
    external: [if (migration) LaunchBuyer(wallets[2], parseUnits('0.05', 18))],
  );

  for (final (symbol, quote) in [
    ('BNB', zeroAddress),
    ('WBNB', wbnb),
    ('BNCB', _bncb),
    ('NVDAB', _nvdab),
  ]) {
    for (final taxed in [false, true]) {
      test(
        'm5.2 $symbol ${taxed ? "tax" : "non-tax"}: official creation, native factory price and receipts',
        () async {
          await launch(quote, taxed: taxed);
          expect(launcher.error, isNull);
          expect(launcher.session!.token.toLowerCase(), _created);
          expect(launcher.state, LaunchState.launched);
          expect(node.simulated, hasLength(1));
          expect(node.signed.map((s) => s.$2.nonce), [9]);
          expect(fake.bundles.single, hasLength(1));
          expect(fake.calls, isNot(contains('transactions/bsc')));
          final txs = launcher.transactions;
          expect(txs.map((t) => t.status), everyElement('confirmed'));
          expect(txs.first.to, geniusM52Factory);
          expect(txs.first.from.address, wallets.first.address);
          expect(txs.single.value, BigInt.from(17));
          final created = geniusCreate.decodeInput(txs.first.data);
          final preview = geniusPreview.decodeInput(node.previewData!);
          expect(created.first, preview.first);
          expect((created[1] as List).last, 1);
          final policy = (created.first as List).last as List;
          expect(policy.take(2), [
            BigInt.from(taxed ? 200 : 0),
            BigInt.from(taxed ? 350 : 0),
          ]);
          expect(policy[6], BigInt.from(taxed ? 2500 : 3000));
        },
      );
    }
  }
  test('m5.2 native atomic launch binds recipient, input, measured minimum and evidenced delivery', () async {
    await launch(zeroAddress, devBuy: '0.1');
    expect(launcher.error, isNull);
    expect(launcher.state, LaunchState.launched);
    final tx = launcher.transactions.single;
    expect(tx.to, geniusM52LaunchAndBuy);
    expect(tx.value, parseUnits('0.1', 18) + BigInt.from(17));
    final fields = geniusCreateAndBuy.decodeInput(bytesToHex(tx.data));
    expect(fields[2], parseUnits('0.1', 18));
    expect(fields[3], BigInt.from(1228));
    expect(fake.bundles, hasLength(1));
  });
  test('only Dev funds the future tip and its transfer gas', () async {
    final buy = BigInt.from(1000), tip = BigInt.from(37);
    final price = launchBundleGasPrice(gasPrice);
    fake.wallets[wallets[1].address.toLowerCase()]!['native'] = '${buy + BigInt.from(200000) * price}';
    await launch(zeroAddress, tip: tip, internal: [LaunchBuyer(wallets[1], buy)]);
    expect(launcher.error, isNull);
    expect(launcher.session!.reserved, tip + BigInt.from(200000) * price);
    expect(node.signed.map((s) => s.$2.gasPrice), everyElement(price));
  });
  test('m5.2 ordinary launch can send two separate native curve purchases with positive exact floors', () async {
    await launch(
      zeroAddress,
      internal: [
        LaunchBuyer(wallets[1], BigInt.from(1000)),
        LaunchBuyer(wallets[2], BigInt.from(2000)),
      ],
    );
    expect(launcher.error, isNull, reason: launcher.error);
    expect(launcher.transactions.map((t) => t.kind), [
      'create',
      'inner',
      'inner',
    ]);
    expect(
      launcher.session!.wallets.map((w) => w.address),
      wallets.map((w) => w.address),
    );
    expect(launcher.transactions.skip(1).map((t) => t.minimumDelivery), [
      BigInt.from(1228),
      BigInt.from(1228),
    ]);
    expect(fake.bundles.single, hasLength(3));
  });
  test('unexpected early graduation halts a pure curve launch before any signatures', () async {
    node.reportedPhase = 1;
    await launch(zeroAddress, internal: [LaunchBuyer(wallets[1], BigInt.one)]);
    expect(launcher.error, contains('阶段'));
    expect(node.signed, isEmpty);
    expect(fake.bundles, isEmpty);
  });
  test('an external launch cannot omit every inner purchase', () async {
    await launch(_bncb, migration: true);
    expect(launcher.error, contains('内盘'));
    expect(node.signed, isEmpty);
    expect(node.previewData, isNull);
  });
  for (final failure in [
    'unapproved quote',
    'empty preview commitment',
    'creation reverted',
  ]) {
    test('m5.2 $failure stops the entire bundle before signing', () async {
      node.approved = failure != 'unapproved quote';
      node.validPreview = failure != 'empty preview commitment';
      if (failure == 'creation reverted')
        node.failSelector = bytesToHex(geniusCreate.selector);
      await launch(_bncb);
      expect(
        launcher.error,
        contains(switch (failure) {
          'unapproved quote' => '尚未支持',
          'empty preview commitment' => '创建预览无效',
          _ => '预检失败',
        }),
      );
      if (failure == 'creation reverted') {
        expect(node.simulated, hasLength(1));
      } else {
        expect(node.simulated, isNull);
      }
      expect(node.signed, isEmpty);
      expect(fake.bundles, isEmpty);
      expect(launcher.session, isNull);
      if (failure == 'creation reverted') {
        expect(
          launcher.error,
          contains('PoolCreationPaused'),
          reason: 'The contract paused pool creation; adding BNB cannot resolve it.',
        );
        expect(launcher.error, isNot(contains('请增加内盘地址或金额')));
      }
    });
  }
}
