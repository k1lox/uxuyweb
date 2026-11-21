import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/evm/evm.dart';

const router = '0x00000000000000000000000000000000000C0dE1';
const token = '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82';
const pool = '0x0ed7e52944161450477ee417de9cd3a859b14fd0';
final gasPrice = BigInt.from(50000000);

// Opaque provider payload. The surrogate binds the quoted wallet and input.
String uxuyCall(String wallet, BigInt amount, bool buy) =>
    '0x5103aafa${wallet.toLowerCase().substring(2).padLeft(64, '0')}'
    '${amount.toRadixString(16).padLeft(64, '0')}${buy ? '01' : '00'}';

/// In-memory backend: records every request; never touches a network.
class FakeBackend {
  BackendClient api() => _RecordingClient(this);
  Map<String,Object?> Function(Map<String,dynamic>)? innerQuote;
  String activeRouter = router;
  final minedNonces=<String,int>{};
  String? activeSpender;
  final traces = <String, Map<String, Object?>>{};
  final signatures = <String, (String, String, LegacyTx)>{};
  final chainReceipts = <String, Map<String, Object?>>{};
  final calls = <String>[];
  final submitted = <String>[];
  final bundles = <List<String>>[];
  final Map<String, Map<String, Object>> wallets = {};
  final Set<String> refuse = {}; // wallets whose route is refused for liquidity
  final bundleRouteRequests = <List<Map<String, dynamic>>>[];
  final routeAmounts = <String>[];
  final routeBodies = <Map<String, dynamic>>[];
  void Function()? afterSubmit;
  void Function(List<String> raws)? onBundle;
  String? bundleStatus;
  String receipt = 'confirmed';

  /// Receipt status per bundle attempt (consumed in order); falls back to [receipt].
  final List<String> receipts = [];
  final Map<String, String> codes = {};
  int estimateGas = 50000;
  int blockGasLimit = 60000000;
  bool applyApproval = true;
  bool settleLiquidations = false;
  BigInt? actualLiquidationOutput;
  final settlementByWallet = <String,String>{};
  final tokenMetadata = <String,Map<String,Object>>{};
  double? adverseImpact;

