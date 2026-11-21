import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/crypto/secp256k1.dart';
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

void main() {
  group('keccak256', () {
    test('known vectors', () {
      expect(
        bytesToHex(keccak256([])),
        '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470',
      );
      expect(
        bytesToHex(keccak256(utf8.encode('abc'))),
        '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45',
      );
      // ERC-20 Transfer topic
      expect(
        bytesToHex(keccak256(utf8.encode('Transfer(address,address,uint256)'))),
        '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
      );
    });

    test('multi-block inputs match foundry cast keccak', () {
      expect(
        bytesToHex(keccak256(utf8.encode('a' * 200))),
        '0x96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d',
      );
      expect(
        bytesToHex(keccak256(Uint8List(136))),
        '0x3a5912a7c5faa06ee4fe906253e339467a9ce87d533c65be3c15cb231cdb25f9',
      );
      expect(
        bytesToHex(keccak256(List.filled(271, 0xab))),
        '0x2f5aefa4b9b8599d9e5e36ee40b60685b156dd004ef0dd01a7abbe6360bb7914',
      );
    });
  });

  group('addresses', () {
    test('private key 1', () {
      final key = toBytes32(BigInt.one);
      expect(
        addressFromPrivateKey(key),
        '0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf',
      );
    });

    test('web3 documentation key', () {
      final key = hexToBytes(
        '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318',
      );
      expect(
        addressFromPrivateKey(key),
        '0x2c7536E3605D9C16a7a3D7b1898e529396a65c23',
      );
    });

    test('EIP-55 checksum vectors', () {
      for (final a in [
        '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359',
        '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB',
        '0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb',
      ]) {
        expect(checksumAddress(a.toLowerCase()), a);
      }
    });
  });

  group('transactions', () {
    test('EIP-155 specification example', () {
      final tx = LegacyTx(
        nonce: 9,
        gasPrice: BigInt.from(20000000000),
        gasLimit: 21000,
        to: '0x3535353535353535353535353535353535353535',
        value: BigInt.parse('1000000000000000000'),
        data: Uint8List(0),
        chainId: 1,
      );
      expect(
        bytesToHex(tx.signingHash()),
        '0xdaf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53',
      );
      final signed = tx.sign(hexToBytes('0x${'46' * 32}'));
      expect(
        signed.raw,
        '0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83',
      );
    });

    test('RLP vectors', () {
      expect(bytesToHex(rlpEncode(Uint8List(0))), '0x80');
      expect(bytesToHex(rlpEncode(0)), '0x80');
      expect(bytesToHex(rlpEncode(15)), '0x0f');
      expect(bytesToHex(rlpEncode(1024)), '0x820400');
      expect(bytesToHex(rlpEncode(<Object>[])), '0xc0');
      expect(
        bytesToHex(rlpEncode(Uint8List.fromList(utf8.encode('dog')))),
        '0x83646f67',
      );
      final lorem = Uint8List.fromList(
        utf8.encode('Lorem ipsum dolor sit amet, consectetur adipisicing elit'),
      );
      expect(bytesToHex(rlpEncode(lorem)).substring(0, 6), '0xb838');
    });

    test('CREATE address (matches cast compute-address)', () {
      expect(
        createAddress('0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf', 0),
        '0xF2E246BB76DF876Cef8b38ae84130F4F55De395b',
      );
      expect(
        createAddress('0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf', 1),
        '0x2946259E0334f33A064106302415aD3391BeD384',
      );
    });

    test('signatures are low-s and deterministic', () {
      final key = hexToBytes('0x${'11' * 32}');
      for (var i = 0; i < 20; i++) {
        final hash = keccak256([i]);
        final a = Secp256k1.sign(hash, bytesToBigInt(key));
        final b = Secp256k1.sign(hash, bytesToBigInt(key));
        expect(a.r, b.r);
        expect(a.s <= Secp256k1.n >> 1, isTrue);
      }
    });
  });

  group('units', () {
    test('parse and format without floating point', () {
      expect(parseUnits('1.25', 18), BigInt.parse('1250000000000000000'));
      expect(parseUnits('0.000001', 6), BigInt.one);
      expect(
        parseUnits('123456789012345678901234567890', 0),
        BigInt.parse('123456789012345678901234567890'),
      );
      expect(() => parseUnits('0.0000001', 6), throwsFormatException);
      expect(() => parseUnits('1e18', 18), throwsFormatException);
      expect(() => parseUnits('-1', 18), throwsFormatException);
      expect(formatUnits(BigInt.parse('1250000000000000000'), 18), '1.25');
      expect(formatUnits(BigInt.parse('1000000000000000000'), 18), '1');
      expect(formatUnits(BigInt.from(123456789), 8, maxFraction: 4), '1.2345');
    });

    test('ABI encodings', () {
      final data = erc20Approve(
        '0x00000000000000000000000000000000000c0de1',
        maxUint256,
      );
      expect(
        bytesToHex(data),
        '0x095ea7b3${'0' * 24}00000000000000000000000000000000000c0de1${'f' * 64}',
      );
      expect(
        erc20Transfer(
          '0x00000000000000000000000000000000000a11ce',
          BigInt.one,
        ).length,
        68,
      );
    });
  });

  test('personal_sign matches cast wallet sign', () {
    final w = TradeWallet.import('k', '0x${'1'.padLeft(64, '0')}');
    expect(
      w.signMessage('You are sign in Meme 123456'),
      '0xa62a7546c90c32f29f54e85e1f3d6c01739c9b4d0470b09b5388aab3133f83de72cd6cf69e9a94414d322be58f03bee9e7d405579a3859d3aac0627d9ba20e7c1c',
    );
  });

  test('CREATE2 and PancakeSwap V2 pair addresses match cast and the chain', () {
    expect(
      create2Address(
        pancakeV2Factory,
        toBytes32(BigInt.one),
        hexToBytes(
          '0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5',
        ),
      ),
      '0xdDe573E3bfB3b9e05644464FAC91823F68fa99b7',
    );
    // Four token migrated on BSC (LiquidityAdded in tx 0x72369e…): its WBNB pair.
    expect(
      pancakeV2Pair(
        '0x523c2657d8a632b9238f9ddeca9a290ee4e4ffff',
        '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
      ),
      '0x4EE4888e7f5e1Ee9162713d09EF1A33817281Bfd',
    );
  });
}
