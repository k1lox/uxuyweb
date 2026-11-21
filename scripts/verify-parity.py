#!/usr/bin/env python3
"""Check protected release sources against the public distribution's SHA-256 manifest."""
import hashlib
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "scripts" / "source-sha256.json").read_text())
changed = []
for name, expected in manifest["files"].items():
    source = root / name
    if source.is_symlink() or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        changed.append(name)

for name in manifest["retired"]:
    if (root / name).exists():
        changed.append(name)

print(json.dumps({"protectedFiles": len(manifest["files"]), "unexpectedChanges": changed, "ok": not changed}, indent=2))
sys.exit(bool(changed))
