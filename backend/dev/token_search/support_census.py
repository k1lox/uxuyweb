"""Read-only census: of the newest tokens each launchpad created, how many does the backend accept?

Collects the most recently created tokens from mainnet logs (Four TokenManager2, Flap Portal, Genius
factories, OpenFour Core), asks the backend's platform detection for each one and prints, per platform,
how many are accepted (and as what) and the reasons for the rest. No transactions are sent.

Usage: python3 -I support_census.py <rpc_url> <backend_url> [per_platform=60] [out.json]
"""
import collections, json, sys, time, urllib.request

RPC, BACKEND = sys.argv[1], sys.argv[2].rstrip("/") + "/"
PER = int(sys.argv[3]) if len(sys.argv) > 3 else 60
OUT = sys.argv[4] if len(sys.argv) > 4 else None
FOUR = "0x5c952063c7fc8610ffdb798152d69f0b9550762b"
FOUR_TOKEN_CREATE = "0x396d5e902b675b032348d3d2e9517ee8f0c4a926603fbc075d3d282ff00cad20"
FLAP = "0xe2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0"
GENIUS = ["0x78eae9537c0ef90dfe9b7ae964682fe8138afe31", "0x37ee8aee29c5efd3c1a7eda6df3f510779928a37"]
GENIUS_LAUNCH = "0x8d4aad4953d0ca700d468f3753aa14432d1b35b43ec6409f051fb6aa43a89607"
OPENFOUR_CORE = "0xebe7b6c1089d9f72ad07f34e36d898e44e5e27f3"


def post(url, body, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "uxuy-test"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:  # backend answers refusals with 4xx + JSON
        return json.loads(e.read() or b"{}")


def rpc(method, params):
    r = post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


HEAD = int(rpc("eth_blockNumber", []), 16)


def newest_logs(address, topic, max_blocks, want, step=5000):
    end = HEAD
    while end > HEAD - max_blocks and want():
        start = max(end - step + 1, HEAD - max_blocks)
        q = {"address": address, "fromBlock": hex(start), "toBlock": hex(end)}
        if topic:
            q["topics"] = [topic]
        yield from reversed(rpc("eth_getLogs", [q]))
        end = start - 1


def addr_words(log, data_only=False, topics_only=False):
    ws = ([] if data_only else log["topics"][1:]) + ([] if topics_only else [log["data"][2 + i:66 + i] for i in range(0, len(log["data"]) - 2, 64)])
    for w in ws:
        w = w[-64:]
        if len(w) == 64 and w[:24] == "0" * 24 and int(w[24:], 16) > 0xFFFFFFFF:
            yield "0x" + w[24:].lower()


def collect(name, address, topic, max_blocks, pick):
    out = []
    for log in newest_logs(address, topic, max_blocks, lambda: len(out) < PER):
        for a in pick(log):
            if a not in out and len(out) < PER:
                out.append(a)
    print(f"{name}: {len(out)} newest tokens", file=sys.stderr, flush=True)
    return out


sources = {
    # TokenCreate(creator, token, requestId, ...): token is the second data word.
    "four": collect("four", FOUR, FOUR_TOKEN_CREATE, 60000, lambda l: list(addr_words(l, data_only=True))[1:2]),
    "flap": collect("flap", FLAP, None, 20000, lambda l: [a for a in addr_words(l) if a.endswith(("7777", "8888"))]),
    "genius": collect("genius", GENIUS, GENIUS_LAUNCH, 600000, lambda l: list(addr_words(l, topics_only=True))[:1]),
    "openfour": collect("openfour", OPENFOUR_CORE, None, 600000, lambda l: [a for a in addr_words(l, topics_only=True)
                                                                            if a.endswith(("4444", "ffff"))]),
}

report = {}
for platform, tokens in sources.items():
    tally, rows = collections.Counter(), []
    for t in tokens:
        r = post(BACKEND + "api/v1/platforms/bsc", {"token": t})
        if r.get("ok"):
            m = r["result"]
            quote = (m.get("quote") or "0x0").lower()
            kind = "bnb" if int(quote, 16) == 0 else "pool"
            side = "external" if m.get("external") else "internal"
            extra = (m.get("genius") or {}).get("version") or (f"tax{m.get('taxType')}" if m["platform"] in ("four", "flap") else "")
            label = f'接受 {m["platform"]}|{side}|{kind}|{extra}'
        else:
            label = f'拒绝 {r.get("code")}: {r.get("message")}'
        tally[label] += 1
        rows.append({"token": t, "result": label})
        time.sleep(0.05)
    report[platform] = rows
    accepted = sum(n for k, n in tally.items() if k.startswith("接受"))
    print(f"\n== {platform}: {accepted}/{len(tokens)} 接受")
    for k, n in tally.most_common():
        print(f"  {n:4d}  {k}")

if OUT:
    json.dump(report, open(OUT, "w"), ensure_ascii=False, indent=1)
