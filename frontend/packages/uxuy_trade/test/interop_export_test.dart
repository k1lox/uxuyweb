@Tags(['interop'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

/// Keep the Dart signer in sync with the fixtures consumed by the Rust backend.
void main() {
  test('Dart-signed BSC transactions match the backend fixture', () {
    const router = '0x00000000000000000000000000000000000C0dE1';
    final w = TradeWallet.import('interop', '0x${'7'.padLeft(64, '0')}');
    // buy(address,uint256,uint256,address[]) with one pool
    final buy = hexToBytes(
      '0x'
      '${_sel('buy(address,uint256,uint256,address[])')}'
      '${'0e09fabb73bd3ade0a17ecc321fd13a19e81ce82'.padLeft(64, '0')}'
      '${'1'.padLeft(64, '0')}'
      '${'ffff'.padLeft(64, '0')}'
      '${'80'.padLeft(64, '0')}'
      '${'1'.padLeft(64, '0')}'
      '${'16b9a82891338f9ba80e2d6970fdda79d1eb0dae'.padLeft(64, '0')}',
    );
    final txs = {
      'sender': w.address,
      'buy': w
          .sign(
            LegacyTx(
              nonce: 1,
              gasPrice: BigInt.from(50000000),
              gasLimit: 200000,
              to: router,
              value: BigInt.from(10).pow(16),
              data: buy,
            ),
          )
          .raw,
      'approve': w
          .sign(
            LegacyTx(
              nonce: 2,
              gasPrice: BigInt.from(50000000),
              gasLimit: 70000,
              to: '0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82',
              value: BigInt.zero,
              data: erc20Approve(router, maxUint256),
            ),
          )
          .raw,
      'native': w
          .sign(
            LegacyTx(
              nonce: 3,
              gasPrice: BigInt.from(50000000),
              gasLimit: 21000,
              to: '0x00000000000000000000000000000000000A11cE',
              value: BigInt.one,
              data: Uint8List(0),
            ),
          )
          .raw,
    };
    final fixture = File('../../../backend/app/tests/fixtures/dart-signed.json');
    expect(txs, jsonDecode(fixture.readAsStringSync()));
  });
}

String _sel(String sig) =>
    bytesToHex(keccak256(utf8.encode(sig)).sublist(0, 4), prefix: false);
