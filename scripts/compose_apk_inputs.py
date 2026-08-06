#!/usr/bin/env -S uv run --script
# noqa: SIZE_OK -- composition stays linear so rollback invariants remain visible
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# How to run
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run scripts/compose_apk_inputs.py STATE BASE METADATA OUTPUT
# 3. Or make executable and run:
#      chmod +x scripts/compose_apk_inputs.py && ./scripts/compose_apk_inputs.py STATE BASE METADATA OUTPUT
# End run instructions

from __future__ import annotations

import filecmp
import hashlib
import json
import re
import shutil
import signal
import sys
import tempfile
from pathlib import Path
from types import FrameType

from apk_publication import publish
from apk_repository_policy import checked_package
from repository_state_validation import ARCHITECTURES, StateError, entries, field, mapping, text, validate_v1, validate_v2


type JsonValue = object  # noqa: E501  # noqa: OBJECT_OK -- repository validator compatibility boundary
type JsonObject = dict[str, JsonValue]
ComposeError = fail = StateError


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path, name: str) -> JsonObject:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise fail(f"invalid {name}: {path}") from error
    if not isinstance(value, dict):
        raise fail(f"invalid {name}: {path}")
    return value


def safe_relative(value: JsonValue, name: str) -> str:
    path = Path(text(value, name))
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise fail(f"unsafe {name}")
    return path.as_posix()


def package_sort_key(package: JsonObject) -> tuple[str, str, int, str, str]:
    epoch = field(package, "epoch")
    if not isinstance(epoch, int):
        raise fail("invalid package epoch")
    return (
        text(field(package, "name"), "package.name"),
        text(field(package, "version"), "package.version"),
        epoch,
        text(field(package, "architecture"), "package.architecture"),
        safe_relative(field(package, "path"), "package.path"),
    )


def bundle_path(package: JsonObject) -> str | None:
    origin = mapping(field(package, "origin"), "package.origin")
    match field(origin, "type"):  # noqa: E501  # noqa: MATCH_OK -- untrusted JSON variant is checked at runtime
        case "legacy-snapshot":
            return None
        case "attested-build":
            return safe_relative(field(origin, "bundlePath"), "package.origin.bundlePath")
        case origin_type:
            raise fail(f"unsupported package origin: {origin_type}")


def base_packages(state: JsonObject) -> list[JsonObject]:
    packages = [json.loads(json.dumps(package)) for package in entries(field(state, "packages"), "packages")]
    if field(state, "schemaVersion") == 2:
        return packages
    release = mapping(field(state, "release"), "release")
    asset = mapping(field(state, "asset"), "asset")
    archive = mapping(field(state, "archive"), "archive")
    for package in packages:
        package["origin"] = {
            "type": "legacy-snapshot",
            "releaseId": field(release, "id"),
            "releaseTag": field(release, "tag"),
            "targetCommit": field(release, "targetCommit"),
            "assetId": field(asset, "id"),
            "assetSha256": field(asset, "sha256"),
            "manifestSha256": field(archive, "manifestSha256"),
            "sourcePath": field(package, "path"),
        }
    return packages


def expected_members(packages: list[JsonObject]) -> tuple[set[str], set[str]]:
    package_paths = {safe_relative(field(package, "path"), "package.path") for package in packages}
    bundles = {path for package in packages if (path := bundle_path(package)) is not None}
    if len(package_paths) != len(packages):
        raise fail("duplicate package path")
    return package_paths, bundles


def validate_staged(root: Path, manifest: JsonObject) -> list[JsonObject]:
    fingerprint = field(manifest, "fingerprint")
    if field(manifest, "schemaVersion") != 2 or field(manifest, "architectures") != sorted(ARCHITECTURES) or not isinstance(fingerprint, str) or len(fingerprint) != 64:
        raise fail("invalid schema-v2 metadata")
    packages = entries(field(manifest, "packages"), "packages")
    package_paths, bundle_paths = expected_members(packages)
    actual_packages = {path.relative_to(root).as_posix() for path in root.glob("*/*.apk")}
    actual_bundles = {path.relative_to(root).as_posix() for path in root.glob("bundles/**/*.json")}
    if actual_packages != package_paths or actual_bundles != bundle_paths:
        raise fail("staged member set mismatch")
    identities: dict[tuple[str, str, int], set[str]] = {}
    for package in packages:
        path = safe_relative(field(package, "path"), "package.path")
        architecture = text(field(package, "architecture"), "package.architecture")
        if architecture not in ARCHITECTURES or Path(path).parts[0] != architecture:
            raise fail("package architecture mismatch")
        if digest(root / path) != text(field(package, "sha256"), "package.sha256"):
            raise fail(f"package digest mismatch: {path}")
        identity = package_sort_key(package)[:3]
        identities.setdefault(identity, set()).add(architecture)
        origin = mapping(field(package, "origin"), "package.origin")
        bundle = bundle_path(package)
        if bundle is not None and digest(root / bundle) != text(field(origin, "bundleSha256"), "bundleSha256"):
            raise fail(f"bundle digest mismatch: {bundle}")
    if not identities or any(architectures != ARCHITECTURES for architectures in identities.values()):
        raise fail("incomplete package architecture set")
    return packages


