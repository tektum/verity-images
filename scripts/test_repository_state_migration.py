from __future__ import annotations

import copy
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

import compose_apk_inputs
import repository_state_validation
import validate_repository_state
from test_assemble_apk_snapshot import assemble, fingerprint, melange_shim
from test_compose_apk_inputs import base_snapshot


def generated_v0003_state(root: Path) -> tuple[dict[str, object], Path]:
    state_path, base = base_snapshot(root, 1, "verity-apk-2026.rsa")
    composition = root / "composition.json"
    composition.write_text(
        json.dumps({"schemaVersion": 1, "releaseTag": "apk-repo-v0003", "replacement": None}),
        encoding="utf-8",
    )
    staged = root / "staged"
    compose_apk_inputs.compose(state_path, base, composition, staged)
    key = base / "verity-apk-2026.rsa"
    metadata_path = staged / "metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["fingerprint"] = fingerprint(key)
    metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
    binary, _ = melange_shim(root)
    repository = root / "repository"
    archive_path = root / "verity-apk-repository.tar.zst"
    result = assemble(staged, repository, archive_path, key, binary)
    assert result.returncode == 0, result.stderr

    manifest_path = repository / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    archive_sha256 = "sha256:" + hashlib.sha256(archive_path.read_bytes()).hexdigest()
    state = {
        "schemaVersion": 2,
        "repository": "tektum/verity-images",
        "release": {"id": 3, "tag": "apk-repo-v0003", "targetCommit": "3" * 40, "immutable": True},
        "asset": {"id": 4, "name": "verity-apk-repository.tar.zst", "sha256": archive_sha256},
        "archive": {
            "root": "apk",
            "sha256": archive_sha256,
            "manifestSha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "manifest": manifest,
        },
        "key": {"path": "packages/keys/verity-apk-2026.rsa.pub", "fingerprint": fingerprint(key)},
        "packages": copy.deepcopy(manifest["packages"]),
    }
    public_key = root / "packages/keys/verity-apk-2026.rsa.pub"
    public_key.parent.mkdir(parents=True)
    shutil.copy2(key.with_suffix(".rsa.pub"), public_key)
    return state, archive_path


def migration_state_and_archive_are_valid() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, archive_path = generated_v0003_state(root)
        state_path = root / "repository-state.json"
        state_path.write_text(json.dumps(state), encoding="utf-8")
        with (
            patch.object(repository_state_validation, "ROOT", root),
            patch.object(validate_repository_state, "ROOT", root),
        ):
            repository_state_validation.validate_v2(state)
            validate_repository_state.validate_archive(state, archive_path)
        schema = subprocess.run(
            ["check-jsonschema", "--schemafile", "packages/repository-state.schema.json", str(state_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert schema.returncode == 0, schema.stderr


def altered_historical_provenance_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, _ = generated_v0003_state(root)
        mutations = (
            ("releaseId", 3, "legacy snapshot release id mismatch", True),
            ("releaseTag", "apk-repo-v0003", "legacy snapshot release tag mismatch", True),
            ("targetCommit", "9" * 40, "legacy snapshot target commit mismatch", False),
            ("assetId", 9, "legacy snapshot asset id mismatch", False),
            ("assetSha256", "sha256:" + "9" * 64, "legacy snapshot asset digest mismatch", False),
            ("manifestSha256", "9" * 64, "legacy snapshot manifest digest mismatch", False),
            ("sourcePath", "aarch64/other.apk", "legacy snapshot source path mismatch", False),
        )
        with patch.object(repository_state_validation, "ROOT", root):
            for field, value, expected, mutate_all in mutations:
                candidate = copy.deepcopy(state)
                indexes = range(len(candidate["packages"])) if mutate_all else (0,)
                for index in indexes:
                    candidate["packages"][index]["origin"][field] = value
                    candidate["archive"]["manifest"]["packages"][index]["origin"][field] = value
                try:
                    repository_state_validation.validate_v2(candidate)
                except repository_state_validation.StateError as error:
                    assert str(error) == expected
                else:
                    raise AssertionError(f"altered historical {field} was accepted")


def main() -> None:
    migration_state_and_archive_are_valid()
    altered_historical_provenance_is_rejected()


if __name__ == "__main__":
    main()
