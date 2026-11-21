"""Offline authentication check using a temporary RSA key and a captured HTTP request."""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import uxuy_readonly_gateway as gateway


def openssl(*args, data=None):
    return subprocess.run(
        ["openssl", *args], input=data, capture_output=True, check=True, timeout=10
    ).stdout


def jwt_part(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class AuthTests(unittest.TestCase):
    def test_url_uses_app_id_and_jwt_uses_pkix_fingerprint(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            app_id = "synthetic-app-id"
            (root / "app_id.txt").write_text(app_id)
            key = str(root / "rs256_key.pem")
            openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key)
            pub = root / "public.pem"
            pub.write_bytes(openssl("pkey", "-in", key, "-pubout"))

            # Use a separately parsed public PEM, as in the supplier's Go implementation.
            der = openssl("pkey", "-pubin", "-in", str(pub), "-outform", "DER")
            digest = openssl("dgst", "-sha256", "-binary", data=der)
            fingerprint = openssl("base64", "-A", data=digest)
            expected_jti = openssl("dgst", "-md5", "-binary", data=fingerprint).hex()

            self.addCleanup(gateway._credentials.cache_clear)
            timestamp = 1_700_000_000
            with patch.dict(os.environ, {"UXUY_TEST_CREDENTIAL_DIR": d}), \
                    patch.object(gateway.time, "time", return_value=timestamp), \
                    patch.object(gateway.urllib.request, "build_opener") as build:
                outbound = build.return_value.open
                outbound.return_value = io.BytesIO(b'{"jsonrpc":"2.0","id":1,"result":[]}')
                self.assertEqual(gateway.quote({"orderId": "test"}), [])
                outbound.assert_called_once()
                request = outbound.call_args.args[0]

            self.assertEqual(request.full_url, "https://gwapi.ourdex.com/bnbchain/" + app_id)
            self.assertEqual(request.get_method(), "POST")
            scheme, jwt = request.get_header("Authorization").split(" ")
            self.assertEqual(scheme, "Bearer")
            head, payload, sig = jwt.split(".")
            self.assertEqual(json.loads(jwt_part(head)), {"alg": "RS256", "typ": "JWT", "jti": expected_jti})
            self.assertEqual(json.loads(jwt_part(payload)), {
                "jti": expected_jti, "iss": "app", "ts": timestamp, "exp": timestamp + 300,
            })
            signature = root / "signature.bin"
            signature.write_bytes(jwt_part(sig))
            openssl("dgst", "-sha256", "-verify", str(pub), "-signature", str(signature),
                    data=f"{head}.{payload}".encode("ascii"))


if __name__ == "__main__":
    unittest.main()
