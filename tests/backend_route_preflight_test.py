"""Run the Rust UXUY route preflight suite against its loopback gateway, RPC and relay."""

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class BackendRoutePreflight(unittest.TestCase):
    def test_uxuy_route_preflight(self):
        env = os.environ.copy()
        env.setdefault("CARGO_TARGET_DIR", str(ROOT / ".tooling/cargo-target"))
        result = subprocess.run(
            ["cargo", "test", "--offline", "--locked", "-p", "uxuy-backend", "route::tests::"],
            cwd=ROOT / "backend",
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertRegex(result.stdout, r"test result: ok\. [1-9]\d* passed", result.stdout)
        print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
