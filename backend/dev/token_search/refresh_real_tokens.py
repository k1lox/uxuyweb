"""Rebuild the real-token test list from the newest mainnet tokens (read-only).

Category = platform|side|settlement|variant, variant being the Four creator type (tax0 plain, tax5/8/9),
the Flap token version (v6 tax, v7 non-tax) or the Genius version. Four tokens with AntiSniperFeeMode get an
extra "|antisniper" suffix. Newest candidates first, at most 2 tokens per category. Everything is classified by
the backend's platform detection; nothing is sent.

Usage: python3 -I refresh_real_tokens.py <rpc_url> <backend_url> <head_block> <out.json>
"""
import collections, json, sys, time, urllib.error, urllib.request

RPC, BACKEND, HEAD, OUT = sys.argv[1], sys.argv[2].rstrip("/") + "/", int(sys.argv[3]), sys.argv[4]
FOUR = "0x5c952063c7fc8610ffdb798152d69f0b9550762b"
FOUR_TOKEN_CREATE = "0x396d5e902b675b032348d3d2e9517ee8f0c4a926603fbc075d3d282ff00cad20"
FOUR_LIQUIDITY_ADDED = "0xc18aa71171b358b706fe3dd345299685ba21a5316c66ffa9e319268b033c44b0"
FLAP = "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"
GENIUS = ["0x78eae9537c0ef90dfe9b7ae964682fe8138afe31", "0x37ee8aee29c5efd3c1a7eda6df3f510779928a37"]
GENIUS_LAUNCH = "0x8d4aad4953d0ca700d468f3753aa14432d1b35b43ec6409f051fb6aa43a89607"
OPENFOUR_CORE = "0xebe7b6c1089d9f72ad07f34e36d898e44e5e27f3"
PER = 2


def say(*a):
    print(*a, file=sys.stderr, flush=True)


def post(url, body, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "uxuy-test"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def rpc(method, params):
    r = post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def logs(address, topic, blocks, step=9999):
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


def words(log, data=True, topics=True):
    ws = (log["topics"][1:] if topics else []) + ([log["data"][2 + i:66 + i] for i in range(0, len(log["data"]) - 2, 64)] if data else [])
    for w in ws:
        w = w[-64:]
        if len(w) == 64 and w[:24] == "0" * 24 and int(w[24:], 16) > 0xFFFFFFFF:
            yield "0x" + w[24:].lower()


def anti_sniper(token):
    # TokenManager2._tokenInfoEx1s(token) (selector 0x9f266331) -> (launchFee, pcFee, feeSetting, blockNumber, extraFee)
    out = rpc("eth_call", [{"to": FOUR, "data": "0x9f266331" + token[2:].rjust(64, "0")}, hex(HEAD)])
    return len(out) >= 2 + 64 * 3 and int(out[2 + 128:2 + 192], 16) > 0


def category(m, token):
    quote = (m.get("quote") or "0x0").lower()
    kind = "bnb" if int(quote, 16) == 0 else "pool"
    side = "external" if m.get("external") else "internal"
    p = m["platform"]
    if p == "four":
        extra = f"tax{m.get('taxType')}" + ("|antisniper" if not m.get("external") and anti_sniper(token) else "")
    elif p == "flap":
        extra = f"v{m.get('taxType')}"
    elif p == "genius":
        extra = (m.get("genius") or {}).get("version") or ""
    else:
        extra = ""
    return f"{p}|{side}|{kind}|{extra}", quote


buckets = collections.defaultdict(list)
refused = []
seen = set()


def search(name, candidates, budget):
    n = 0
    for token in candidates:
        if token in seen:
            continue
        seen.add(token)
        if n >= budget:
            break
        n += 1
        r = post(BACKEND + "api/v1/platforms/bsc", {"token": token})
        if not r.get("ok"):
            if len(refused) < 40:
                refused.append({"token": token, "source": name, "reason": r.get("message")})
            continue
        m = r["result"]
        key, quote = category(m, token)
        if len(buckets[key]) < PER:
            buckets[key].append({"token": m["address"], "symbol": m.get("symbol"), "platform": m["platform"],
                                 "external": bool(m.get("external")), "quote": quote, "category": key})
            say(f"{name}: + {key} {m.get('symbol')} {m['address']} (#{n})")
    say(f"{name}: classified {n}")


def unique(gen, suffixes=()):
    out = set()
    for a in gen:
        if a not in out and (not suffixes or a.endswith(suffixes)):
            out.add(a)
            yield a


search("four-new", unique(a for l in logs(FOUR, FOUR_TOKEN_CREATE, 40000) for a in list(words(l, topics=False))[1:2]), 160)
search("four-migrated", unique((a for l in logs(FOUR, FOUR_LIQUIDITY_ADDED, 600000) for a in words(l)), ("4444", "ffff")), 160)
search("flap", unique((a for l in logs(FLAP, None, 150000) for a in words(l)), ("7777", "8888")), 500)
search("genius", unique(a for l in logs(GENIUS, GENIUS_LAUNCH, 2000000) for a in list(words(l, data=False))[:1]), 400)
search("openfour", unique((a for l in logs(OPENFOUR_CORE, None, 600000) for a in words(l, data=False)), ("4444", "ffff")), 60)

result = [t for k in sorted(buckets) for t in buckets[k]]
json.dump(result, open(OUT, "w"), ensure_ascii=False, indent=1)
json.dump(refused, open(OUT.replace(".json", ".refused.json"), "w"), ensure_ascii=False, indent=1)
for k in sorted(buckets):
    say(f"{k:40s} {[t['symbol'] for t in buckets[k]]}")
say(f"refused samples: {collections.Counter(r['reason'] for r in refused).most_common()}")
