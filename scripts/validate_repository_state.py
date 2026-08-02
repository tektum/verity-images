#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/validate_repository_state.py [STATE] [--live] [--archive ARCHIVE] [--pages DIRECTORY]

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


def archive_paths(state: dict[str, object]) -> tuple[str, ...]:
    archive = mapping(field(state, "archive"), "archive")
    root = text(field(archive, "root"), "archive.root")
    manifest = mapping(field(archive, "manifest"), "archive.manifest")
    packages = entries(field(manifest, "packages"), "archive.manifest.packages")
    paths = [root, f"{root}/manifest.json"]
    for architecture in sorted(ARCHITECTURES):
        paths.append(f"{root}/{architecture}")
        paths.append(f"{root}/{architecture}/APKINDEX.tar.gz")
    paths.extend(f"{root}/{text(field(package, 'path'), 'package.path')}" for package in packages)
    return tuple(paths)


def archive_file(archive_path: Path, member: str) -> bytes:
    result = subprocess.run(
        ["tar", "--zstd", "-xOf", str(archive_path), member],
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise StateError(f"archive member is unavailable: {member}")
    return result.stdout


def validate_archive_members(state: dict[str, object], archive_path: Path) -> tuple[str, ...]:
    result = subprocess.run(
        ["tar", "--zstd", "--quoting-style=literal", "-tvf", str(archive_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise StateError("archive listing failed")
    paths = archive_paths(state)
    expected = set(paths)
    actual: set[str] = set()
    for line in result.stdout.splitlines():
        if not line or line[0] not in {"-", "d"}:
            raise StateError("archive contains unsafe entry")
        member = line.rsplit(" ", maxsplit=1)[-1].rstrip("/")
        if member not in expected:
            raise StateError("archive contains unexpected member")
        if member in actual:
            raise StateError("archive contains duplicate member")
        actual.add(member)
        if member == paths[0] or member.endswith(tuple(ARCHITECTURES)):
            if line[0] != "d":
                raise StateError("archive directory is not a directory")
        elif line[0] != "-":
            raise StateError("archive member is not a regular file")
    if actual != expected:
        raise StateError("archive member set mismatch")
    return paths


def stage_archive(state: dict[str, object], archive_path: Path, destination: Path) -> None:
    root = archive_paths(state)[0]
    for member in validate_archive_members(state, archive_path):
        relative = Path(member).relative_to(root)
        if not relative.parts:
            continue
        target = destination / root / relative
        if member.endswith(tuple(ARCHITECTURES)):
            target.mkdir(parents=True, exist_ok=False)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive_file(archive_path, member))
    key = mapping(field(state, "key"), "key")
    key_path = ROOT / text(field(key, "path"), "key.path")
    (destination / root / key_path.name).write_bytes(key_path.read_bytes())


def validate_archive(state: dict[str, object], archive_path: Path) -> None:
    pinned = read_state(PINNED_STATE)
    archive = mapping(field(pinned, "archive"), "archive")
    manifest_path = f"{text(field(archive, 'root'), 'archive.root')}/manifest.json"
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    asset = mapping(field(pinned, "asset"), "asset")
    if f"sha256:{digest}" != field(asset, "sha256"):
        raise StateError("archive digest mismatch")
    manifest_bytes = archive_file(archive_path, manifest_path)
    if hashlib.sha256(manifest_bytes).hexdigest() != field(archive, "manifestSha256"):
        raise StateError("archive manifest digest mismatch")
    manifest = json.loads(manifest_bytes)
    if manifest != field(archive, "manifest"):
        raise StateError("archive manifest mismatch")
    with tempfile.TemporaryDirectory() as temporary:
        stage_archive(state, archive_path, Path(temporary))
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
    archive_path: Path | None = None
    pages_path: Path | None = None
    while arguments:
        option = arguments.pop(0)
        match option:
            case "--live":
                validate_live(state)
            case "--archive" if arguments:
                archive_path = Path(arguments.pop(0))
                validate_archive(state, archive_path)
            case "--pages" if arguments:
                pages_path = Path(arguments.pop(0))
            case _:
                raise SystemExit("usage: validate_repository_state.py [STATE] [--live] [--archive ARCHIVE] [--pages DIRECTORY]")
    if pages_path is not None:
        if archive_path is None:
            raise SystemExit("--pages requires --archive")
        stage_archive(state, archive_path, pages_path)


if __name__ == "__main__":
    main()
