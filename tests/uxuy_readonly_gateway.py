"""Opt-in BSC read-only UXUY test adapter; no transaction-signing or submission methods.

Set UXUY_TEST_CREDENTIAL_DIR to a directory containing app_id.txt and rs256_key.pem.
The key is used locally for a short-lived RS256 API bearer and its public fingerprint.
"""
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from functools import lru_cache
from pathlib import Path


SWAP_ABI = "(address,address,address[],uint256,bytes)"
BRIDGE_ABI = "(address,address,address,uint256,address,uint256,bytes)"
TRADE_ABI = f"trade((uint256,{SWAP_ABI}[],{BRIDGE_ABI},address,address,uint256,{SWAP_ABI}[],uint256,uint256))"


def new_order_id():
    return str(secrets.randbelow(2**52 - 1) + 1)


def verify_trade_calldata(row, request, *, expected_input=None):
    """Validate the unsigned ABI's order identity locally; never contact a provider."""
    order_id = request["orderId"]
    if not isinstance(order_id, str) or not re.fullmatch(r"[1-9][0-9]{0,77}", order_id):
        raise ValueError("UXUY_ORDER_MISMATCH")
    echoed = "orderId" in row
    if echoed and row["orderId"] != order_id:
        raise ValueError("UXUY_ORDER_MISMATCH")
    if expected_input is None:
        # Exactly calculate the integer input without using a floating-point conversion.
        amount = request["amountIn"]
        decimals = request["decimals"]
        if (type(decimals) is not int or not 0 <= decimals <= 255 or not isinstance(amount, str)
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", amount)):
            raise ValueError("UXUY_AMOUNT_MISMATCH")
        whole, _, fraction = amount.partition(".")
        if any(digit != "0" for digit in fraction[decimals:]):
            raise ValueError("UXUY_AMOUNT_MISMATCH")
        expected_input = int(whole + fraction[:decimals].ljust(decimals, "0"))
    call = row.get("calldata")
    if (not isinstance(call, dict) or not isinstance(call.get("to"), str)
            or not re.fullmatch(r"0x[0-9a-fA-F]{40}", call["to"]) or int(call["to"], 16) == 0):
        raise ValueError("UXUY_TRADE_TARGET_INVALID")
    data = call.get("data")
    if not isinstance(data, str):
        raise ValueError("UXUY_TRADE_CALLDATA_INVALID")
    raw = data.removeprefix("0x")
    if (not raw.startswith("5103aafa") or len(raw) < 8 + 10 * 64 or (len(raw) - 8) % 64
            or len(raw) > 2 * 256 * 1024 or not re.fullmatch(r"[0-9a-fA-F]+", raw)
            or int(raw[8:72], 16) != 32):
        raise ValueError("UXUY_TRADE_CALLDATA_INVALID")
    cast = shutil.which("cast")
    if not cast:
        raise ValueError("UXUY_LOCAL_ABI_DECODER_MISSING")
    # feed via stdin: provider data may exceed the OS maximum length for one argv string.
    try:
        proc = subprocess.run(
            [cast, "calldata-decode", "--json", TRADE_ABI, "--file", "/dev/stdin"], input="0x" + raw,
            capture_output=True, text=True, timeout=10)
        if proc.returncode:
            raise ValueError("UXUY_TRADE_CALLDATA_INVALID")
        [trade] = json.loads(proc.stdout)
        if len(trade) != 9 or int(trade[8]) != int(order_id):
            raise ValueError("UXUY_ORDER_MISMATCH")
        if int(trade[0]) != expected_input:
            raise ValueError("UXUY_AMOUNT_MISMATCH")
        recipient = trade[3].lower()
        if recipient != request["receiver"].lower():
            raise ValueError("UXUY_RECIPIENT_MISMATCH")
    except (TypeError, KeyError, IndexError, AttributeError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
        raise ValueError("UXUY_TRADE_CALLDATA_INVALID") from exc
    return {"orderId": order_id, "amountIn": str(expected_input), "recipient": recipient,
            "rowOrderIdEchoed": echoed}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def encoded(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


@lru_cache(maxsize=1)
def _credentials(directory, interval):
    root = Path(directory)
    app = (root / "app_id.txt").read_text("utf-8-sig").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", app):
        raise ValueError("invalid UXUY API ID")
    key = str(root / "rs256_key.pem")
    # The gateway identifies the signing key by its SubjectPublicKeyInfo fingerprint.
    public_key = subprocess.run(
        ["openssl", "rsa", "-in", key, "-pubout", "-outform", "DER"],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=5,
    )
    if public_key.returncode:
        raise RuntimeError("UXUY RSA public key unavailable")
    fingerprint = base64.b64encode(hashlib.sha256(public_key.stdout).digest())
    jti = hashlib.md5(fingerprint, usedforsecurity=False).hexdigest()
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "jti": jti}
    claims = {"jti": jti, "iss": "app", "ts": now, "exp": now + 300}
    unsigned = ".".join(encoded(json.dumps(item, separators=(",", ":")).encode()) for item in (header, claims)).encode("ascii")
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key],
                            input=unsigned, capture_output=True, timeout=5)
    if result.returncode:
        raise RuntimeError("UXUY API signature unavailable")
    return app, unsigned.decode("ascii") + "." + encoded(result.stdout)


def _fetch(method, params):
    if method not in {"dex_offlineQuote", "dex_offlineQuotes"}:
        raise ValueError("only read-only UXUY quote methods are supported")
    directory = os.environ.get("UXUY_TEST_CREDENTIAL_DIR")
    if not directory:
        raise RuntimeError("set UXUY_TEST_CREDENTIAL_DIR to enable live read-only quotes")
    app, bearer = _credentials(directory, int(time.time()) // 120)
    request = urllib.request.Request(
        "https://gwapi.ourdex.com/bnbchain/" + app,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + bearer, "User-Agent": "uxuy-web-readonly-audit/1"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"UXUY HTTP {exc.code}") from None
    except OSError as exc:
        raise RuntimeError("UXUY transport " + type(exc).__name__) from None
    if len(raw) > 4 * 1024 * 1024:
        raise RuntimeError("UXUY response too large")
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("id") != 1 or data.get("jsonrpc") != "2.0":
        raise RuntimeError("invalid UXUY RPC response")
    if data.get("error") or not isinstance(data.get("result"), list):
        error = data.get("error")
        code = error.get("code") if isinstance(error, dict) else None
        raise RuntimeError(f"UXUY RPC {code}" if isinstance(code, int) else "UXUY RPC rejected quote")
    return data["result"]


def quote(req):
    return _fetch("dex_offlineQuote", [req])


def quotes(requests):
    if not 1 <= len(requests) <= 20:
        raise ValueError("UXUY accepts up to 20 quotes per batch")
    return _fetch("dex_offlineQuotes", [requests])
