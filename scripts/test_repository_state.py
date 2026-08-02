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
    candidate = state()
    assert validate(candidate).returncode == 0
    assert candidate["release"] == {
        "id": 363781736,
        "tag": "apk-repo-v0002",
        "targetCommit": "d5c04984b5ee70654c081b016a0d7818030a7f61",
        "immutable": True,
    }
    assert candidate["asset"]["id"] == 498881369
    assert candidate["asset"]["sha256"] == "sha256:7d6783ffae959a9761fc61cf10b7888a14813e2e24887ff8315fa52f8a68e79a"
    assert candidate["archive"]["manifestSha256"] == "6604d9948d4c8acd95127eba2051721788eb1b9dd1490af6f4373f9c10cf1ea0"
    assert candidate["key"] == {
        "path": "packages/keys/verity-apk-2026.rsa.pub",
        "fingerprint": "764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698",
    }
    assert {(entry["architecture"], entry["name"], entry["version"], entry["epoch"], entry["path"], entry["sha256"]) for entry in candidate["packages"]} == {
        ("x86_64", "openssl-fips-provider", "3.1.2-r3", 3, "x86_64/openssl-fips-provider-3.1.2-r3.apk", "d5d67155c6689825d9eb9ec218adfafa017e88d11204d2e206b6e1c50125cb34"),
        ("aarch64", "openssl-fips-provider", "3.1.2-r3", 3, "aarch64/openssl-fips-provider-3.1.2-r3.apk", "d3479205b01250d98c9e167d467f4af6f839bddf591ce453b5d6fca9b68c294a"),
    }


def rejects_invalid_owner() -> None:
    candidate = state()
    candidate["repository"] = "other/verity-images"
    rejects(candidate)


def rejects_noncanonical_tag() -> None:
    candidate = state()
    candidate["release"] = {**candidate["release"], "tag": "latest"}
    rejects(candidate)


def rejects_substituted_release_identity() -> None:
    candidate = state()
    candidate["release"] = {
        **candidate["release"],
        "id": 1,
        "tag": "apk-repo-v9999",
        "targetCommit": "0" * 40,
    }
    candidate["asset"] = {**candidate["asset"], "id": 1}
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


def rejects_substituted_package_identity() -> None:
    candidate = state()
    candidate["packages"] = [
        {**entry, "name": "unrelated", "version": "999.0-r0", "epoch": 0}
        for entry in candidate["packages"]
    ]
    rejects(candidate)


def rejects_architecture_path_mismatch() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    for entries in (candidate["packages"], archive["manifest"]["packages"]):
        for entry in entries:
            entry["architecture"] = "aarch64" if entry["architecture"] == "x86_64" else "x86_64"
    candidate["archive"] = archive
    rejects(candidate)


def rejects_duplicate_package_reuse() -> None:
    candidate = state()
    archive = copy.deepcopy(candidate["archive"])
    source = candidate["packages"][0]
    candidate["packages"][1] = {
        **candidate["packages"][1],
        "path": source["path"],
        "sha256": source["sha256"],
    }
    manifest_source = archive["manifest"]["packages"][0]
    archive["manifest"]["packages"][1] = {
        **archive["manifest"]["packages"][1],
        "path": manifest_source["path"],
        "sha256": manifest_source["sha256"],
    }
    candidate["archive"] = archive
    rejects(candidate)


def rejects_forged_archive_metadata() -> None:
    candidate = state()
    digest = "sha256:" + "0" * 64
    candidate["asset"] = {**candidate["asset"], "sha256": digest}
    candidate["archive"] = {
        **candidate["archive"],
        "sha256": digest,
        "manifestSha256": "0" * 64,
    }
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
    assert renovate["automerge"] is False
    assert renovate["platformAutomerge"] is False
    assert renovate["automergeType"] == "pr"
    assert renovate["prCreation"] == "immediate"
    assert any(
        rule.get("matchFileNames") == ["packages/repository-state.json"]
        and rule.get("labels") == ["apk-repository-state", "review-required"]
        for rule in rules
    )
    assert any(
        rule.get("matchPackageNames") == ["*"]
        and rule.get("automerge") is False
        and rule.get("platformAutomerge") is False
        and rule.get("automergeType") == "pr"
        and rule.get("prCreation") == "immediate"
        for rule in rules
    )
    assert all(rule.get("automerge", False) is False for rule in rules)
    assert all(rule.get("platformAutomerge", False) is False for rule in rules)
    assert all(rule.get("automergeType", "pr") == "pr" for rule in rules)
    assert all(rule.get("prCreation", "immediate") == "immediate" for rule in rules)


def main() -> None:
    valid_state()
    rejects_invalid_owner()
    rejects_noncanonical_tag()
    rejects_substituted_release_identity()
    rejects_wrong_fixed_asset_name()
    rejects_malformed_digest()
    rejects_mismatched_digest()
    rejects_key_mismatch()
    rejects_duplicate_package_identity()
    rejects_substituted_package_identity()
    rejects_architecture_path_mismatch()
    rejects_duplicate_package_reuse()
    rejects_forged_archive_metadata()
    rejects_unsupported_architecture()
    rejects_missing_architecture()
    rejects_wrong_archive_root()
    rejects_manifest_self_hash()
    updater_requires_review()


if __name__ == "__main__":
    main()
