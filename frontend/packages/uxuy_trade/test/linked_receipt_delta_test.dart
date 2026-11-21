import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/evm.dart';

const _external = '0x00000000000000000000000000000000000000a1';
const _owner = '0x00000000000000000000000000000000000000a5';
const _token = '0x00000000000000000000000000000000000000a6';
const _pool = '0x00000000000000000000000000000000000000a7';
String _hash(int n) => '0x${n.toRadixString(16).padLeft(64, '0')}';
String _quantity(int n) => '0x${n.toRadixString(16)}';
String _addressTopic(String address) =>
    '0x${address.substring(2).padLeft(64, '0')}';

Map<String, Object> _log(
  String emitter,
  String event,
  List<String> indexed,
  List<int> data,
) => {
  'address': emitter,
  'topics': [bytesToHex(keccak256(event.codeUnits)), ...indexed],
  'data': '0x${data.map((n) => _hash(n).substring(2)).join()}',
};

Map<String, Object> _transfer(bool buy, int amount) => _log(
  _token,
  'Transfer(address,address,uint256)',
  [_addressTopic(buy ? _pool : _owner), _addressTopic(buy ? _owner : _pool)],
  [amount],
);

// The transaction and its receipt are identified separately to exercise a
// misbehaving RPC returning a different hash under the requested lookup.
class _Chain {
  final receipts = <String, Map<String, dynamic>>{};
  final statuses = <String, String>{};
  final traces = <String, Map<String, dynamic>>{};
  final traced = <String>[];
  final receiptErrors = <String>{};
  final walletQueries = <String>[];
  int walletSnapshot = 0;

  Map<String, dynamic> receipt(
    String hash,
    String router,
    List<Map<String, Object>> logs,
  ) {
    statuses[hash] = 'confirmed';
    return receipts[hash] = {
      'transactionHash': hash,
      'blockHash': _hash(9000),
      'blockNumber': '0x123',
      'transactionIndex': '0x1',
      'from': _owner,
      'to': router,
      'status': '0x1',
      'effectiveGasPrice': '0x2',
      'gasUsed': '0x5208',
      'logs': logs,
    };
  }

  Future<BackendClient> connect() async {
    final api = BackendClient(
      Uri.parse('http://fixture.test/'),
      MockClient((req) async {
        final path = req.url.path;
        http.Response result(Object? value) =>
            http.Response(jsonEncode(value), 200);
        if (path.endsWith('/config')) {
          return result({
            'ok': true,
            'router': _external,
            'approvalSpender': _external,
            'routeEnabled': true,
            'routeSource': 'uxuy',
            'maxPriceImpactPercent': 10,
          });
        }
        if (path.contains('/transactions/bsc/')) {
          final hash = req.url.pathSegments.last;
          return result({
            'ok': true,
            'result': {
              'transactionHash': hash,
              'status': statuses[hash] ?? 'ambiguous',
              'receipt': receipts[hash],
            },
          });
        }
        if (path.endsWith('/wallets/state')) {
          walletQueries.add(path);
          return result({
            'ok': true,
            'wallets': [
              {
                'wallet': _owner,
                'native': '$walletSnapshot',
                'nonce': 99,
                'tokenBalance': '123456',
                'routerAllowance': '999999',
              },
            ],
          });
        }
        expect(path, endsWith('/rpc/bsc'));
        final responses = <Map<String, dynamic>>[];
        for (final call in jsonDecode(req.body) as List) {
          final hash = call['params'][0] as String;
          final envelope = <String, dynamic>{
            'jsonrpc': '2.0',
            'id': call['id'],
          };
          switch (call['method']) {
            case 'eth_getTransactionReceipt':
              if (receiptErrors.contains(hash)) {
                envelope['error'] = {
                  'code': -32000,
                  'message': 'receipt unavailable',
                };
              } else {
                envelope['result'] = receipts[hash];
              }
            case 'debug_traceTransaction':
              final options = call['params'][1] as Map;
              expect(options['tracer'], 'prestateTracer');
              expect(options['tracerConfig']['diffMode'], true);
              traced.add(hash);
              envelope['result'] = traces[hash];
            default:
              fail('Unexpected RPC call ${call['method']}');
          }
          responses.add(envelope);
        }
        return result(responses.reversed.toList());
      }),
    );
    await api.config();
    return api;
  }
}

