"""Opt-in read-only integration check. Run from any directory with python3.

Reads historical sample addresses, never their old market stage as an oracle.
Only the explicit metadata, venue detection and forecast APIs below are used.
Set UXUY_TEST_BACKEND_URL to use a backend other than the local preview API.
Outputs JSON to stdout so callers can keep separately dated observations.
"""
import concurrent.futures
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = os.getenv("UXUY_TEST_BACKEND_URL", "http://127.0.0.1:3291").rstrip("/")
CAKE = "0x0e09fabb73bd3ade0a17ecc321fd13a19e81ce82"
POOLS = {
    "BNCB": "0x4902c5ebc598265ed2212b559b042de8a5eeec3f",
    "NVDAB": "0x02fca66c1d1afb4e2a7884261eb00f63598a7436",
}
# Public placeholder for requesting wallet-specific *forecasts*. No key is used.
QUOTE_WALLET = "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"


def read(path, payload=None):
    request = urllib.request.Request(
        ORIGIN + "/api/v1/" + path,
        None if payload is None else json.dumps(payload).encode(),
        {"Content-Type": "application/json", "User-Agent": "UXUY-release-readonly/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            obj = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            obj = json.load(exc)
        except ValueError:
            raise RuntimeError(f"HTTP {exc.code}") from exc
    if not obj.get("ok"):
        raise RuntimeError(f"{obj.get('code')}: {obj.get('message')}")
    return obj


def inspect_token(item):
    ca, label, origin, version = item
    started = time.monotonic()
    row = {"address": ca, "sample": label, "expectedOrigin": origin}
    try:
        meta = read("tokens/" + ca)["token"]
        market = read("platforms/bsc", {"token": ca})["result"]
        row.update(symbol=meta["symbol"], decimals=meta["decimals"],
                   platform=market["platform"], external=market["external"],
                   block=market["block"], quote=market["quote"])
        if meta["token"].lower() != ca.lower() or market["address"].lower() != ca.lower():
            raise ValueError("response address mismatch")
        if type(meta["decimals"]) is not int or not 0 <= meta["decimals"] <= 255:
            raise ValueError("missing or invalid token decimals")
        if market["decimals"] != meta["decimals"] or type(market["external"]) is not bool:
            raise ValueError("invalid market stage or token precision mismatch")
        if version:
            row["version"] = market.get("genius", {}).get("version")
            if row["version"] != version:
                raise ValueError(f"expected {version} on the official creation event sample")
        if origin and market["platform"] != origin:
            raise ValueError(f"unexpected origin {market['platform']}, fixture {origin}")
    except (OSError, ValueError, KeyError, RuntimeError) as exc:
        row["error"] = str(exc)
    row["elapsedMs"] = round(1000 * (time.monotonic() - started))
    return row


def forecast_token(row, side):
    # BNB buys use 18 decimals. Sells use the selected asset's own precision.
    amount = str(10**15 if side == "buy" else 10**row["decimals"])
    token = row["address"]
    plan = read("routes", {"side": side, "token": token, "amount": amount,
                "wallet": QUOTE_WALLET, "maxImpactPercent": 100, "forecastOnly": True})["plan"]
    if (plan["source"] != "uxuy" or plan["chainId"] != 56 or plan["quoteScope"] != "wallet" or
            plan["token"].lower() != token or plan["wallet"].lower() != QUOTE_WALLET or
            plan["side"] != side or plan["amount"] != amount or
            not 0 < int(plan["minOut"]) <= int(plan["quoteOut"]) or
            plan["data"] != "0x" or plan["executed"] is not False or plan["simulation"] != "forecast"):
        raise ValueError("UXUY forecast disagrees with the request or is not an unsigned preview")
    return {"source": plan["source"], "amount": amount, "quoteOut": plan["quoteOut"],
            "minOut": plan["minOut"], "impact": plan["adversePriceImpactPercent"]}


def quotes(rows):
    results = []
    for row in rows:
        if row["sample"] not in ("CAKE", "USDC (Wormhole)", "DOGE", "FLOKI", *POOLS):
            continue
        for side in ("buy", "sell"):
            result = {"case": row["sample"] + "/" + side}
            try:
                if "error" in row:
                    raise ValueError("token identification failed")
                result.update(forecast_token(row, side))
            except (OSError, ValueError, KeyError, RuntimeError) as exc:
                result["error"] = str(exc)
            results.append(result)
    return results


def main():
    fixtures = json.loads((ROOT / "backend/dev/real_tokens.json").read_text())
    samples = {row["token"].lower(): (row["category"], row["platform"]) for row in fixtures}
    samples.update({
        CAKE: ("CAKE", "external"),
        "0xb04906e95ab5d797ada81508115611fee694c2b3": ("USDC (Wormhole)", None),
        "0xba2ae424d960c26247dd6c32edc70b295c744c43": ("DOGE", None),
        "0xfb5b838b6cfeedc2873ab27866079ac55363d37e": ("FLOKI", None),
        **{token: (label, None) for label, token in POOLS.items()},
    })
    recent = json.loads((ROOT / "tests/fixtures/release-bsc-creation-samples.json").read_text())
    versions = {}
    for item in recent:
        ca = item["token"].lower()
        samples[ca] = (item["platform"] + " factory event", item["platform"])
        versions[ca] = item.get("version")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(inspect_token, [(ca, *fields, versions.get(ca)) for ca, fields in samples.items()]))
    forecasts = quotes(rows)
    result = {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "tokens": rows, "forecasts": forecasts}
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(any("error" in row for row in rows + forecasts))


if __name__ == "__main__":
    sys.exit(main())
