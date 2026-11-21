import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uxuy_trade/src/state/app_state.dart';
import 'package:uxuy_trade/src/ui/launch_page.dart';
import 'package:uxuy_trade/src/wallet/wallet.dart';

import 'support/fake_backend.dart';

TradeWallet _wallet(int i) =>
    TradeWallet.import('fixture', i.toRadixString(16).padLeft(64, '0'));

String _botai(
  String purpose,
  List<TradeWallet> wallets, {
  List<String>? recipients,
}) => [
  'Botai 私钥备份 v1',
  '时间：2026-11-01T00:00:00Z',
  '链：BSC',
  '用途：$purpose',
  '数量：${wallets.length}',
  '请保管此文件。持有私钥即可控制对应地址的资产。',
  '',
  if (recipients == null) '地址\t私钥' else '接收地址\t中转地址\t中转私钥',
  for (var i = 0; i < wallets.length; i++)
    [
      if (recipients != null) recipients[i],
      wallets[i].address,
      wallets[i].exportPrivateKey(),
    ].join('\t'),
].join('\r\n');

String _json(
  TradeWallet w, {
  String category = 'tool-generated',
  String scope = '',
  String? to,
}) => jsonEncode({
  'format': 'uagent-wallet-backup-v1',
  'category': category,
  'scope': scope,
  'address': w.address,
  'privateKey': w.exportPrivateKey(),
  'relatedAddress': to,
});

Map<String, Object?> _use(String category, {String scope = '', String? to}) => {
  'category': category,
  'scope': scope,
  'relatedAddress': to,
};
Map<String, Object?> _entry(TradeWallet w, List<Map<String, Object?>> uses) => {
  'address': w.address,
  'privateKey': w.exportPrivateKey(),
  'purpose': '首次登记的用途',
  'usages': uses,
};
String _archive(List<Map<String, Object?>> entries) =>
    jsonEncode({'format': 'uagent-wallet-backup-v2', 'wallets': entries});