def validate_base(state: JsonObject, base: Path) -> list[JsonObject]:
    version = field(state, "schemaVersion")
    try:
        match version:  # noqa: E501  # noqa: MATCH_OK -- untrusted JSON variant is checked at runtime
            case 1:
                validate_v1(state)
            case 2:
                validate_v2(state)
            case unsupported:
                raise fail(f"unsupported base schema version: {unsupported}")
    except StateError as error:
        raise fail(str(error)) from error
    archive = mapping(field(state, "archive"), "archive")
    manifest_path = base / "manifest.json"
    manifest = read_json(manifest_path, "base manifest")
    if manifest != field(archive, "manifest") or digest(manifest_path) != field(archive, "manifestSha256"):
        raise fail("base manifest mismatch")
    packages = base_packages(state)
    package_paths, bundle_paths = expected_members(packages)
    if {path.relative_to(base).as_posix() for path in base.glob("*/*.apk")} != package_paths:
        raise fail("base package set mismatch")
    if {path.relative_to(base).as_posix() for path in base.glob("bundles/**/*.json")} != bundle_paths:
        raise fail("base provenance set mismatch")
    key = mapping(field(state, "key"), "key")
    validate_staged(base, {"schemaVersion": 2, "architectures": sorted(ARCHITECTURES), "fingerprint": field(key, "fingerprint"), "packages": packages})
    return packages


def replacement_packages(value: JsonValue) -> tuple[str, list[JsonObject], list[tuple[Path, str, str]]]:
    replacement = mapping(value, "replacement")
    if set(replacement) != {"name", "packages"}:
        raise fail("invalid replacement metadata")
    name = text(field(replacement, "name"), "replacement.name")
    packages = entries(field(replacement, "packages"), "replacement.packages")
    if len(packages) != len(ARCHITECTURES):
        raise fail("replacement requires exactly one architecture pair")
    sources: list[tuple[Path, str, str]] = []
    final: list[JsonObject] = []
    for package in packages:
        if set(package) != {"architecture", "name", "version", "epoch", "path", "sha256", "sourceFile", "bundleFile", "origin"}:
            raise fail("invalid replacement package fields")
        source = Path(text(field(package, "sourceFile"), "replacement.sourceFile"))
        bundle_source = Path(text(field(package, "bundleFile"), "replacement.bundleFile"))
        clean = {key: package[key] for key in ("architecture", "name", "version", "epoch", "path", "sha256", "origin")}
        architecture = text(field(clean, "architecture"), "replacement.architecture")
        if not source.is_file() or not bundle_source.is_file():
            raise fail("invalid replacement file")
        info = checked_package(source, architecture)
        package_epoch = int(info.version.rpartition("-r")[2])
        if info.name != name or info.version != field(clean, "version") or package_epoch != field(clean, "epoch") or field(clean, "name") != name:
            raise fail("replacement identity mismatch")
        bundle = bundle_path(clean)
        if bundle is None or bundle != f"bundles/{name}/{architecture}.json":
            raise fail("invalid replacement bundle")
        if digest(source) != field(clean, "sha256"):
            raise fail("replacement digest mismatch")
        origin = mapping(field(clean, "origin"), "replacement.origin")
        if digest(bundle_source) != field(origin, "bundleSha256"):
            raise fail("replacement bundle digest mismatch")
        sources.extend(((source, safe_relative(field(clean, "path"), "replacement.path"), "package"), (bundle_source, bundle, "bundle")))
        final.append(clean)
    if {text(field(package, "architecture"), "architecture") for package in final} != ARCHITECTURES:
        raise fail("replacement architecture set mismatch")
    if len({package_sort_key(package)[:3] for package in final}) != 1:
        raise fail("replacement identity mismatch")
    return name, final, sources


