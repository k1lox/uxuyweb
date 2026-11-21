"""Read-only: Flap tokens that got a DEX pool (PancakeSwap V2 pair, V3 pool or Infinity CL pool), grouped by
Flap tokenVersion and status, newest first. Used to find migrated samples of rarer versions.

Usage: python3 -I flap_by_version.py <rpc_url> <head_block> [blocks=1500000] [per_group=3]
"""
import collections, json, sys, urllib.request

RPC, HEAD = sys.argv[1], int(sys.argv[2])
BLOCKS = int(sys.argv[3]) if len(sys.argv) > 3 else 1500000
PER = int(sys.argv[4]) if len(sys.argv) > 4 else 3
PORTAL = "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"
SOURCES = [
    ("v2pair", "0xca143ce32fe78f1f7019d7d551a6402fc5350c73", "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9"),  # PairCreated
    ("v3pool", "0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865", "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118"),  # PoolCreated
    ("infinity", "0xa0ffb9c1ce1fe56963b0321b32e7a0302114058b", "0x426cc62fe6a33a40ba2788c2c87a9c34ee4582b95bc9fa5a7bb7ae70b750b99c"),  # CL Initialize
]
GET_STATE = "0x62fafcca"  # getTokenV8Safe(address)


def call(body):
    req = urllib.request.Request(RPC, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "uxuy-test"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def main():
    groups = collections.defaultdict(list)
    seen = set()
    for name, address, topic in SOURCES:
        end = HEAD
        while end > HEAD - BLOCKS:
            start = max(end - 9998, HEAD - BLOCKS)
            logs = call({"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs",
                         "params": [{"address": address, "topics": [topic], "fromBlock": hex(start), "toBlock": hex(end)}]}).get("result", [])
            tokens = []
            for l in reversed(logs):
                for t in l["topics"][1:4]:
                    a = "0x" + t[26:]
                    if a.endswith(("7777", "8888")) and a not in seen:
                        seen.add(a)
                        tokens.append(a)
            if tokens:
                batch = [{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": PORTAL, "data": GET_STATE + t[2:].rjust(64, "0")}, hex(HEAD)]}
                         for i, t in enumerate(tokens)]
                for r in sorted(call(batch), key=lambda r: r["id"]):
                    out = r.get("result") or ""
                    if len(out) < 2 + 64 * 18:
                        continue
                    w = [out[2 + 64 * i:2 + 64 * (i + 1)] for i in range(18)]
                    key = f"v{int(w[4], 16)} status{int(w[0], 16)} {'bnb' if int(w[9], 16) == 0 else 'pool'} via {name}"
                    if len(groups[key]) < PER:
                        groups[key].append(tokens[r["id"]])
            end = start - 1
    for k in sorted(groups):
        print(k, groups[k])


if __name__ == "__main__":
    main()
