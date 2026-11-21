import 'package:uxuy_trade/src/crypto/keccak.dart';
import 'package:uxuy_trade/src/evm/evm.dart';

Map<String, dynamic> purchaseTransfer(
  String token,
  String dev, {
  int amount = 1234,
}) => {
  'address': token,
  'topics': [
    bytesToHex(keccak256('Transfer(address,address,uint256)'.codeUnits)),
    '0x${'0' * 64}',
    '0x${dev.substring(2).toLowerCase().padLeft(64, '0')}',
  ],
  'data': '0x${amount.toRadixString(16).padLeft(64, '0')}',
};

Map<String, dynamic> launchReceipt(
  String hash,
  int index,
  List<Map<String, dynamic>> logs,
) => {
  'transactionHash': hash,
  'transactionIndex': '0x${index.toRadixString(16)}',
  'blockNumber': '0x1234',
  'blockHash': '0x${'12' * 32}',
  'status': '0x1',
  'logs': logs,
};
