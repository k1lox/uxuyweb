"""Read-only: which launchpad entry points are people calling right now?

Pulls the logs of the Four / Flap / Genius contracts over the last N blocks, loads each transaction
and counts (contract the user called, 4-byte selector). A selector or contract that is busy on mainnet
but unknown to this project means the official app moved to a new interface.

Usage: python3 -I recent_entrypoints.py <rpc_url> [blocks=3000]
"""
import json, sys, urllib.request
from collections import Counter

RPC = sys.argv[1]
BLOCKS = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
WATCH = {
    "0x5c952063c7fc8610ffdb798152d69f0b9550762b": "Four TokenManager2",
    "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0": "Flap Portal",
    "0x78eae9537c0ef90dfe9b7ae964682fe8138afe31": "Genius factory v1",
    "0x37ee8aee29c5efd3c1a7eda6df3f510779928a37": "Genius factory v2",
    "0xff17f41c5efd6cce944af0912f300097d62df5c9": "Genius hook v1",
    "0x8e6f8ebbd62b60085b703c40b460dae802edc51b": "Genius hook v2",
}


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json", "User-Agent": "uxuy-test"})
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read())
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


head = int(rpc("eth_blockNumber", []), 16)
hashes = {}
for start in range(head - BLOCKS + 1, head + 1, 2000):
    logs = rpc("eth_getLogs", [{"fromBlock": hex(start), "toBlock": hex(min(start + 1999, head)), "address": list(WATCH)}])
    for log in logs:
        hashes.setdefault(log["transactionHash"], set()).add(log["address"].lower())

calls = Counter()
for i, (h, touched) in enumerate(hashes.items()):
    tx = rpc("eth_getTransactionByHash", [h])
    to = (tx.get("to") or "create").lower()
    sel = tx["input"][:10]
    platforms = ",".join(sorted(WATCH[a] for a in touched))
    calls[(platforms, WATCH.get(to, to), sel)] += 1

print(f"blocks {head - BLOCKS + 1}..{head}: {len(hashes)} transactions")
for (platforms, to, sel), n in calls.most_common(60):
    print(f"{n:5d}  {platforms:40s} to={to:44s} {sel}")
