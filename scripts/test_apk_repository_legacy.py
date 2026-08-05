from __future__ import annotations

import hashlib
import json
import tempfile
from pathlib import Path

import apk_repository_policy
from test_apk_repository import repository


def accepts_legacy_manifest_identity_from_apk() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        _, keys, _ = repository(root)
        manifest = root / "manifest.json"
        values = json.loads(manifest.read_text(encoding="utf-8"))
        for package in values["packages"]:
            for field in ("name", "version", "epoch"):
                del package[field]
        manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
        apk_repository_policy.validate(root, keys, hashlib.sha256(manifest.read_bytes()).hexdigest())


if __name__ == "__main__":
    accepts_legacy_manifest_identity_from_apk()
