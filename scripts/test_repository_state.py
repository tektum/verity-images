#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_repository_state.py

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Final


ROOT: Final = Path(__file__).resolve().parents[1]
SCHEMA: Final = ROOT / "packages/repository-state.schema.json"
STATE: Final = ROOT / "packages/repository-state.json"
VALIDATOR: Final = ROOT / "scripts/validate_repository_state.py"
RENOVATE: Final = ROOT / "renovate.json"


def validate(state: dict[str, object]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "repository-state.json"
        path.write_text(json.dumps(state), encoding="utf-8")
        schema = subprocess.run(
            ["check-jsonschema", "--schemafile", str(SCHEMA), str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        semantic = subprocess.run(
            ["python3", str(VALIDATOR), str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        return schema if schema.returncode else semantic


def rejects(state: dict[str, object]) -> None:
    assert validate(state).returncode != 0


def state() -> dict[str, object]:
    return json.loads(STATE.read_text(encoding="utf-8"))


def valid_state() -> None:
    assert validate(state()).returncode == 0


def rejects_invalid_owner() -> None:
    candidate = state()
    candidate["repository"] = "other/verity-images"
    rejects(candidate)


def rejects_noncanonical_tag() -> None:
    candidate = state()
    candidate["release"] = {**candidate["release"], "tag": "latest"}
    rejects(candidate)


def rejects_wrong_fixed_asset_name() -> None:
    candidate = state()
    candidate["asset"] = {**candidate["asset"], "name": "other.tar.zst"}
    rejects(candidate)


def rejects_malformed_digest() -> None:
    candidate = state()
    candidate["asset"] = {**candidate["asset"], "sha256": "sha256:bad"}
    rejects(candidate)


def rejects_mismatched_digest() -> None:
    candidate = state()
    candidate["asset"] = {**candidate["asset"], "sha256": "sha256:" + "0" * 64}
    rejects(candidate)


def rejects_key_mismatch() -> None:
    candidate = state()
    candidate["key"] = {**candidate["key"], "fingerprint": "0" * 64}
    rejects(candidate)


def rejects_duplicate_package_identity() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    archive["manifest"]["packages"].append(archive["manifest"]["packages"][0])
    candidate["archive"] = archive
    rejects(candidate)


def rejects_unsupported_architecture() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    archive["manifest"]["packages"][0]["architecture"] = "armv7"
    candidate["archive"] = archive
    rejects(candidate)


def rejects_missing_architecture() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    archive["manifest"]["packages"].pop()
    candidate["archive"] = archive
    rejects(candidate)


def rejects_wrong_archive_root() -> None:
    candidate = state()
    candidate["archive"] = {**candidate["archive"], "root": "release"}
    rejects(candidate)


def rejects_manifest_self_hash() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    archive["manifest"]["sha256"] = archive["manifestSha256"]
    candidate["archive"] = archive
    rejects(candidate)


def updater_requires_review() -> None:
    renovate = json.loads(RENOVATE.read_text(encoding="utf-8"))
    managers = renovate["customManagers"]
    rules = renovate["packageRules"]
    assert any("repository-state" in manager["managerFilePatterns"][0] for manager in managers)
    assert any(
        rule.get("matchFileNames") == ["packages/repository-state.json"]
        and rule.get("automerge") is False
        for rule in rules
    )


def main() -> None:
    valid_state()
    rejects_invalid_owner()
    rejects_noncanonical_tag()
    rejects_wrong_fixed_asset_name()
    rejects_malformed_digest()
    rejects_mismatched_digest()
    rejects_key_mismatch()
    rejects_duplicate_package_identity()
    rejects_unsupported_architecture()
    rejects_missing_architecture()
    rejects_wrong_archive_root()
    rejects_manifest_self_hash()
    updater_requires_review()


if __name__ == "__main__":
    main()
