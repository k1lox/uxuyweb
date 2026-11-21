"""Targeted search for real launchpad tokens in categories the broad scan has not filled yet.
Read-only (eth_getLogs + backend platform detection). Newest candidates first, stops per category at 2.

Usage: python3 -I find_gap_tokens.py <rpc_url> <backend_url> <out.json> <head_block> [existing.json]
"""
import json, sys, time, urllib.request, collections

RPC, BACKEND, OUT = sys.argv[1:4]
HEAD = int(sys.argv[4])
EXISTING = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else []
FOUR = "0x5c952063c7fc8610ffdb798152d69f0b9550762b"
FLAP = "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"
GENIUS = ["0x78eae9537c0ef90dfe9b7ae964682fe8138afe31", "0x37ee8aee29c5efd3c1a7eda6df3f510779928a37"]
FOUR_LIQUIDITY_ADDED = "0xc18aa71171b358b706fe3dd345299685ba21a5316c66ffa9e319268b033c44b0"
GENIUS_LAUNCH = "0x8d4aad4953d0ca700d468f3753aa14432d1b35b43ec6409f051fb6aa43a89607"


def say(*a):
    print(*a, file=sys.stderr, flush=True)


def post(url, body, timeout=90):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def rpc(method, params):
    r = post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=120)
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def logs(address, topic, blocks, step=5000):
    """Newest window first."""
    end = HEAD
    while end > HEAD - blocks:
        start = max(end - step + 1, HEAD - blocks)
        q = {"address": address, "fromBlock": hex(start), "toBlock": hex(end)}
        if topic:
            q["topics"] = [topic]
        try:
            batch = rpc("eth_getLogs", [q])
        except Exception as e:  # noqa: BLE001
            say(f"logs {start}-{end}: {e}")
            batch = []
        yield from reversed(batch)
        end = start - 1


def words(log, topic_only=False):
    ws = log["topics"][1:2] if topic_only else log["topics"][1:] + [log["data"][2 + i:2 + i + 64] for i in range(0, len(log["data"]) - 2, 64)]
    for w in ws:
        w = w[-64:]
        if len(w) == 64 and w[:24] == "0" * 24:
            yield "0x" + w[24:]


def classify(token):
    for _ in range(3):
        try:
            r = post(BACKEND + "api/v1/platforms/bsc", {"token": token})
            return r.get("result") if r.get("ok") else None
        except Exception:  # noqa: BLE001
            time.sleep(1)
    return None


def key_of(m):
    quote = m.get("quote") or "0x0000000000000000000000000000000000000000"
    kind = "bnb" if int(quote, 16) == 0 or quote.lower() == "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c" else "pool"
    extra = ""
    if m["platform"] == "four":
        extra = "tax" if int(m.get("taxType") or 0) else "plain"
    if m["platform"] == "genius":
        extra = str((m.get("genius") or {}).get("version") or "")
    side = "external" if m.get("external") or m["platform"] == "external" else "internal"
    return f'{m["platform"]}|{side}|{kind}|{extra}', quote


buckets = collections.defaultdict(list)
seen = set()
for t in EXISTING:
    buckets[t["category"]].append(t)
    seen.add(t["token"].lower())


def search(name, candidates, wanted, budget):
    """Classify candidates (newest first) until every wanted prefix has 2 tokens or the budget runs out."""
    def missing():
        return [w for w in wanted if sum(len(v) for k, v in buckets.items() if k.startswith(w)) < 2]
    n = 0
    for token in candidates:
        if not missing() or n >= budget:
            break
        if token in seen:
            continue
        seen.add(token)
        n += 1
        m = classify(token)
        if not m:
            continue
        key, quote = key_of(m)
        if any(key.startswith(w) for w in missing()) and len(buckets[key]) < 2:
            buckets[key].append({"token": m["address"], "symbol": m.get("symbol"), "platform": m["platform"], "external": bool(m.get("external")),
                                 "quote": quote, "category": key})
            say(f"{name}: + {key} {m.get('symbol')} {m['address']} (classified {n})")
    say(f"{name}: done after {n}; still missing {missing()}")


def unique(gen, suffixes=()):
    out = set()
    for a in gen:
        if a not in out and (not suffixes or a.endswith(suffixes)):
            out.add(a)
            yield a


# Four migrated to PancakeSwap (external), BNB and pool-token quotes.
search("four-external", unique((a for l in logs(FOUR, FOUR_LIQUIDITY_ADDED, 400000) for a in words(l)), ("4444", "ffff")),
       ["four|external|bnb", "four|external|pool"], 120)
# Four non-tax (plain) internal tokens.
search("four-plain", unique((a for l in logs(FOUR, None, 20000) for a in words(l)), ("4444",)), ["four|internal|bnb|plain", "four|internal|pool|plain"], 120)
# Genius, every version / side.
search("genius", unique(a for l in logs(GENIUS, GENIUS_LAUNCH, 400000) for a in words(l, topic_only=True)),
       ["genius|internal|bnb|v1", "genius|internal|bnb|v2", "genius|external|bnb", "genius|internal|pool", "genius|external|pool"], 150)
# Flap migrated, BNB quote.
search("flap-external", unique((a for l in logs(FLAP, None, 60000) for a in words(l)), ("7777", "8888")), ["flap|external|bnb"], 150)

result = [t for k in sorted(buckets) for t in buckets[k]]
json.dump(result, open(OUT, "w"), indent=1)
for k in sorted(buckets):
    say(k, [t["symbol"] for t in buckets[k]])
