"""Validate live BSC quote candidates before using them in the read-only simulations."""

import re

from uxuy_readonly_gateway import verify_trade_calldata

ROUTER = "0x7b458dbe4e7a693be2e691deddff4607104f1266"
WBNB = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"
PPM = 1_000_000


def gateway_error(error):
    message = str(error)
    if re.fullmatch(r"UXUY (?:HTTP [0-9]{3}|RPC -?[0-9]{1,12})", message):
        return message
    if re.fullmatch(r"UXUY_[A-Z0-9_]{1,80}", message):
        return message
    return type(error).__name__


def unsigned(value):
    if type(value) not in (str, int) or not re.fullmatch(r"[0-9]{1,78}", str(value)):
        raise ValueError("UXUY_INVALID_INTEGER")
    n = int(value)
    if n >= 2**256:
        raise ValueError("UXUY_INVALID_INTEGER")
    return n


def select_quote(rows, request, atoms, native):
    """Return the best candidate that satisfies the wallet's request and configured BSC router."""
    valid = []
    rejected = []
    native = native.lower()
    token_in = request["tokenIn"].lower()
    token_out = request["tokenOut"].lower()
    expected_value = atoms if token_in == native else 0
    for index, row in enumerate(rows):
        try:
            proof = verify_trade_calldata(row, request)
            if int(proof["amountIn"]) != atoms:
                raise ValueError("UXUY_AMOUNT_MISMATCH")
            call = row["calldata"]
            if call["to"].lower() != ROUTER or unsigned(call["value"]) != expected_value:
                raise ValueError("UXUY_TARGET_OR_VALUE_MISMATCH")
            if call.get("error") != "" or call.get("executed") is not request["withTx"]:
                raise ValueError("UXUY_PREFLIGHT_FAILED")
            path = row["paths"]
            if not 2 <= len(path) <= 17 or any(h["chainId"] != 56 for h in path):
                raise ValueError("UXUY_PATH_MISMATCH")
            for hop, requested in [(path[0], token_in), (path[-1], token_out)]:
                asset = hop["token"].lower()
                if asset != requested and not (requested == native and asset == WBNB):
                    raise ValueError("UXUY_PATH_MISMATCH")
            pairs = row["pairs"]
            if len(pairs) != len(path) - 1 or sum(unsigned(p["in"]) for p in pairs[0]["pools"]) != atoms:
                raise ValueError("UXUY_AMOUNT_MISMATCH")
            output = unsigned(row["amount"])
            minimum = unsigned(row["minAmount"])
            slip = unsigned(row["slippage"])
            if not (0 < minimum <= output
                    and slip <= min(request["slippage"], PPM)
                    and minimum >= output * (PPM - slip) // PPM):
                raise ValueError("UXUY_INVALID_MINIMUM")
            valid.append((output, minimum, row, proof, index))
        except (TypeError, KeyError, ValueError, AttributeError, IndexError) as error:
            rejected.append({"index": index, "error": gateway_error(error)})
    detail = {"returnedCandidates": len(rows), "qualifiedCandidates": len(valid), "rejected": rejected}
    if not valid:
        return None, detail
    _, _, row, proof, index = max(valid, key=lambda entry: entry[:2])
    detail.update(selectedIndex=index, calldataOrderId=proof["orderId"],
                  rowOrderIdEchoed=proof["rowOrderIdEchoed"], orderIdMatches=True)
    return row, detail
