"""Collect real, recently traded launchpad tokens from official contract logs and classify them with the
backend's official-registry detection. Read-only. Output: JSON list of representative tokens per category.

Usage: python3 -I scan_real_tokens.py <rpc_url> <backend_url> <out.json> [blocks]
"""
import json, sys, urllib.request, collections

RPC, BACKEND, OUT = sys.argv[1:4]
BLOCKS = int(sys.argv[4]) if len(sys.argv) > 4 else 40000
SOURCES = {
    "four": (["0x5c952063c7fc8610ffdb798152d69f0b9550762b"], ("4444", "ffff")),
    "flap": (["0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"], ("7777", "8888")),
    "genius": (["0x78eae9537c0ef90dfe9b7ae964682fe8138afe31", "0x37ee8aee29c5efd3c1a7eda6df3f510779928a37"], ("6666",)),
}

def post(url, body, timeout=60):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def rpc(method, params):
    r = post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]

head = int(sys.argv[5]) if len(sys.argv) > 5 else int(rpc("eth_blockNumber", []), 16)  # pass the fork block to skip test tokens
counts = {k: collections.Counter() for k in SOURCES}

def scan(platform, addresses, topic, blocks, suffixes, topic_only=False):
    start = head - blocks
    while start < head:
        end = min(start + 4999, head)
        query = {"address": addresses, "fromBlock": hex(start), "toBlock": hex(end)}
        if topic:
            query["topics"] = [topic]
        try:
            logs = rpc("eth_getLogs", [query])
        except Exception as e:
            print(f"{platform} {start}-{end}: {e}", file=sys.stderr)
            logs = []
        for log in logs:
            words = log["topics"][1:2] if topic_only else log["topics"][1:] + [log["data"][2 + i:2 + i + 64] for i in range(0, len(log["data"]) - 2, 64)]
            for w in words:
                w = w[-64:] if w.startswith("0x") else w
                if len(w) == 64 and w[:24] == "0" * 24:
                    a = "0x" + w[24:]
                    if not suffixes or a.endswith(suffixes):
                        counts[platform][a] += 1
        start = end + 1

FOUR, FLAP = SOURCES["four"][0], SOURCES["flap"][0]
GENIUS = SOURCES["genius"][0]
scan("four", FOUR, None, BLOCKS, ("4444", "ffff"))
# Migrations (LiquidityAdded(base, offers, quote, funds)): tokens that are on PancakeSwap now.
scan("four", FOUR, "0xc18aa71171b358b706fe3dd345299685ba21a5316c66ffa9e319268b033c44b0", BLOCKS * 10, ("4444", "ffff"))
scan("flap", FLAP, None, BLOCKS, ("7777", "8888"))
# Genius launch events carry the token in topic 1 (no vanity suffix).
scan("genius", GENIUS, "0x8d4aad4953d0ca700d468f3753aa14432d1b35b43ec6409f051fb6aa43a89607", BLOCKS * 10, (), topic_only=True)

for platform, counter in counts.items():
    print(f"{platform}: {len(counter)} candidates", file=sys.stderr)

def classify(token):
    for _ in range(3):
        try:
            return post(BACKEND + "api/v1/platforms/bsc", {"token": token}, timeout=90)
        except Exception:
            continue
    return {}

buckets = collections.defaultdict(list)
for platform, counter in counts.items():
    for token, n in counter.most_common(200):
        r = classify(token)
        if not r.get("ok"):
            continue
        m = r["result"]
        quote = m.get("quote") or "0x0000000000000000000000000000000000000000"
        kind = "bnb" if int(quote, 16) == 0 or quote.lower() == "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c" else "pool"
        extra = ""
        if m["platform"] == "four":
            extra = "tax" if int(m.get("taxType") or 0) else "plain"
        if m["platform"] == "genius":
            extra = str((m.get("genius") or {}).get("version") or "")
        key = f'{m["platform"]}|{"external" if m.get("external") or m["platform"] == "external" else "internal"}|{kind}|{extra}'
        if len(buckets[key]) < 2:
            buckets[key].append({"token": m["address"], "symbol": m.get("symbol"), "platform": m["platform"], "external": bool(m.get("external")),
                                 "quote": quote, "category": key, "activity": n})

result = [t for k in sorted(buckets) for t in buckets[k]]
json.dump(result, open(OUT, "w"), indent=1)
for k in sorted(buckets):
    print(k, [t["symbol"] for t in buckets[k]])
