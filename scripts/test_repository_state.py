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

import test_repository_state_v2 as v2_tests
import validate_repository_state as validator


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
    assert candidate["schemaVersion"] == 2
    assert candidate["release"] == {
        "id": 366688435,
        "tag": "apk-repo-v0004",
        "targetCommit": "be06c720a52496262c1d6aa210af2d02536046f3",
        "immutable": True,
    }
    assert candidate["asset"]["id"] == 505040937
    assert candidate["asset"]["sha256"] == "sha256:52ad0e8fdb04d389bca3d2f670edb87c3aa42bfbc10755d2941d9b7ceab6d50e"
    assert candidate["archive"]["manifestSha256"] == "c48c9301dd4676be389116d59e8592bb0e8ab2bc3c3c5f4422bef681e518609d"
    assert candidate["key"] == {
        "path": "packages/keys/verity-apk-2026.rsa.pub",
        "fingerprint": "764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698",
    }
    assert {(entry["architecture"], entry["name"], entry["version"], entry["epoch"], entry["path"], entry["sha256"]) for entry in candidate["packages"]} == {
        ("x86_64", "openssl-fips-provider", "3.1.2-r3", 3, "x86_64/openssl-fips-provider-3.1.2-r3.apk", "d5d67155c6689825d9eb9ec218adfafa017e88d11204d2e206b6e1c50125cb34"),
        ("aarch64", "openssl-fips-provider", "3.1.2-r3", 3, "aarch64/openssl-fips-provider-3.1.2-r3.apk", "d3479205b01250d98c9e167d467f4af6f839bddf591ce453b5d6fca9b68c294a"),
        ("x86_64", "gosu", "1.19-r0", 0, "x86_64/gosu-1.19-r0.apk", "e34eaeaa7d901f18b115e31624528d7d5161336621adeb501c47457bdb73a553"),
        ("aarch64", "gosu", "1.19-r0", 0, "aarch64/gosu-1.19-r0.apk", "c4b0a87c4047a36e1e06eab4781cb1c50b2c991b6b5c64720360489d264b9256"),
    }
    assert all(entry["origin"]["releaseTag"] == "apk-repo-v0002" for entry in candidate["packages"] if entry["name"] == "openssl-fips-provider")
    assert all(entry["origin"]["sourceCommit"] == "be06c720a52496262c1d6aa210af2d02536046f3" for entry in candidate["packages"] if entry["name"] == "gosu")


def v1_rollback_state_remains_valid() -> None:
    candidate = state()
    # Only legacy-snapshot packages describe a v1 release, so an attested build is not a rollback target.
    snapshot = [package for package in candidate["packages"] if package["origin"]["type"] == "legacy-snapshot"]
    packages = [{key: value for key, value in package.items() if key != "origin"} for package in snapshot]
    origin = snapshot[0]["origin"]
    candidate["schemaVersion"] = 1
    candidate["release"] = {
        "id": origin["releaseId"],
        "tag": origin["releaseTag"],
        "targetCommit": origin["targetCommit"],
        "immutable": True,
    }
    candidate["asset"] = {
        "id": origin["assetId"],
        "name": "verity-apk-repository.tar.zst",
        "sha256": origin["assetSha256"],
    }
    candidate["archive"] = {
        "root": "apk",
        "sha256": origin["assetSha256"],
        "manifestSha256": origin["manifestSha256"],
        "manifest": {
            "architectures": ["x86_64", "aarch64"],
            "fingerprint": candidate["key"]["fingerprint"],
            "packages": [{key: package[key] for key in ("architecture", "path", "sha256")} for package in packages],
        },
    }
    candidate["packages"] = packages
    validator.validate_v1(candidate)


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
    assert renovate["automerge"] is True
    assert renovate["platformAutomerge"] is True
    assert renovate["automergeType"] == "pr"
    assert renovate["prCreation"] == "immediate"
    assert any(
        rule.get("matchFileNames") == ["packages/repository-state.json"]
        and rule.get("automerge") is False
        and rule.get("labels") == ["apk-repository-state", "review-required"]
        for rule in rules
    )
    assert not any(
        rule.get("matchPackageNames") == ["*"] and rule.get("automerge") is False
        for rule in rules
    )
    assert all(rule.get("automerge", False) is False for rule in rules)
    assert all(rule.get("platformAutomerge", False) is False for rule in rules)
    assert all(rule.get("automergeType", "pr") == "pr" for rule in rules)
    assert all(rule.get("prCreation", "immediate") == "immediate" for rule in rules)


def main() -> None:
    valid_state()
    v1_rollback_state_remains_valid()
    v2_tests.main()
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
