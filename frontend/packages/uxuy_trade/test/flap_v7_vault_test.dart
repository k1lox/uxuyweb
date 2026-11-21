import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/api/backend_client.dart' show LaunchImage;
import 'package:uxuy_trade/src/evm/evm.dart';
import 'package:uxuy_trade/src/exec/flap_vault.dart';
import 'package:uxuy_trade/src/exec/flap_vault_adapters.dart';
import 'package:uxuy_trade/src/exec/launch.dart';
import 'package:uxuy_trade/src/exec/market.dart';

const sender = '0x1111111111111111111111111111111111111111';
const salt =
    '0xc08c541f8f56e943b0a8f5a93cec70dfa113ee6df7c00b81c8bcbbae3c1ff129';
const block = 134429290;
const cid = 'bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

FlapLaunchForm draft(String factory, {String quote = zeroAddress}) {
  final info = FlapVaultInfo(
    factory: factory,
    quoteToken: quote,
    schema: FlapVaultSchema(
      fields: [FlapVaultField(name: 'xHandle', type: 'string')],
    ),
  );
  return FlapLaunchForm(
    name: 'Fork Check',
    symbol: 'FORK',
    payment: FlapPayment({'address': quote, 'decimals': 18, 'symbol': 'Q'}),
    nonTax: true,
    vault: buildFlapCuratedSelection(
      info: info,
      rows: [
        {'xHandle': '@UxuyReadTest'},
      ],
    ),
    image: LaunchImage([1], 'test.png', 'image/png'),
  );
}

Uint8List calldata(FlapLaunchForm form) => encodeFlapVaultCreation(
  form,
  creator: sender,
  cid: cid,
  salt: hexToBytes(salt),
  extensionId: '0x${'00' * 32}',
  extensionData: Uint8List(0),
);

void main() {
  test('V7 VaultPortal uses its deployed ABI, zero tax, one vault slot and Gift data', () {
    final form = draft(flapV7GiftFactory);
    form.validate();
    validateFlapCuratedLaunch(
      form.vault!,
      form.vaultContext(sender),
      quoteSymbol: 'BNB',
    );
    final encoded = calldata(form);
    final args = flapV7WithVault.decodeInput(encoded).single as List;
    expect(bytesToHex(flapV7WithVault.selector), '0x3d2fc388');
    expect(args[5], BigInt.from(3));
    expect(args[11], BigInt.from(7));
    expect(args[13], BigInt.from(30 * 86400));
    expect(args.sublist(14, 17), List.filled(3, BigInt.zero));
    expect(args[17], zeroAddress);
    expect((args[18] as List).first, [
      BigInt.one,
      BigInt.from(10000),
      sender,
      zeroAddress,
      BigInt.zero,
    ]);
    for (final slot in (args[18] as List).skip(1)) {
      expect(slot, [
        BigInt.zero,
        BigInt.zero,
        zeroAddress,
        zeroAddress,
        BigInt.zero,
      ]);
    }
    expect((args[19] as String).toLowerCase(), flapV7GiftFactory.toLowerCase());
    expect(args[20], form.vault!.encode());
    expect(form.vault!.rows.single['xHandle'], 'uxuyreadtest');
  });

  test(
    'V7 Vault rejects stock quotes and unlisted factories before submission',
    () {
      expect(
        () => draft(flapV7GiftFactory, quote: sender).validate(),
        throwsFormatException,
      );
      expect(() => draft(sender).validate(), throwsFormatException);
    },
  );

  final endpoint = Platform.environment['UXUY_FLAP_V7_FORK'];
  test(
    'pinned BSC fork rejects both documented V7 Gift factories with rule 8',
    () async {
      final url = Uri.parse(endpoint!);
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<Map> rpc(String method, List<Object?> params) async {
        final req = await client.postUrl(url);
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        );
        return jsonDecode(await utf8.decoder.bind(await req.close()).join())
            as Map;
      }

      final node = (await rpc('anvil_nodeInfo', []))['result'] as Map;
      expect(node['forkConfig']['forkBlockNumber'], block);
      for (final factory in [flapV7GiftFactory, flapV7LegacyGiftFactory]) {
        final response = await rpc('eth_call', [
          {
            'from': sender,
            'to': flapVaultPortal,
            'data': bytesToHex(calldata(draft(factory))),
          },
          '0x${block.toRadixString(16)}',
        ]);
        expect(
          response['error']['data'],
          '0x16fba6af${'8'.padLeft(64, '0')}',
          reason: factory,
        );
      }
    },
    skip: endpoint == null
        ? 'Set UXUY_FLAP_V7_FORK to a local Anvil fork at block $block.'
        : false,
  );
}
