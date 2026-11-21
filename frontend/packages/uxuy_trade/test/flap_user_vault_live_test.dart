@Tags(['fork'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uxuy_trade/src/api/backend_client.dart';
import 'package:uxuy_trade/src/evm/abi.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';

/// Opt-in public READ-ONLY regression for the user-supplied standard StockVault.
/// This client rejects every RPC write method and all backend bundle submissions.
class PublicReadBackend extends BackendClient {
  PublicReadBackend(this.rpcEndpoint)
    : super(Uri.parse('http://unused.invalid'), http.Client());
  final Uri rpcEndpoint;
  @override
  Future<List<Object?>> rpc(List<(String, List<Object?>)> calls) async {
    final output = <Object?>[];
    for (final (method, params) in calls) {
      if (!{
        'eth_call',
        'eth_getCode',
        'eth_blockNumber',
        'eth_chainId',
      }.contains(method)) {
        throw StateError('Read-only RPC required');
      }
      final r = await http_
          .post(
            rpcEndpoint,
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': method,
              'params': params,
            }),
          )
          .timeout(const Duration(seconds: 25));
      final body = jsonDecode(r.body) as Map;
      if (body['error'] != null)
        throw BackendException(
          'RPC_ERROR',
          '${body['error']['message']}',
          false,
        );
      output.add(body['result']);
    }
    return output;
  }

  @override
  Future<Map<String, dynamic>> bundle(List<String> raws, int block) =>
      throw StateError('No broadcast');
}

void main() {
  const factory = '0x889C64Ba9fe1A0E371EDe0579098E0bd71135232';
  const creator = '0x1111111111111111111111111111111111111111';
  const bncb = '0x4902c5ebc598265ed2212b559b042de8a5eeec3f';
  final rpc = Platform.environment['UXUY_FLAP_READONLY_RPC'];
  test(
    'standard custom Factory reads, validates and creates through our encoder (read only)',
    () async {
      final api = PublicReadBackend(Uri.parse(rpc!));
      final service = FlapVaultService(api);
      final results = <Map<String, Object?>>[];
      try {
        expect((await api.rpc([('eth_chainId', [])])).single, '0x38');
        final implFn = AbiFunction.parse(
          'TOKEN_IMPL_TAXED_V3() returns (address)',
        );
        final implementation =
            implFn
                    .decodeOutput(
                      await api.call(flapVaultPortal, implFn.encodeHex([])),
                    )
                    .single
                as String;
        final (salt, expected) = await findFlapSalt(
          implementation,
          '7777',
          (address) async =>
              (await api.rpc([('eth_getCode', [address, 'latest'])])).single == '0x',
          random: Random(20261116),
        );
        for (final quote in [zeroAddress, bncb]) {
          final info = await service.read(factory, quoteToken: quote);
          expect(info.schema.fields.length, 9);
          expect(info.permission, 0);
          final row = <String, String>{
            'creatorWallet': creator,
            'creatorBps': '3300',
            'ownBurnBps': '6600',
            'thirdBurnBps': '0',
            'fissionBps': '100',
            'burnToken': zeroAddress,
            'intervalSeconds': '10',
            'spendBps': '100',
            'fissionRecipients': '10',
          };
          final selection = FlapVaultSelection(info: info, rows: [row]);
          final context = FlapVaultLaunchContext(
            creator: creator,
            quoteToken: quote,
            tokenVersion: 6,
            buyTaxBps: 300,
            sellTaxBps: 300,
            vaultBps: 10000,
            burnBps: 0,
            dividendBps: 0,
            liquidityBps: 0,
            dividendToken: quote,
            minimumShare: BigInt.zero,
          );
          await service.revalidate(selection, context);
          for (final invalid in [false, true]) {
            final chosen = FlapVaultSelection(
              info: info,
              rows: [
                {...row, if (invalid) 'ownBurnBps': '6500'},
              ],
            );
            final form = FlapLaunchForm(
              nonTax: false,
              name: 'Read only alignment',
              symbol: 'CHECK',
              payment: FlapPayment({
                'address': quote,
                'symbol': quote == zeroAddress ? 'BNB' : 'BNCB',
                'decimals': 18,
              }),
              buyTaxBps: 300,
              sellTaxBps: 300,
              marketingBps: 10000,
              vault: chosen,
              image: LaunchImage([1], 'mock.png', 'image/png'),
            );
            form.validate();
            final data = encodeFlapVaultCreation(
              form,
              cid:
                  'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              salt: salt,
              extensionId: '0x${'00' * 32}',
              extensionData: Uint8List(0),
            );
            final call = api.rpc([
              (
                'eth_call',
                [
                  {
                    'from': creator,
                    'to': flapVaultPortal,
                    'data': bytesToHex(data),
                    'gas': '0x1c9c380',
                  },
                  'latest',
                ],
              ),
            ]);
            if (invalid) {
              await expectLater(
                call,
                throwsA(
                  isA<BackendException>().having(
                    (e) => e.message,
                    'reason',
                    contains('Shares must total 100%'),
                  ),
                ),
              );
            } else {
              final result = (await call).single as String;
              expect(flapV6WithVault.decodeOutput(result).single, expected);
            }
            results.add({
              'quote': quote,
              'invalidShares': invalid,
              'expectedOutcomeVerified': true,
              'predictedToken': expected,
            });
          }
        }
        expect(
          (await api.rpc([
            ('eth_getCode', [expected, 'latest']),
          ])).single,
          '0x',
        );
        final report = Platform.environment['UXUY_FLAP_VAULT_REPORT'];
        if (report != null) {
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'readOnly': true,
              'broadcast': false,
              'factory': factory,
              'cases': results,
            }),
          );
        }
      } finally {
        api.http_.close();
      }
    },
    skip: rpc == null ? 'set UXUY_FLAP_READONLY_RPC to a BSC RPC endpoint' : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
