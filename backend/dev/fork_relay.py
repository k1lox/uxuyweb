"""Local bundle relay for fork testing only.

Accepts bloXroute-style `blxr_submit_bundle` on 127.0.0.1 and lands the transactions of a bundle on a
local Anvil fork in one ordered block. Start a dedicated node with --order fifo.
If Anvil cannot admit an unfunded dependent transfer, an ordinary bundle can use the original
sequential transfer fixture. A no_merge bundle must execute in one block or roll back.
Never points at a public network.

Usage: python3 -I fork_relay.py <listen_port> <anvil_url>
"""
import http.server, json, sys, threading, time, urllib.request

PORT = int(sys.argv[1])
ANVIL = sys.argv[2]
assert ANVIL.startswith("http://127.0.0.1:") or ANVIL.startswith("http://localhost:"), "fork relay only talks to a local node"
bundle_lock = threading.Lock()


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(ANVIL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if payload.get("method") != "blxr_submit_bundle":
            return self.reply({"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32601, "message": "unsupported"}})
        with bundle_lock:
            result = self.land_bundle(payload["params"]["txs"], payload["params"].get("no_merge") is True)
        self.reply({"jsonrpc": "2.0", "id": payload.get("id"), **result})

    def land_bundle(self, txs, atomic):
        raws = [tx if tx.startswith("0x") else "0x" + tx for tx in txs]
        if not raws:
            return {"error": {"code": -32602, "message": "empty bundle"}}

        # The fixture owns this Anvil while it changes mining mode.
        pool = rpc("txpool_status", []).get("result") or {}
        if rpc("anvil_getAutomine", []).get("result") is not True or any(
            int(pool.get(key, "0x1"), 16) for key in ("pending", "queued")
        ):
            return {"error": {"code": -32603, "message": "fork relay requires an idle automining Anvil"}}
        hashes = [rpc("web3_sha3", [raw]).get("result") for raw in raws]
        snapshot = rpc("evm_snapshot", []).get("result")
        if snapshot is None or not all(hashes):
            return {"error": {"code": -32603, "message": "fork snapshot or original hash unavailable"}}

        error = None
        dependent = False
        restore_mining = True
        try:
            if "error" in rpc("evm_setAutomine", [False]):
                raise RuntimeError("cannot suspend automining")
            for raw, expected in zip(raws, hashes):
                result = rpc("eth_sendRawTransaction", [raw])
                if result.get("result") != expected:
                    message = result.get("error", {}).get("message", "unverified transaction hash")
                    dependent = "insufficient funds" in message.lower()
                    raise RuntimeError(message)
            if "error" in rpc("evm_mine", []):
                raise RuntimeError("cannot mine fork bundle")
            block = None
            previous = -1
            for tx_hash in hashes:
                receipt = rpc("eth_getTransactionReceipt", [tx_hash]).get("result") or {}
                index = int(receipt.get("transactionIndex", "-1"), 16)
                found = receipt.get("blockHash")
                if (receipt.get("transactionHash") != tx_hash or receipt.get("status") != "0x1"
                    or not found or (block is not None and found != block) or index <= previous):
                    raise RuntimeError("fork bundle did not settle in one block in submitted order")
                block, previous = found, index
        except Exception as problem:
            error = str(problem)
            restore_mining = False
            if rpc("evm_revert", [snapshot]).get("result") is not True:
                return {"error": {"code": -32603, "message": "fork rollback could not be confirmed"}}
            for tx_hash in hashes:
                rpc("anvil_dropTransaction", [tx_hash])
            pool = rpc("txpool_status", []).get("result") or {}
            if any(int(pool.get(key, "0x1"), 16) for key in ("pending", "queued")):
                return {"error": {"code": -32603, "message": "fork pending queue could not be reconciled"}}
            restore_mining = True
        finally:
            if restore_mining and "error" in rpc("evm_setAutomine", [True]):
                raise RuntimeError("cannot restore fork automining")

        if error is None:
            return {"result": {"bundleHash": hashes[0]}}
        if atomic or not dependent:
            return {"error": {"code": -32003, "message": "local bundle rolled back: " + error}}

        # Anvil checks balances at mempool admission. This fallback is only for ordinary
        # transfer fixtures that first fund a new relay and then spend from that relay.
        included = []
        for raw, tx_hash in zip(raws, hashes):
            submitted = rpc("eth_sendRawTransaction", [raw])
            if submitted.get("result") != tx_hash:
                continue
            for _ in range(100):
                if rpc("eth_getTransactionReceipt", [tx_hash]).get("result"):
                    included.append(tx_hash)
                    break
                time.sleep(0.05)
        if included:
            return {"result": {"bundleHash": included[0]}}
        return {"error": {"code": -32000, "message": "dependent transfer fixture did not settle"}}

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
