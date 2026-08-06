#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_repository_state_v2.py

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Final

import validate_repository_state as validator


ROOT: Final = Path(__file__).resolve().parents[1]
SCHEMA: Final = ROOT / "packages/repository-state.schema.json"
STATE: Final = ROOT / "packages/repository-state.json"


def state() -> dict[str, object]:
    return json.loads(STATE.read_text(encoding="utf-8"))


def v2_state() -> dict[str, object]:
    candidate = state()
    candidate["schemaVersion"] = 2
    candidate["release"] = {"id": 4, "tag": "apk-repo-v0003", "targetCommit": "4" * 40, "immutable": True}
    candidate["asset"] = {"id": 5, "name": "verity-apk-repository.tar.zst", "sha256": "sha256:" + "7" * 64}
    packages = copy.deepcopy(candidate["packages"])
    for entry in copy.deepcopy(packages):
        entry["name"] = "openssl-fips-provider-next"
        entry["version"] = "3.2.0-r0"
        entry["epoch"] = 0
        entry["path"] = entry["path"].replace("3.1.2-r3", "3.2.0-r0")
        entry["sha256"] = "1" * 64 if entry["architecture"] == "aarch64" else "2" * 64
        entry["origin"] = {
            "type": "attested-build",
            "sourceCommit": "3" * 40,
            "buildWorkflowId": 101,
            "buildRunId": 102,
            "buildArtifactId": 103,
            "buildArtifactSha256": "sha256:" + "4" * 64,
            "unsignedSha256": "5" * 64,
            "signingWorkflowId": 201,
            "signingRunId": 202,
            "bundlePath": f"bundles/{entry['name']}/{entry['architecture']}.json",
            "bundleSha256": "6" * 64,
        }
        packages.append(entry)
    candidate["packages"] = packages
    archive = copy.deepcopy(candidate["archive"])
    archive["sha256"] = candidate["asset"]["sha256"]
    archive["manifest"] = {**archive["manifest"], "schemaVersion": 2, "packages": copy.deepcopy(packages)}
    candidate["archive"] = archive
    return candidate


def schema_validate(candidate: dict[str, object]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "repository-state.json"
        path.write_text(json.dumps(candidate), encoding="utf-8")
        return subprocess.run(
            ["check-jsonschema", "--schemafile", str(SCHEMA), str(path)],
            capture_output=True,
            text=True,
            check=False,
        )


def semantic_error(candidate: dict[str, object]) -> str:
    try:
        validator.validate(candidate)
    except validator.StateError as error:
        return str(error)
    raise AssertionError("state was accepted")


def valid_v2_state() -> None:
    candidate = v2_state()
    assert schema_validate(candidate).returncode == 0
    validator.validate_v2(candidate)
    assert semantic_error(candidate) == "repository state differs from reviewed pin contract"


def rejects_unknown_schema_version() -> None:
    candidate = state()
    candidate["schemaVersion"] = 3
    assert semantic_error(candidate) == "unsupported repository state schema version: 3"


def rejects_v2_mutated_origin_digest_before_pin_gate() -> None:
    candidate = v2_state()
    candidate["packages"][0]["origin"]["assetSha256"] = "sha256:" + "0" * 64
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert semantic_error(candidate) == "legacy snapshot asset digest mismatch"


def rejects_v2_duplicate_package_architecture() -> None:
    candidate = v2_state()
    candidate["packages"][1]["architecture"] = "aarch64"
    candidate["packages"][1]["path"] = "aarch64/openssl-fips-provider-duplicate.apk"
    candidate["packages"][1]["origin"]["sourcePath"] = candidate["packages"][1]["path"]
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert semantic_error(candidate) == "duplicate package architecture"


def rejects_v2_missing_package_architecture() -> None:
    candidate = v2_state()
    candidate["packages"].pop(1)
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert semantic_error(candidate) == "incomplete package architecture set"


def rejects_v2_manifest_package_divergence() -> None:
    candidate = v2_state()
    candidate["archive"]["manifest"]["packages"][0]["sha256"] = "0" * 64
    assert semantic_error(candidate) == "package manifest mismatch"


def rejects_v2_unknown_property() -> None:
    candidate = v2_state()
    candidate["packages"][0]["origin"]["unexpected"] = True
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert schema_validate(candidate).returncode != 0


def rejects_attested_build_unknown_property() -> None:
    candidate = v2_state()
    candidate["packages"][2]["origin"]["unexpected"] = True
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert schema_validate(candidate).returncode != 0


def rejects_attested_build_without_source_commit() -> None:
    candidate = v2_state()
    del candidate["packages"][2]["origin"]["sourceCommit"]
    candidate["archive"]["manifest"]["packages"] = copy.deepcopy(candidate["packages"])
    assert schema_validate(candidate).returncode != 0


def supplied_state_drives_archive_validation() -> None:
    candidate = state()
    with tempfile.TemporaryDirectory() as temporary:
        manifest = copy.deepcopy(candidate["archive"]["manifest"])
        manifest["fingerprint"] = "0" * 64
        manifest_bytes = json.dumps(manifest).encode()
        fixture = Path(temporary) / "apk"
        fixture.mkdir()
        (fixture / "manifest.json").write_bytes(manifest_bytes)
        path = Path(temporary) / "repository.tar.zst"
        subprocess.run(["tar", "--zstd", "-cf", str(path), "-C", temporary, "apk"], check=True)
        digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        candidate["asset"] = {**candidate["asset"], "sha256": digest}
        candidate["archive"] = {
            **candidate["archive"],
            "sha256": digest,
            "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "manifest": manifest,
        }
        try:
            validator.validate_archive(candidate, path)
        except validator.StateError as error:
            assert str(error) == "archive member set mismatch"
        else:
            raise AssertionError("invalid archive was accepted")


def main() -> None:
    valid_v2_state()
    rejects_unknown_schema_version()
    rejects_v2_mutated_origin_digest_before_pin_gate()
    rejects_v2_duplicate_package_architecture()
    rejects_v2_missing_package_architecture()
    rejects_v2_manifest_package_divergence()
    rejects_v2_unknown_property()
    rejects_attested_build_unknown_property()
    rejects_attested_build_without_source_commit()
    supplied_state_drives_archive_validation()


if __name__ == "__main__":
    main()
