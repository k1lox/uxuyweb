"""Offline route-selection checks for the execution and migration evidence runners."""

import copy
import subprocess
import unittest

from uxuy_quote_evidence import ROUTER, WBNB, gateway_error, select_quote
from uxuy_readonly_gateway import TRADE_ABI


class QuoteEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        zero = "0x" + "00" * 20
        token = "0x" + "ab" * 20
        wallet = "0x" + "12" * 20
        cls.native = zero
        cls.request = {"orderId": "123", "amountIn": "1", "decimals": 1, "receiver": wallet,
                       "tokenIn": zero, "tokenOut": token, "slippage": 5000, "withTx": False}
        trade = (f"(10,[({token},{token},[{WBNB},{token}],1,0x)],"
                 f"({zero},{zero},{zero},0,{zero},0,0x),{wallet},{zero},0,[],9999999,123)")
        data = subprocess.check_output(["cast", "calldata", TRADE_ABI, trade], text=True).strip()
        cls.row = {"id": 789, "amount": "1000", "minAmount": "995", "slippage": 5000,
                   "paths": [{"chainId": 56, "token": WBNB}, {"chainId": 56, "token": token}],
                   "pairs": [{"pools": [{"in": "10"}]}],
                   "calldata": {"to": ROUTER, "value": "10", "executed": False, "error": "", "data": data}}

    def test_checked_alternative_can_win_without_a_top_level_order_id(self):
        tampered = dict(self.row, orderId="789", amount="2000", minAmount="1990")
        invalid_minimum = dict(self.row, minAmount="994")
        result, checks = select_quote([tampered, invalid_minimum, self.row], self.request, 10, self.native)
        self.assertIs(result, self.row)
        self.assertEqual(checks["selectedIndex"], 2)
        self.assertFalse(checks["rowOrderIdEchoed"])
        self.assertEqual(checks["calldataOrderId"], "123")
        self.assertEqual([e["error"] for e in checks["rejected"]], ["UXUY_ORDER_MISMATCH", "UXUY_INVALID_MINIMUM"])

    def test_invalid_input_chain_target_and_native_value_each_fail_closed(self):
        for field, value, error in [
            (("pairs", 0, "pools", 0, "in"), "11", "UXUY_AMOUNT_MISMATCH"),
            (("paths", 0, "chainId"), 1, "UXUY_PATH_MISMATCH"),
            (("calldata", "to"), WBNB, "UXUY_TARGET_OR_VALUE_MISMATCH"),
            (("calldata", "value"), "0", "UXUY_TARGET_OR_VALUE_MISMATCH"),
            (("calldata", "executed"), True, "UXUY_PREFLIGHT_FAILED"),
            (("calldata", "data"), "0x5103aafa", "UXUY_TRADE_CALLDATA_INVALID"),
            (("amount",), str(2**256), "UXUY_INVALID_INTEGER"),
        ]:
            with self.subTest(field=field):
                row = copy.deepcopy(self.row)
                target = row
                for key in field[:-1]:
                    target = target[key]
                target[field[-1]] = value
                result, checks = select_quote([row], self.request, 10, self.native)
                self.assertIsNone(result)
                self.assertEqual(checks["rejected"], [{"index": 0, "error": error}])

    def test_errors_persist_only_known_classes_or_exact_numeric_gateway_codes(self):
        self.assertEqual(gateway_error(RuntimeError("UXUY RPC -32000")), "UXUY RPC -32000")
        self.assertEqual(gateway_error(RuntimeError("UXUY HTTP 401")), "UXUY HTTP 401")
        self.assertEqual(gateway_error(RuntimeError("UXUY RPC -32000 token=secret")), "RuntimeError")
