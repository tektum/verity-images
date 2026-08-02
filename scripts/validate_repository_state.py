#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/validate_repository_state.py [STATE] [--live] [--archive ARCHIVE]

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Final

from apk_repository_policy import validate as validate_repository


ROOT: Final = Path(__file__).resolve().parents[1]
DEFAULT_STATE: Final = ROOT / "packages/repository-state.json"
PINNED_STATE: Final = ROOT / "packages/repository-state.pin.json"
ARCHITECTURES: Final = frozenset({"x86_64", "aarch64"})


class StateError(ValueError):
    pass


def key_fingerprint(path: Path) -> str:
    result = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", str(path), "-pubout", "-outform", "DER"],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise StateError("unable to read repository key")
    return hashlib.sha256(result.stdout).hexdigest()


def read_state(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise StateError("repository state must be an object")
    return value


def field(value: dict[str, object], name: str) -> object:
    try:
        return value[name]
    except KeyError as error:
        raise StateError(f"missing state field: {name}") from error


def mapping(value: object, name: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise StateError(f"invalid object: {name}")
    return value


def entries(value: object, name: str) -> list[dict[str, object]]:
    if not isinstance(value, list) or not all(isinstance(entry, dict) for entry in value):
        raise StateError(f"invalid entries: {name}")
    return value


def text(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise StateError(f"invalid text: {name}")
    return value


def validate(state: dict[str, object]) -> None:
    if state != read_state(PINNED_STATE):
        raise StateError("repository state differs from reviewed pin contract")
    release = mapping(field(state, "release"), "release")
    asset = mapping(field(state, "asset"), "asset")
    archive = mapping(field(state, "archive"), "archive")
    manifest = mapping(field(archive, "manifest"), "archive.manifest")
    key = mapping(field(state, "key"), "key")
    package_entries = entries(field(state, "packages"), "packages")
    manifest_entries = entries(field(manifest, "packages"), "archive.manifest.packages")
    manifest_architectures = field(manifest, "architectures")
    if field(state, "repository") != "tektum/verity-images":
        raise StateError("unexpected repository")
    if not text(field(release, "tag"), "release.tag").startswith("apk-repo-v"):
        raise StateError("noncanonical release tag")
    if text(field(asset, "name"), "asset.name") != "verity-apk-repository.tar.zst":
        raise StateError("unexpected asset name")
    if field(archive, "root") != "apk":
        raise StateError("unexpected archive root")
    if field(asset, "sha256") != field(archive, "sha256"):
        raise StateError("release asset and archive digest mismatch")
    if "sha256" in manifest:
        raise StateError("archive manifest must not hash itself")
    if field(manifest, "fingerprint") != field(key, "fingerprint"):
        raise StateError("manifest and key fingerprint mismatch")
    if text(field(key, "fingerprint"), "key.fingerprint") != key_fingerprint(ROOT / text(field(key, "path"), "key.path")):
        raise StateError("active key fingerprint mismatch")
    if not isinstance(manifest_architectures, list) or set(manifest_architectures) != ARCHITECTURES:
        raise StateError("unexpected manifest architectures")
    if {entry["architecture"] for entry in package_entries} != ARCHITECTURES:
        raise StateError("unexpected package architectures")
    if len(package_entries) != len(ARCHITECTURES) or len(manifest_entries) != len(ARCHITECTURES):
        raise StateError("duplicate package entries")
    if len({(entry["name"], entry["version"], entry["epoch"]) for entry in package_entries}) != 1:
        raise StateError("duplicate or mismatched package identity")
    for entry in (*package_entries, *manifest_entries):
        if Path(text(entry["path"], "package.path")).parts[0] != entry["architecture"]:
            raise StateError("package architecture and path mismatch")
    for entries_to_check in (package_entries, manifest_entries):
        if len({entry["path"] for entry in entries_to_check}) != len(entries_to_check):
            raise StateError("duplicate package paths")
        if len({entry["sha256"] for entry in entries_to_check}) != len(entries_to_check):
            raise StateError("duplicate package digests")
    bindings = {(entry["architecture"], entry["path"], entry["sha256"]) for entry in package_entries}
    manifest_bindings = {(entry["architecture"], entry["path"], entry["sha256"]) for entry in manifest_entries}
    if bindings != manifest_bindings:
        raise StateError("package manifest mismatch")


def validate_archive(state: dict[str, object], archive_path: Path) -> None:
    pinned = read_state(PINNED_STATE)
    archive = mapping(field(pinned, "archive"), "archive")
    manifest_path = f"{text(field(archive, 'root'), 'archive.root')}/manifest.json"
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    asset = mapping(field(pinned, "asset"), "asset")
    if f"sha256:{digest}" != field(asset, "sha256"):
        raise StateError("archive digest mismatch")
    result = subprocess.run(
        ["tar", "--zstd", "-xOf", str(archive_path), manifest_path],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise StateError("archive manifest is unavailable")
    if hashlib.sha256(result.stdout).hexdigest() != field(archive, "manifestSha256"):
        raise StateError("archive manifest digest mismatch")
    manifest = json.loads(result.stdout)
    if manifest != field(archive, "manifest"):
        raise StateError("archive manifest mismatch")
    with tempfile.TemporaryDirectory() as temporary:
        result = subprocess.run(
            ["tar", "--zstd", "-xf", str(archive_path), "-C", temporary],
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise StateError("archive extraction failed")
        validate_repository(
            Path(temporary) / text(field(archive, "root"), "archive.root"),
            ROOT / "packages/keys",
            text(field(archive, "manifestSha256"), "archive.manifestSha256"),
        )


def validate_live(state: dict[str, object]) -> None:
    release = mapping(field(state, "release"), "release")
    asset = mapping(field(state, "asset"), "asset")
    result = subprocess.run(
        ["gh", "api", f"repos/{field(state, 'repository')}/releases/{field(release, 'id')}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise StateError("release lookup failed")
    live = json.loads(result.stdout)
    if not isinstance(live, dict):
        raise StateError("invalid release lookup")
    expected_release = {"id": field(release, "id"), "tag_name": field(release, "tag"), "target_commitish": field(release, "targetCommit"), "immutable": True, "draft": False, "prerelease": False}
    if any(live.get(name) != value for name, value in expected_release.items()):
        raise StateError("release state mismatch")
    assets = live.get("assets")
    if not isinstance(assets, list) or len(assets) != 1 or not isinstance(assets[0], dict):
        raise StateError("release must contain exactly one asset")
    expected_asset = {"id": field(asset, "id"), "name": field(asset, "name"), "digest": field(asset, "sha256"), "state": "uploaded"}
    if any(assets[0].get(name) != value for name, value in expected_asset.items()):
        raise StateError("release asset mismatch")


def main() -> None:
    arguments = sys.argv[1:]
    state_path = DEFAULT_STATE
    if arguments and not arguments[0].startswith("--"):
        state_path = Path(arguments.pop(0))
    state = read_state(state_path)
    validate(state)
    while arguments:
        option = arguments.pop(0)
        match option:
            case "--live":
                validate_live(state)
            case "--archive" if arguments:
                validate_archive(state, Path(arguments.pop(0)))
            case _:
                raise SystemExit("usage: validate_repository_state.py [STATE] [--live] [--archive ARCHIVE]")


if __name__ == "__main__":
    main()