void main() {
  test('restoring a generated wallet verifies the address before unlocking it', () {
    final wallet = _wallet(1);
    final key = wallet.exportPrivateKey();
    final restored = TradeWallet.restoreGenerated('N1', key, wallet.address.toLowerCase());
    expect(restored.address, wallet.address);
    expect(restored.generated, isTrue);
    expect(restored.backedUp, isTrue);
    expect(
      () => TradeWallet.restoreGenerated('N1', key, _wallet(2).address),
      throwsFormatException,
    );
  });

  final a = _wallet(1), b = _wallet(2), r = _wallet(3), s = _wallet(4);
  test('complete BotAI and UXUY wallet files import and verify printed addresses and counts', () {
    final txt = _botai('主动生成', [a, b]);
    final wallets = parsePrivateKeys('\uFEFF$txt', existing: {}, startIndex: 0);
    expect(wallets.map((w) => w.address), [a.address, b.address]);
    expect(parseBuyers(_json(a), '2', 2).single.amount, BigInt.from(200));
    for (final input in [
      txt.replaceFirst(a.address, b.address),
      txt.replaceFirst('数量：2', '数量：1'),
      txt.replaceFirst('链：BSC', '链：Arc'),
      _json(a).replaceFirst(a.address, b.address),
      '${b.address},${a.exportPrivateKey()}',
    ]) {
      expect(
        () => parsePrivateKeys(input, existing: {}, startIndex: 0),
        throwsFormatException,
      );
    }
  });

  test('combined JSON restores only the selected use and scope, separately from its original purpose', () {
    const firstGroup = (category: 'trade-group', scope: '01');
    const secondGroup = (category: 'trade-group', scope: '02');
    const generated = (category: 'tool-generated', scope: '');
    final archive = _archive([
      _entry(a, [_use('trade-group', scope: '01'), _use('tool-generated')]),
      _entry(b, [_use('trade-group', scope: '02')]),
      _entry(r, [_use('distribution-transit', to: a.address)]),
    ]);
    for (final (group, w) in [
      (firstGroup, a),
      (secondGroup, b),
      (generated, a),
    ]) {
      expect(ordinaryWalletInput(archive, target: group), w.exportPrivateKey());
    }
    for (final target in [null, (category: 'launch-dev', scope: 'Flap')]) {
      expect(
        () => ordinaryWalletInput(archive, target: target),
        throwsA(
          isA<BackupUsageSelectionRequired>().having(
            (e) => e.groups,
            'ordinary options',
            unorderedEquals([firstGroup, secondGroup, generated]),
          ),
        ),
      );
    }
    expect(
      () => ordinaryWalletInput(
        archive,
        target: (category: 'distribution-transit', scope: ''),
      ),
      throwsFormatException,
    );
    expect(
      () => ordinaryWalletInput(
        _archive([
          _entry(a, [_use('tool-generated')])
            ..['privateKey'] = b.exportPrivateKey(),
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => ordinaryWalletInput(
        _archive([
          _entry(a, [_use('tool-generated', to: r.address)]),
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => ordinaryWalletInput(
        _archive([
          _entry(r, [_use('distribution-transit', to: a.address)]),
        ]),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'help',
          contains('恢复中转备份'),
        ),
      ),
    );
  });

  test('combined transit restore selects current group and independently checked recipients', () async {
    final api = FakeBackend(), state = AppState(api.api(), MemoryKeyStore());
    addTearDown(state.dispose);
    final group = state.addLinkedGroup();
    final json = _archive([
      _entry(a, [_use('tool-generated')]),
      _entry(r, [
        _use('distribution-transit', to: a.address),
        _use('linked-transit', scope: group.name, to: b.address),
      ]),
      _entry(s, [
        _use('distribution-transit', to: b.address),
        _use('linked-transit', scope: '其他组', to: b.address),
      ]),
    ]);
    await expectLater(
      state.restoreTransits(json, '${a.address}\n${s.address}'),
      throwsFormatException,
    );
    await expectLater(
      state.restoreTransits(json, a.address, group: group),
      throwsFormatException,
    );
    expect(state.distributionTransits, isEmpty);
    expect(group.transitByBuyer, isEmpty);
    expect(await state.restoreTransits(json, a.address), 1);
    expect(state.distributionTransits.keys, [a.address.toLowerCase()]);
    expect(state.distributionTransits.values.single.address, r.address);
    expect(await state.restoreTransits(json, b.address, group: group), 1);
    expect(group.transitByBuyer.values.single.address, r.address);
    expect(api.submitted, isEmpty);
    expect(api.bundles, isEmpty);
  });

  test('restore validates recipient, purpose, group, address, and existing pairs without partial overwrite', () async {
    final api = FakeBackend(), state = AppState(api.api(), MemoryKeyStore());
    addTearDown(state.dispose);
    final txt = _botai('分发中转', [r, s], recipients: [a.address, b.address]);
    expect(
      () => ordinaryWalletInput(txt),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'help',
          contains('恢复中转备份'),
        ),
      ),
    );
    await expectLater(
      state.restoreTransits(txt, a.address),
      throwsFormatException,
    );
    await expectLater(
      state.restoreTransits(txt, '${a.address}\n${r.address}'),
      throwsFormatException,
    );
    expect(state.distributionTransits, isEmpty);
    final one = _json(s, category: 'distribution-transit', to: b.address);
    await state.restoreTransits(one, b.address);
    final conflict = _botai('分发中转', [s, r], recipients: [a.address, b.address]);
    await expectLater(
      state.restoreTransits(conflict, '${a.address}\n${b.address}'),
      throwsStateError,
    );
    expect(state.distributionTransits.keys, [b.address.toLowerCase()]);
    await state.restoreTransits(txt, '${a.address}\n${b.address}');
    expect(
      (await state.transitsFor([a.address]))[a.address.toLowerCase()]?.address,
      r.address,
    );
    expect((await state.restoreTransits(one, b.address)), 1);
    final g = state.addLinkedGroup();
    final linked = _botai(
      '关联组中转 · 组 ${g.number}',
      [r],
      recipients: [a.address],
    );
    await expectLater(
      state.restoreTransits(txt, '${a.address}\n${b.address}', group: g),
      throwsFormatException,
    );
    await expectLater(
      state.restoreTransits(
        linked.replaceFirst('组 ${g.number}', '组 999'),
        a.address,
        group: g,
      ),
      throwsFormatException,
    );
    await state.restoreTransits(linked, a.address, group: g);
    await state.setLinkedKeys(g, sellers: false, text: a.exportPrivateKey());
    expect(g.transits.single.address, r.address);
    expect(api.submitted, isEmpty);
    expect(api.bundles, isEmpty);
  });
}
