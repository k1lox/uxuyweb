"""Read-only: newest Four tokens created with AntiSniperFeeMode (TokenManager2._tokenInfoEx1s(token).feeSetting > 0).

Usage: python3 -I four_antisniper.py <rpc_url> <head_block> [blocks=400000] [want=4]
Prints one token address per line (newest first).
"""
import json, sys, urllib.request

RPC, HEAD = sys.argv[1], int(sys.argv[2])
BLOCKS = int(sys.argv[3]) if len(sys.argv) > 3 else 400000
WANT = int(sys.argv[4]) if len(sys.argv) > 4 else 4
FOUR = "0x5c952063c7fc8610ffdb798152d69f0b9550762b"
TOKEN_CREATE = "0x396d5e902b675b032348d3d2e9517ee8f0c4a926603fbc075d3d282ff00cad20"
EX1 = "0x9f266331"  # _tokenInfoEx1s(address) -> (launchFee, pcFee, feeSetting, blockNumber, extraFee)


def call(body):
    req = urllib.request.Request(RPC, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "uxuy-test"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


found, end = [], HEAD
while end > HEAD - BLOCKS and len(found) < WANT:
    start = max(end - 9998, HEAD - BLOCKS)
    logs = call({"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs",
                 "params": [{"address": FOUR, "topics": [TOKEN_CREATE], "fromBlock": hex(start), "toBlock": hex(end)}]}).get("result", [])
    tokens = ["0x" + l["data"][2 + 64 + 24:2 + 128] for l in reversed(logs)]
    if tokens:
        batch = [{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": FOUR, "data": EX1 + t[2:].rjust(64, "0")}, hex(HEAD)]}
                 for i, t in enumerate(tokens)]
        for r in sorted(call(batch), key=lambda r: r["id"]):
            out = r.get("result") or ""
            if len(out) >= 2 + 192 and int(out[2 + 128:2 + 192], 16) > 0 and len(found) < WANT:
                found.append(tokens[r["id"]])
                print(tokens[r["id"]], flush=True)
    end = start - 1
print(f"scanned down to block {end + 1}", file=sys.stderr)
