import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/executor.dart';
import 'package:uxuy_trade/src/exec/genius_launch.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart' show FakeBackend;
import 'support/launch_purchase_receipt.dart';

const token = '0x1000000000000000000000000000000000000011';
final dev = TradeWallet.import('test', 'ea'.padLeft(64, '0'));

class _Node extends BackendClient {
  _Node() : super(Uri.parse('http://fixture.invalid'), FakeBackend().client());
  final statuses = <Object>[];
  int uploads = 0, nonce = 0;
  String? job;
  int metadataDecimals = 6;
  bool approved = true;
  Map<String, dynamic> receipts = {};
  @override
  Future<Map<String, dynamic>> geniusUpload(
    LaunchImage image, {
    required String address,
    required String signature,
    required String timestamp,
  }) async {
    uploads++;
    return {'uploadId': 'review$uploads', 'capability': '0123456789abcdef'};
  }

  @override
  Future<Map<String, dynamic>> geniusUploadStatus(
    String id,
    String capability,
  ) async {
    job = id;
    final response = statuses.removeAt(0);
    if (response is Map<String, dynamic>) return response;
    throw response;
  }

  @override
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async => [
    WalletState(dev.address, BigInt.from(1000000000), nonce, null, null),
  ];
  @override
  Future<TxRecord> reconcileStatus(String hash) => status(hash);
  @override
  Future<TxRecord> status(String hash) async => TxRecord(
    hash,
    'confirmed',
    null,
    receipt: receipts[hash] as Map<String, dynamic>?,
  );
  @override
  Future<TokenMeta> token(String address) async =>
      TokenMeta(address, 'USDX', 'USDX', metadataDecimals);
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    String words(List<int> values) =>
        '0x${values.map((v) => v.toRadixString(16).padLeft(64, '0')).join()}';
    String selector(String name) =>
        bytesToHex(AbiFunction.parse(name).selector);
    final rows = {
      selector('launchEnabled()'): [1],
      selector('launchFee()'): [17],
      selector('getLaunchConfig(uint256)'): [100, 77, 12, 900, 1, 1, 1],
      selector('approvedPairTokens(address)'): [approved ? 1 : 0],
      selector('pairTokenEconomics(address)'): [5, 123456789, 6],
    };
    return [
      for (final (method, args) in calls)
        if (method == 'eth_call')
          words(rows[((args.first as Map)['data'] as String).substring(0, 10)]!)
        else if (method == 'eth_getTransactionReceipt')
          receipts[args.first]
        else
          throw StateError(method),
    ];
  }
}

class _ApprovalNode extends _Node {
  final allowances = <String, BigInt>{};
  final grants = <List<({String wallet, BigInt amount, bool reset})>>[];
  final sent = <List<LaunchTx>>[];
  int? grantDelta = 0;
  @override
  Future<List<WalletState>> refreshWalletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) async => [
    for (final w in wallets)
      WalletState(
        w,
        parseUnits('1', 18),
        0,
        BigInt.from(200),
        allowances[w.toLowerCase()] ?? BigInt.zero,
      ),
  ];
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async => [
    for (final c in calls)
      if (c.$1 == 'eth_getBlockByNumber')
        {'gasLimit': '0xdbba0'}
      else if (c.$1 == 'eth_simulateV1')
        [
          {
            'calls': [
              for (final _
                  in (((c.$2.first as Map)['blockStateCalls'] as List)
                          .first['calls']
                      as List))
                {'status': '0x1', 'gasUsed': '0x9c40', 'logs': []},
            ],
          },
        ]
      else
        throw StateError(c.$1),
  ];
  @override
  Future<int> checkLaunchPayments(
    String token,
    String spender,
    List<({String wallet, BigInt amount, bool reset})> rows, {
    Map<String, Object?>? launchContext,
  }) async {
    expect(launchContext?['dev'], dev.address);
    grants.add(rows);
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60;
  }

  @override
  Future<GasInfo> gas() async => GasInfo(BigInt.one, 4200);
  @override
  Future<List<WalletState>> walletStates(
    List<String> wallets, {
    String? token,
    String? spender,
  }) => refreshWalletStates(wallets, token: token, spender: spender);
}

