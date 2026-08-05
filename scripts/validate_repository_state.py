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

from apk_archive import read_archive
from apk_repository_policy import validate as validate_repository
from repository_state_validation import ARCHITECTURES, StateError, entries, field, mapping, text, validate_v1, validate_v2


ROOT: Final = Path(__file__).resolve().parents[1]
DEFAULT_STATE: Final = ROOT / "packages/repository-state.json"
PINNED_STATE: Final = ROOT / "packages/repository-state.pin.json"


def read_state(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise StateError("repository state must be an object")
    return value


def validate(state: dict[str, object]) -> None:
    version = field(state, "schemaVersion")
    match version:
        case 1:
            validate_v1(state)
        case 2:
            validate_v2(state)
        case _:
            raise StateError(f"unsupported repository state schema version: {version}")
    if state != read_state(PINNED_STATE):
        raise StateError("repository state differs from reviewed pin contract")


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
    bundles = {
        text(field(origin, "bundlePath"), "package.origin.bundlePath")
        for package in packages
        if "origin" in package
        and field((origin := mapping(field(package, "origin"), "package.origin")), "type") == "attested-build"
    }
    directories = {str(path) for bundle in bundles for path in Path(root, bundle).parents if str(path) != "."}
    paths.extend(sorted(directories - set(paths)))
    paths.extend(f"{root}/{bundle}" for bundle in sorted(bundles))
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
    directories = {path for path in paths if any(candidate.startswith(f"{path}/") for candidate in paths)}
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
        if member in directories:
            if line[0] != "d":
                raise StateError("archive directory is not a directory")
        elif line[0] != "-":
            raise StateError("archive member is not a regular file")
    if actual != expected:
        raise StateError("archive member set mismatch")
    return paths


def stage_archive(state: dict[str, object], archive_path: Path, destination: Path) -> None:
    root = archive_paths(state)[0]
    members = validate_archive_members(state, archive_path)
    directories = {member for member in members if any(candidate.startswith(f"{member}/") for candidate in members)}
    for member in members:
        relative = Path(member).relative_to(root)
        if not relative.parts:
            continue
        target = destination / root / relative
        if member in directories:
            try:
                target.mkdir(parents=True, exist_ok=False)
            except FileExistsError as error:
                raise StateError(f"destination already contains staged content: {target}") from error
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive_file(archive_path, member))
    key = mapping(field(state, "key"), "key")
    key_path = ROOT / text(field(key, "path"), "key.path")
    (destination / root / key_path.name).write_bytes(key_path.read_bytes())


def validate_archive(state: dict[str, object], archive_path: Path) -> None:
    archive = mapping(field(state, "archive"), "archive")
    manifest_path = f"{text(field(archive, 'root'), 'archive.root')}/manifest.json"
    digest = hashlib.sha256(read_archive(archive_path)).hexdigest()
    asset = mapping(field(state, "asset"), "asset")
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
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{field(state, 'repository')}/releases/{field(release, 'id')}"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise StateError("release lookup timed out") from error
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