void main() {
  late _Chain chain;
  late BackendClient api;
  final hash = _hash(1);
  setUp(() async {
    chain = _Chain();
    api = await chain.connect();
  });

  void trace(String hash, int principal) {
    const before = 1000000;
    chain.traces[hash] = {
      'pre': {
        _owner: {'balance': _quantity(before)},
      },
      'post': {
        _owner: {'balance': _quantity(before + principal - 42000)},
      },
    };
  }

  for (final buy in [false, true]) {
    test(
      'UXUY verifies net tokens and transaction-specific BNB excluding gas (buy=$buy)',
      () async {
        chain.receipt(hash, _external, [
          _transfer(buy, 370),
          _transfer(!buy, 25),
        ]);
        trace(hash, buy ? -125000 : 125000);
        expect(await api.linkedTradeDelta([hash], token: _token, buy: buy), (
          native: BigInt.from(125000),
          tokens: BigInt.from(345),
        ));
        expect(chain.walletQueries, isEmpty);
      },
    );
  }

  test(
    'an unavailable trace cannot be converted into a zero or estimate',
    () async {
      chain.receipt(hash, _external, [_transfer(false, 20)]);
      await expectLater(
        api.linkedTradeDelta([hash], token: _token, buy: false),
        throwsException,
      );
      expect(chain.traced, [hash]);
    },
  );

  for (final mismatch in ['removed', 'transactionHash', 'blockHash']) {
    test('withdrawn or unrelated $mismatch log cannot fund the next linked leg', () async {
      final log = _transfer(false, 5);
      log[mismatch] = mismatch == 'removed' ? true : _hash(999);
      chain.receipt(hash, _external, [log])['blockHash'] = _hash(700);
      trace(hash, 200);
      await expectLater(api.linkedTradeDelta([hash], token: _token, buy: false), throwsException);
      expect(chain.traced, isEmpty);
    });
  }

  for (final failure in ['missing', 'wrong hash', 'RPC error']) {
    test('receipt $failure keeps the original leg unsettled', () async {
      final receipt = chain.receipt(hash, _external, [_transfer(false, 5)]);
      if (failure == 'missing') chain.receipts.remove(hash);
      if (failure == 'wrong hash') receipt['transactionHash'] = _hash(999);
      if (failure == 'RPC error') chain.receiptErrors.add(hash);
      await expectLater(
        api.linkedTradeDelta([hash], token: _token, buy: false),
        throwsException,
      );
    });
  }

  test('a partial batch cannot settle and duplicate hashes count only once on recovery', () async {
    chain.receipt(hash, _external, [_transfer(false, 5)]);
    trace(hash, 100);
    final second = _hash(2);
    final original = [hash, second, hash];
    await expectLater(
      api.linkedTradeDelta(original, token: _token, buy: false),
      throwsException,
    );
    chain.receipt(second, _external, [_transfer(false, 7)]);
    trace(second, 150);
    expect(await api.linkedTradeDelta(original, token: _token, buy: false), (
      native: BigInt.from(250),
      tokens: BigInt.from(12),
    ));
  });

  for (final mismatch in ['emitter', 'owner', 'token', 'direction']) {
    test('an event with the wrong $mismatch cannot prove the trade', () async {
      chain.receipt(hash, mismatch == 'emitter' ? _pool : _external, [
        _log(
          mismatch == 'token' ? _pool : _token,
          'Transfer(address,address,uint256)',
          [
            _addressTopic(
              mismatch == 'owner' || mismatch == 'direction' ? _pool : _owner,
            ),
            _addressTopic(mismatch == 'direction' ? _owner : _pool),
          ],
          [30],
        ),
      ]);
      trace(hash, 200);
      await expectLater(
        api.linkedTradeDelta([hash], token: _token, buy: false),
        throwsException,
      );
    });
  }

  test(
    'on-chain revert and definitively excluded hash add no traded amount',
    () async {
      chain.receipt(hash, _external, [])['status'] = '0x0';
      chain.statuses[hash] = 'reverted';
      chain.statuses[_hash(2)] = 'not_included';
      expect(
        await api.linkedTradeDelta([hash, _hash(2)], token: _token, buy: false),
        (native: BigInt.zero, tokens: BigInt.zero),
      );
      expect(chain.traced, isEmpty);
    },
  );
}