  http.Client client() => MockClient((req) async {
    final path = req.url.path.replaceFirst('/api/v1/', '');
    calls.add(path);
    Map<String, dynamic> body() => jsonDecode(req.body) as Map<String, dynamic>;
    Object res;
    if (path == 'config') {
      res = {
        'ok': true,
        'router': activeRouter,
        'approvalSpender': activeSpender ?? activeRouter,
        'routeSource': 'uxuy',
        'routeEnabled': true,
        'maxPriceImpactPercent': 10.0,
        'fastPreflightVersion': 1,
      };
    } else if (path.startsWith('tokens/') && tokenMetadata.containsKey(path.substring(7).toLowerCase())) {
      res = {'ok':true, 'token':tokenMetadata[path.substring(7).toLowerCase()]};
    } else if (path == 'platforms/bsc') {
      res = {
        'ok': true,
        'result': {
          'address': body()['token'],
          'symbol': 'CAKE',
          'decimals': 18,
          'platform': 'external',
          'external': true,
          'quote': '0x0000000000000000000000000000000000000000',
          'block': 1000,
        },
      };
    } else if (path == 'gas') {
      res = {'ok': true, 'gasPrice': gasPrice.toString(), 'blockNumber': 1000};
    } else if (path == 'wallets/state') {
      res = {
        'ok': true,
        'wallets': [
          for (final w in body()['wallets'] as List)
            {'wallet': w, ...wallets[(w as String).toLowerCase()]!},
        ],
      };
    } else if (path == 'approvals/check') {
      final input = body();
      res = {'ok':true, 'token':input['token'], 'chainId':56, 'spender':activeSpender ?? activeRouter,
        'deadline': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90, 'wallets':input['wallets']};
    } else if (path == 'routes/rapid-check') {
      final request = body(), buy = request['buy'] as Map;
      final owner = (buy['wallet'] as String).toLowerCase();
      final before = BigInt.parse(wallets[owner]!['tokenBalance'] as String);
      final receive = BigInt.parse(buy['amount'] as String) * BigInt.two;
      final value = BigInt.parse(request['sellValue'] as String);
      final sell = request['percentSell'] == true ? (before + receive) * value ~/ BigInt.from(10000) : value;
      res = {'ok': true, 'wallet':owner, 'token':buy['token'], 'received':'$receive', 'before':'$before',
        'buyGas':200000, 'sellGas':200000, 'sellAmount':'$sell','buyApprovals':[], 'sellApprovals':[]};
    } else if (path == 'routes') {
      res = _route(body());
    } else if (path == 'routes/bundle') {
      final requests = (body()['requests'] as List)
          .cast<Map<String, dynamic>>();
      bundleRouteRequests.add(requests);
      final amount = requests.fold(
        BigInt.zero,
        (n, r) => n + BigInt.parse(r['amount'] as String),
      );
      final group = _route({
        ...requests.first,
        'amount': amount.toString(),
        'forecastOnly': true,
      }, checkWallet: false);
      final rows = [
        if (requests.first['forecastOnly'] != true)
          for (final r in requests) _route(r, record: false, bundle: true),
      ];
      final failed = rows.where((row) => row['ok'] != true);
      res = failed.isNotEmpty
          ? failed.first
          : {
              'ok': true,
              'groupPlan': {
                ...(group['plan'] as Map),
                'quoteScope': 'bundle',
                'data': '0x',
                'gasLimit': 0,
              },
              'results': rows,
            };
    } else if (path == 'routes/batch') {
      res = {
        'ok': true,
        'results': [
          for (final r in body()['requests'] as List)
            _route(r as Map<String, dynamic>),
        ],
      };
    } else if (path == 'transactions/bsc') {
      final raws = [for (final r in body()['transactions'] as List) '$r'];
      final out = <Object>[];
      for (final raw in raws) {
        submitted.add(raw);
        afterSubmit?.call();
        out.add({
          'transactionHash': bytesToHex(_hash(raw)),
          'status': 'accepted',
        });
      }
      res = {'ok': true, 'result': out};
    } else if (path.startsWith('transactions/bsc/')) {
      res = {
        'ok': true,
        'result': {
          'transactionHash': path.split('/').last,
          'status': bundleStatus ?? receipt,
          'receipt': chainReceipts[path.split('/').last],
        },
      };
    } else if (path == 'rpc/bsc') {
      // Receipts with zero gas keep balance-delta accounting exact in tests.
      res = [
        for (final c in jsonDecode(req.body) as List)
          {
            'jsonrpc': '2.0',
            'id': (c as Map)['id'],
            'result': switch (c['method']) {
              'eth_blockNumber' => '0x3e8', // Same head returned by the gas endpoint.
              'eth_getBlockByNumber' => {'gasLimit': '0x${blockGasLimit.toRadixString(16)}'},
              'eth_getTransactionCount' => '0x${(((c['params'] as List).last == 'latest' ? minedNonces[(c['params'].first as String).toLowerCase()] : null) ?? wallets[((c['params'] as List).first as String).toLowerCase()]?['nonce'] as int? ?? 0).toRadixString(16)}',
              'eth_getCode' =>
                codes[('${(c['params'] as List).first}').toLowerCase()] ?? '0x',
              'debug_traceTransaction' => traces[(c['params'] as List).first],
              'eth_estimateGas' => '0x${estimateGas.toRadixString(16)}',
              'eth_getTransactionReceipt'
                  when chainReceipts.containsKey((c['params'] as List).first) =>
                chainReceipts[(c['params'] as List).first],
              _ => {
                'gasUsed': '0x0',
                'effectiveGasPrice': '0x0',
                'status': '0x1',
              },
            },
          },
      ];
    } else if (path == 'bundles') {
      final raws = [for (final r in body()['transactions'] as List) '$r'];
      final before = {for (final e in wallets.entries) e.key: Map.of(e.value)};
      bundles.add(raws);
      for (final raw in raws) {
        submitted.add(raw);
        afterSubmit?.call();
      }
      bundleStatus = receipts.isNotEmpty ? receipts.removeAt(0) : null;
      onBundle?.call(raws);
      for (final raw in raws) {
        final item = signatures[raw];
        final placement = {
          'blockHash': '0x${(100+bundles.length).toRadixString(16).padLeft(64, '0')}',
          'blockNumber': '0x${(100+bundles.length).toRadixString(16)}',
          'transactionIndex': '0x${raws.indexOf(raw).toRadixString(16)}',
        };
        if (item == null) {
          final hash = bytesToHex(keccak256(hexToBytes(raw)));
          chainReceipts[hash] = {...placement, 'transactionHash':hash, 'status':(bundleStatus ?? receipt) == 'reverted' ? '0x0' : '0x1', 'gasUsed':'0x5208', 'effectiveGasPrice':'0x0'};
          continue;
        }
        final (hash, owner, tx) = item;
        final row = wallets[owner];
        if (row != null && {'confirmed','reverted'}.contains(bundleStatus ?? receipt) &&
            (row['nonce'] as int) <= tx.nonce) {
          row['nonce'] = tx.nonce + 1;
        }
        final logs = <Map<String, Object?>>[];
        final to = tx.to?.toLowerCase();
        String sig(String s) => bytesToHex(keccak256(s.codeUnits));
        String word(BigInt n) => n.toRadixString(16).padLeft(64, '0');
        String addr(String a) =>
            '0x${a.toLowerCase().substring(2).padLeft(64, '0')}';
        void transfer(String from, String dest, BigInt value) => logs.add({
          'address': to == activeRouter.toLowerCase() ? token : to,
          'topics': [
            sig('Transfer(address,address,uint256)'),
            addr(from),
            addr(dest),
          ],
          'data': '0x${word(value)}',
        });
        final selector = tx.data.length >= 4
            ? bytesToHex(tx.data.sublist(0, 4))
            : '';
        final amount = tx.data.length == 68
            ? BigInt.parse(
                bytesToHex(tx.data.sublist(36), prefix: false),
                radix: 16,
              )
            : BigInt.zero;
        if (selector == '0x095ea7b3') {
          if (applyApproval && row != null && (bundleStatus ?? receipt) == 'confirmed') row['routerAllowance'] = amount.toString();
          logs.add({
            'address': to,
            'topics': [
              sig('Approval(address,address,uint256)'),
              addr(owner),
              addr(bytesToHex(tx.data.sublist(16, 36))),
            ],
            'data': '0x${word(amount)}',
          });
        } else if (selector == '0xa9059cbb') {
          transfer(owner, bytesToHex(tx.data.sublist(16, 36)), amount);
        } else if (to == activeRouter.toLowerCase()) {
          final previous = before[owner]!, next = wallets[owner]!;
          BigInt delta(String field) =>
              BigInt.parse('${next[field]}') -
              BigInt.parse('${previous[field]}');
          final buy = tx.value > BigInt.zero;
          final sale = settleLiquidations && !buy;
          final settlement = settlementByWallet[owner];
          final proceeds = actualLiquidationOutput ?? BigInt.from(1000);
          final sold = sale ? BigInt.parse(bytesToHex(tx.data.sublist(36, 68), prefix:false), radix:16) : BigInt.zero;
          final input = buy ? tx.value : sale ? (settlement == null ? proceeds : BigInt.zero) : delta('native');
          final output = sale ? sold : delta('tokenBalance').abs();
          if (sale && afterSubmit == null) next['tokenBalance'] = (BigInt.parse('${previous['tokenBalance']}') - sold).toString();
          transfer(buy ? pool : owner, buy ? owner : pool, output);
          if (sale && settlement != null) {
            logs.add({'address':settlement, 'topics':[sig('Transfer(address,address,uint256)'),addr(pool),addr(owner)], 'data':'0x${word(proceeds)}'});
          }
          final gasPaid = BigInt.from(21000) * tx.gasPrice;
          final prior = BigInt.parse('${previous['native']}');
          final after = prior + (buy ? -input : input) - gasPaid;
          traces[hash] = {
            'pre': {owner: {'balance': '0x${prior.toRadixString(16)}'}},
            'post': {owner: {'balance': '0x${after.toRadixString(16)}'}},
          };
        }
        chainReceipts[hash] = {
          ...placement,
          'transactionHash': hash,
          'from': owner,
          'to': to,
          'gasUsed': '0x5208',
          'effectiveGasPrice': '0x${tx.gasPrice.toRadixString(16)}',
          'status': (bundleStatus ?? receipt) == 'reverted' ? '0x0' : '0x1',
          'logs': logs,
        };
      }
      res = {
        'ok': true,
        'result': {'bundleHash': '0x${'ab' * 32}'},
      };
    } else {
      res = {'ok': false, 'code': 'NOT_FOUND', 'message': path};
    }
    return http.Response(
      jsonEncode(res),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  Map<String, Object> _route(
    Map<String, dynamic> r, {
    bool record = true,
    bool checkWallet = true,
    bool bundle = false,
  }) {
    final wallet = (r['wallet'] as String).toLowerCase();
    if (record) {
      routeAmounts.add('${r['amount']}');
      routeBodies.add(r);
    }
    if (checkWallet && refuse.contains(wallet)) {
      return {
        'ok': false,
        'code': 'LIQUIDITY_INSUFFICIENT',
        'message': '流动性不足：价格影响 12.00%，超过 10.00% 上限',
        'retryable': false,
      };
    }
    final buy = r['side'] == 'buy';
    final amount = BigInt.parse(r['amount'] as String);
    final forecast = r['forecastOnly'] == true;
    final allowance = BigInt.parse('${wallets[wallet]?['routerAllowance'] ?? 0}');

    if (!forecast && r['settlementToken'] is String) settlementByWallet[wallet] = r['settlementToken'] as String;
    if (!forecast && r['settlementToken'] == null) settlementByWallet.remove(wallet);
    return {
      'ok': true,
      'plan': {
        if (r['settlementToken'] != null) ...{'settlementToken': r['settlementToken'],'settlementDecimals':tokenMetadata[(r['settlementToken'] as String).toLowerCase()]?['decimals']},
        'wallet': r['wallet'],
        'token': r['token'],
        'amount': r['amount'],
        'side': r['side'],
        'to': activeRouter,
        'quoteScope': 'wallet',
        'chainId': 56,
        'spender': activeSpender ?? activeRouter,
        'slippagePpm': 5000,
        'executed': !forecast,
        'simulation': forecast ? 'forecast' : !buy && allowance < amount ? 'approve_then_swap' : 'uxuy',
        'data': forecast ? '0x' : uxuyCall(wallet, amount, buy),
        'value': buy ? r['amount'] : '0',
        'pools': [pool],
        'source': 'uxuy',
        'dexes': ['PancakeSwap'],
        'quoteOut': '1000',
        'minOut': '995',
        'fee': '0',
        'priceImpactPercent': -0.5,
        'adversePriceImpactPercent': adverseImpact ?? 0.5,
        'deadline': 2000000000,
        'gasLimit': forecast ? 0 : 200000,
        if (r['innerPlatform'] != null && innerQuote != null) ...innerQuote!(r),
      },
    };
  }

  Uint8List _hash(String raw) =>
      hexToBytes(raw).length > 32 ? _keccak(raw) : Uint8List(32);
  Uint8List _keccak(String raw) =>
      Uint8List.fromList(hexToBytes(raw).take(32).toList());
}

class _RecordingClient extends BackendClient {
  _RecordingClient(this.backend)
    : super(Uri.parse('http://backend.test/'), backend.client());
  final FakeBackend backend;

  @override
  SignedTx sign(TradeWallet wallet, LegacyTx tx) {
    final signed = super.sign(wallet, tx);
    backend.signatures[signed.raw] = (
      signed.hash,
      wallet.address.toLowerCase(),
      tx,
    );
    return signed;
  }
}
