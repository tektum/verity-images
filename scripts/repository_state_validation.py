from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path
from typing import Final


ROOT: Final = Path(__file__).resolve().parents[1]
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


def snapshot_fields(
    state: dict[str, object],
) -> tuple[dict[str, object], dict[str, object], dict[str, object], list[dict[str, object]], list[dict[str, object]]]:
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
    for entry in (*package_entries, *manifest_entries):
        if Path(text(entry["path"], "package.path")).parts[0] != entry["architecture"]:
            raise StateError("package architecture and path mismatch")
    for entries_to_check in (package_entries, manifest_entries):
        if len({entry["path"] for entry in entries_to_check}) != len(entries_to_check):
            raise StateError("duplicate package paths")
        if len({entry["sha256"] for entry in entries_to_check}) != len(entries_to_check):
            raise StateError("duplicate package digests")
    return release, asset, archive, package_entries, manifest_entries


def validate_v1(state: dict[str, object]) -> None:
    _, _, _, package_entries, manifest_entries = snapshot_fields(state)
    if {entry["architecture"] for entry in package_entries} != ARCHITECTURES:
        raise StateError("unexpected package architectures")
    if len(package_entries) != len(ARCHITECTURES) or len(manifest_entries) != len(ARCHITECTURES):
        raise StateError("duplicate package entries")
    if len({(entry["name"], entry["version"], entry["epoch"]) for entry in package_entries}) != 1:
        raise StateError("duplicate or mismatched package identity")
    bindings = {(entry["architecture"], entry["path"], entry["sha256"]) for entry in package_entries}
    manifest_bindings = {(entry["architecture"], entry["path"], entry["sha256"]) for entry in manifest_entries}
    if bindings != manifest_bindings:
        raise StateError("package manifest mismatch")


def validate_v2(state: dict[str, object]) -> None:
    release, _, archive, package_entries, manifest_entries = snapshot_fields(state)
    manifest = mapping(field(archive, "manifest"), "archive.manifest")
    if field(manifest, "schemaVersion") != 2:
        raise StateError("unexpected archive manifest schema version")
    if package_entries != manifest_entries:
        raise StateError("package manifest mismatch")
    architectures_by_package: dict[tuple[object, object, object], set[object]] = {}
    legacy_snapshot: dict[str, object] | None = None
    legacy_labels = {
        "releaseId": "release id",
        "releaseTag": "release tag",
        "targetCommit": "target commit",
        "assetId": "asset id",
        "assetSha256": "asset digest",
        "manifestSha256": "manifest digest",
    }
    for entry in package_entries:
        identity = (field(entry, "name"), field(entry, "version"), field(entry, "epoch"))
        architectures = architectures_by_package.setdefault(identity, set())
        architecture = field(entry, "architecture")
        if architecture in architectures:
            raise StateError("duplicate package architecture")
        architectures.add(architecture)
        origin = mapping(field(entry, "origin"), "package.origin")
        match field(origin, "type"):
            case "legacy-snapshot":
                historical = {name: field(origin, name) for name in legacy_labels}
                if historical["releaseId"] == field(release, "id"):
                    raise StateError("legacy snapshot release id mismatch")
                if historical["releaseTag"] == field(release, "tag"):
                    raise StateError("legacy snapshot release tag mismatch")
                if legacy_snapshot is None:
                    legacy_snapshot = historical
                for name, value in historical.items():
                    if legacy_snapshot[name] != value:
                        raise StateError(f"legacy snapshot {legacy_labels[name]} mismatch")
                if field(origin, "sourcePath") != field(entry, "path"):
                    raise StateError("legacy snapshot source path mismatch")
            case "attested-build":
                for name in (
                    "sourceCommit", "buildWorkflowId", "buildRunId", "buildArtifactId", "buildArtifactSha256",
                    "unsignedSha256", "signingWorkflowId", "signingRunId", "bundlePath", "bundleSha256",
                ):
                    field(origin, name)
            case origin_type:
                raise StateError(f"unsupported package origin: {origin_type}")
    if not architectures_by_package or any(architectures != ARCHITECTURES for architectures in architectures_by_package.values()):
        raise StateError("incomplete package architecture set")