def compose(state_path: Path, base: Path, input_path: Path, output: Path) -> None:
    if output.exists():
        raise fail(f"output already exists: {output}")
    state = read_json(state_path, "base state")
    inputs = read_json(input_path, "composition metadata")
    if set(inputs) != {"schemaVersion", "releaseTag", "replacement"} or field(inputs, "schemaVersion") != 1:
        raise fail("unsupported composition metadata schema")
    packages = validate_base(state, base)
    release = mapping(field(state, "release"), "release")
    base_tag = text(field(release, "tag"), "release.tag")
    match = re.fullmatch(r"apk-repo-v([0-9]{4})", base_tag)
    if match is None:
        raise fail("invalid base release tag")
    expected_tag = f"apk-repo-v{int(match.group(1)) + 1:04d}"
    if field(inputs, "releaseTag") != expected_tag:
        raise fail("composition release is not strictly next")
    replacement = field(inputs, "replacement")
    if field(state, "schemaVersion") == 1 and (expected_tag != "apk-repo-v0003" or replacement is not None):
        raise fail("schema-v1 base only supports v0003 migration")
    if field(state, "schemaVersion") == 2 and replacement is None:
        raise fail("schema-v2 no-op composition is forbidden")
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    source_by_member: dict[str, tuple[Path, str, bool]] = {}
    try:
        package_paths, bundle_paths = expected_members(packages)
        for member in sorted(package_paths | bundle_paths):
            source = base / member
            target = stage / member
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            source_by_member[member] = (source, digest(source), True)
        if replacement is not None:
            name, overlay, overlay_sources = replacement_packages(replacement)
            # A replacement may add a package the base does not carry yet; validate_base
            # already guarantees every base package covers both architectures.
            removed = [package for package in packages if field(package, "name") == name]
            packages = [package for package in packages if field(package, "name") != name]
            surviving_bundles = expected_members(packages)[1]
            for package in removed:
                member = safe_relative(field(package, "path"), "package.path")
                (stage / member).unlink()
                source_by_member.pop(member)
                old_bundle = bundle_path(package)
                if old_bundle is not None and old_bundle not in surviving_bundles:
                    (stage / old_bundle).unlink()
                    source_by_member.pop(old_bundle)
            packages.extend(overlay)
            for source, member, _ in overlay_sources:
                target = stage / member
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                source_by_member[member] = (source, digest(source), False)
        packages.sort(key=package_sort_key)
        key = mapping(field(state, "key"), "key")
        manifest = {"schemaVersion": 2, "architectures": sorted(ARCHITECTURES), "fingerprint": field(key, "fingerprint"), "packages": packages}
        validate_staged(stage, manifest)
        comparisons = []
        for member, (source, source_digest, reused) in sorted(source_by_member.items()):
            target = stage / member
            if digest(source) != source_digest or digest(target) != source_digest or not filecmp.cmp(source, target, shallow=False):
                raise fail(f"source changed during composition: {member}")
            if reused:
                comparisons.append({"path": member, "sourceSha256": source_digest, "outputSha256": source_digest, "byteIdentical": True})
        (stage / "metadata.json").write_text(json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        (stage / "reuse-comparisons.json").write_text(json.dumps({"schemaVersion": 1, "members": comparisons}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        publish(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def verify(staged: Path, metadata_path: Path) -> None:
    manifest = read_json(metadata_path, "staged metadata")
    validate_staged(staged, manifest)


def interrupted(_signal: int, _frame: FrameType | None) -> None:
    raise fail("composition interrupted")


def main() -> int:
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, interrupted)
    try:
        match sys.argv[1:]:  # noqa: E501  # noqa: MATCH_OK -- CLI argument shapes are rejected by the default case
            case ["verify", staged, metadata]:
                verify(Path(staged), Path(metadata))
            case [state, base, metadata, output]:
                compose(Path(state), Path(base), Path(metadata), Path(output))
            case _:
                raise fail("usage: compose_apk_inputs.py STATE BASE METADATA OUTPUT | verify STAGED METADATA")
    except ComposeError as error:
        print(f"compose_apk_inputs.py: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