class _ApprovalRunner extends FourLauncher {
  _ApprovalRunner(this.node) : super(node, ExecutionLog());
  final _ApprovalNode node;
  @override
  Future<bool> submitBundle(
    List<LaunchTx> txs,
    List<String> raws, {
    String what = '主交易',
  }) async {
    expect(txs.map((tx) => tx.kind), everyElement('approve'));
    node.sent.add(txs);
    for (final tx in txs) {
      final args = AbiFunction.parse('approve(address,uint256)')
          .decodeInput(tx.data);
      if (node.grantDelta != null) {
        node.allowances[tx.from.address.toLowerCase()] =
            (args[1] as BigInt) + BigInt.from(node.grantDelta!);
      }
      tx.status = 'confirmed';
    }
    transactions = txs;
    return true;
  }
}

void main() {
  final img = LaunchImage(
    [137, 80, 78, 71, 13, 10, 26, 10],
    'logo.png',
    'image/png',
  );
  late _Node api;
  late GeniusLauncher runner;
  setUp(() {
    api = _Node();
    runner = GeniusLauncher(api, ExecutionLog(), sleep: (_) async {});
  });
  tearDown(() {
    runner.dispose();
    api.http_.close();
  });
  for (final delta in <int?>[null, 1, 0]) {
    test(
      'issuance exact allowances keep reset pairs together and reread each batch, adjustment=$delta',
      () async {
        final node = _ApprovalNode()..grantDelta = delta;
        final approver = _ApprovalRunner(node);
        addTearDown(approver.dispose);
        addTearDown(node.http_.close);
        final buyers = [
          for (var i = 0; i < 4; i++)
            LaunchBuyer(
              TradeWallet.import(
                'b$i',
                (i + 601).toRadixString(16).padLeft(64, '0'),
              ),
              BigInt.from(101 + i),
            ),
        ];
        node.allowances[buyers.first.wallet.address.toLowerCase()] = BigInt.one;
        var reviews = 0;
        approver.confirmApproval = (asset, spender, batch, gas) async {
          expect(asset, token);
          expect(spender, fourManager);
          expect(gas, greaterThan(BigInt.zero));
          reviews++;
          return true;
        };
        final run = approver.authorizeLaunchPayments(
          token,
          fourManager,
          buyers,
          launchContext: {'dev': dev.address},
        );
        if (delta != 0) {
          await expectLater(run, throwsStateError);
          expect(node.sent, hasLength(1));
          return;
        }
        await run;
        expect(reviews, 2);
        expect(node.sent.map((g) => g.length), [3, 2]);
        expect(node.grants.map((g) => g.length), [2, 2]);
        expect(node.grants[0].first.reset, isTrue);
        for (final b in buyers) {
          expect(node.allowances[b.wallet.address.toLowerCase()], b.amount);
        }
      },
    );
  }
  test('retry the original image review with unchanged owner/image; rejection clears it', () async {
    api.statuses.addAll([
      StateError('offline'),
      {'status': 'rejected'},
      {'status': 'approved', 'uri': 'ipfs://second'},
    ]);
    await expectLater(runner.uploadImage(img, dev), throwsStateError);
    await expectLater(runner.uploadImage(img, dev), throwsStateError);
    expect(api.uploads, 1);
    expect(api.job, 'review1');
    expect(await runner.uploadImage(img, dev), 'ipfs://second');
    expect(api.job, 'review2');
    expect(api.uploads, 2);
  });
  test('original pending image times out, changing owner creates another authorized upload', () async {
    api.statuses.addAll([
      ...List.filled(60, {'status': 'pending'}),
      {'status': 'approved', 'uri': 'ipfs://approved'},
    ]);
    await expectLater(runner.uploadImage(img, dev), throwsStateError);
    final other = TradeWallet.import('other', 'dc'.padLeft(64, '0'));
    expect(await runner.uploadImage(img, other), 'ipfs://approved');
    expect(api.uploads, 2);
  });
  test('Genius previews approved pair terms with real units, handles unapproved or mismatched decimals', () async {
    final native = await runner.previewPool(zeroAddress);
    expect(
      (native.fee, native.threshold, native.curveFeeBps, native.decimals),
      (BigInt.from(17), BigInt.from(900), BigInt.from(77), 18),
    );
    final erc = await runner.previewPool(token);
    expect(
      (erc.threshold, erc.decimals, erc.symbol),
      (BigInt.from(123456789), 6, 'USDX'),
    );
    api.approved = false;
    await expectLater(runner.previewPool(token), throwsStateError);
    api.approved = true;
    api.metadataDecimals = 18;
    await expectLater(runner.previewPool(token), throwsStateError);
  });
  LaunchTx create() => LaunchTx(
    'create',
    dev,
    token,
    Uint8List(0),
    BigInt.from(17),
    10000,
    kind: 'create',
    creationFee: BigInt.from(17),
  )..hash = 'create';
  LaunchTx alpha() => LaunchTx(
    'alpha',
    dev,
    geniusAlphaRegistry,
    Uint8List(0),
    BigInt.from(45),
    20000,
    kind: 'alpha',
    alphaToken: token,
  )..hash = 'alpha';
  Map<String, dynamic> promoted() => {
    'address': geniusAlphaRegistry,
    'topics': [
      bytesToHex(keccak256('AlphaPromoted(address,address,uint256)'.codeUnits)),
      '0x${token.substring(2).padLeft(64, '0')}',
      '0x${dev.address.toLowerCase().substring(2).padLeft(64, '0')}',
    ],
    'data': '0x${45.toRadixString(16).padLeft(64, '0')}',
  };
  test('Alpha proof binds registry, token, payer and wei; each successful receipt must share block and order', () async {
    final tx = alpha();
    final event = promoted();
    expect(
      launchAlphaPaid({
        'logs': [event],
      }, tx),
      isTrue,
    );
    for (final field in ['address', 'data', 'token', 'payer']) {
      final wrong = {...event};
      final topics = [...(event['topics'] as List)];
      if (field == 'token' || field == 'payer') {
        topics[field == 'token' ? 1 : 2] = '0x${'0' * 64}';
        wrong['topics'] = topics;
      } else {
        wrong[field] = '0x0';
      }
      expect(
        launchAlphaPaid({
          'logs': [wrong],
        }, tx),
        isFalse,
      );
    }
    Future<String> settle(Map<String, dynamic> raw) async {
      final start = create()..status = 'submitted';
      final paid = alpha()..status = 'submitted';
      api.receipts = {'create': launchReceipt('create', 0, []), 'alpha': raw};
      await runner.settle([start, paid]);
      expect(start.status, 'confirmed');
      return paid.status;
    }

    expect(await settle(launchReceipt('alpha', 1, [event])), 'confirmed');
    expect(await settle(launchReceipt('alpha', 0, [event])), 'order_mismatch');
    expect(
      await settle({
        ...launchReceipt('alpha', 1, [event]),
        'blockNumber': '0x888',
      }),
      'order_mismatch',
    );
    expect(await settle(launchReceipt('alpha', 1, [])), 'alpha_unproven');
    expect(await settle(launchReceipt('other', 1, [event])), 'unknown');
    expect(await settle(launchReceipt('alpha', 1, [{...event, 'removed': true}])), 'unknown');
    final start = create()..status = 'submitted';
    final paid = alpha()..status = 'submitted';
    api.receipts = {
      'create': launchReceipt('create', 0, []),
      'alpha': {...launchReceipt('alpha', 1, [event]), 'blockHash': '0x${'34' * 32}'},
    };
    expect(await runner.settle([start, paid]), isFalse);
    expect([start.status, paid.status], everyElement('unknown'));
    expect([start.receipt, paid.receipt], everyElement(isNull));
    runner.state = LaunchState.pending;
    runner.transactions = [start, paid];
    api.receipts['alpha'] = launchReceipt('alpha', 1, [event]);
    await runner.query();
    expect(runner.state, LaunchState.launched);
    expect([start.status, paid.status], everyElement('confirmed'));
  });
  test('final cost cancellation and a changed nonce both stop before signing or submission', () async {
    final tx = create()..hash = null;
    final session = LaunchSession(
      platform: 'genius',
      token: token,
      symbol: 'G',
      dev: dev,
      wallets: [dev],
    );
    final nonces = {dev.address.toLowerCase(): 0};
    runner.confirmCosts = (legs, price, _) async {
      expect(legs.single.creationFee, BigInt.from(17));
      expect(price, BigInt.two);
      return false;
    };
    await runner.launchBundle([tx], nonces, BigInt.two, session);
    expect(tx.hash, isNull);
    expect(runner.session, isNull);
    runner.confirmCosts = (_, _, _) async => true;
    api.nonce = 1;
    await expectLater(
      runner.launchBundle([tx], nonces, BigInt.two, session),
      throwsStateError,
    );
    expect(tx.hash, isNull);
    expect(runner.session, isNull);
  });
}
