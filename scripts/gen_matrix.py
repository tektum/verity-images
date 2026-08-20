#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/gen_matrix.py --all
#   uv run scripts/gen_matrix.py --changed origin/main

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal, TypedDict

ROOT: Final = Path(__file__).resolve().parents[1]
GLOBAL_PATHS: Final = {
    ".github/actions/publish-image/action.yaml",
    ".github/workflows/build.yaml",
    "scripts/build_candidate.sh",
    "scripts/replace_gosu.sh",
    "scripts/evaluate_scan_gate.sh",
    "scripts/parse_push_digest.sh",
    "scripts/install_image_tools.sh",
}
FINGERPRINT_VERSION: Final = "verity-image-receipt-v1"
OPENSSL_FIPS_PATHS: Final = {
    "packages/keys/verity-apk-2026.rsa.pub",
    "packages/repository-state.json",
    "packages/repository-state.pin.json",
    "packages/repository-state.schema.json",
}
SOURCE_REGISTRIES: Final = frozenset({"docker.io", "registry.k8s.io", "docker.elastic.co", "ghcr.io"})
COMMON_REQUIRED_FIELDS: Final = {"name", "track", "description", "enabled"}
WOLFI_REQUIRED_FIELDS: Final = {"upstream", "versions"}
DESCRIPTION_VERSION: Final = re.compile(r"(?<![A-Za-z0-9])v?\d+(?:\.\d+)*(?![A-Za-z0-9])")

type Track = Literal["wolfi", "patched"]
GLOBAL_SAMPLES: Final[dict[tuple[Track, str], str]] = {
    ("wolfi", "plain"): "images/static",
    ("wolfi", "fips"): "images/go/1.26",
    ("patched", "plain"): "patched/debian-12-slim",
}


class MatrixEntry(TypedDict):
    name: str
    build_name: str
    flavor: str
    track: Track
    context: str
    platforms: str
    description: str
    upstream: str
    version: str
    tag_version: str
    major: str
    latest: bool
    owner: str
    evidence_file: str
    input_digest: str


class Matrix(TypedDict):
    include: list[MatrixEntry]


@dataclass(frozen=True, slots=True)
class Metadata:
    name: str
    track: Track
    description: str
    upstream: str
    versions: tuple[str, ...]
    flavors: tuple[str, ...]
    major: str
    owner: str
    enabled: bool
    category: str


class MetadataError(ValueError):
    ...


@dataclass(frozen=True, slots=True)
class Source:
    image: str
    digest: str
    platforms: tuple[str, ...]


def parse_scalar(raw: str) -> str | bool | tuple[str, ...]:
    value = raw.strip()
    if value in {"true", "false"}:
        return value == "true"
    if value.startswith("[") and value.endswith("]"):
        return tuple(item.strip().strip('"\'') for item in value[1:-1].split(",") if item.strip())
    return value.strip('"\'')


def parse_metadata(path: Path) -> Metadata:
    values: dict[str, str | bool | tuple[str, ...]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, raw = stripped.partition(":")
        if not separator or not key or key in values:
            raise MetadataError(f"{path}:{line_number}: invalid metadata entry")
        values[key] = parse_scalar(raw)

    match values.get("track"):
        case "wolfi":
            track: Track = "wolfi"
            required = COMMON_REQUIRED_FIELDS | WOLFI_REQUIRED_FIELDS
        case "patched":
            track = "patched"
            required = COMMON_REQUIRED_FIELDS
        case _:
            raise MetadataError(f"{path}: track must be wolfi or patched")
    optional = {"flavors", "major", "owner", "category"}
    allowed = required | optional | (WOLFI_REQUIRED_FIELDS if track == "patched" else set())
    missing = required - values.keys()
    unknown = values.keys() - allowed
    if missing or unknown:
        raise MetadataError(f"{path}: missing={sorted(missing)} unknown={sorted(unknown)}")

    if track == "patched":
        source_path = path.parent / "source.yaml"
        if not source_path.is_file():
            raise MetadataError(f"{path.parent}: missing source.yaml")
        source = parse_source(source_path)
        upstream = source.image
        versions = (source_version(source.image, source_path),)
    else:
        upstream = values["upstream"]
        versions = values["versions"]
        if not isinstance(upstream, str):
            raise MetadataError(f"{path}: upstream must be a string")
        if not isinstance(versions, tuple) or len(versions) != 1:
            raise MetadataError(f"{path}: versions must contain exactly one version")
    enabled = values["enabled"]
    if not isinstance(enabled, bool):
        raise MetadataError(f"{path}: enabled must be true or false")
    description = str(values["description"])
    if DESCRIPTION_VERSION.search(description):
        raise MetadataError(f"{path}: description must not contain a version")
    flavors = values.get("flavors", ("plain",))
    if not isinstance(flavors, tuple) or not flavors or len(flavors) != len(set(flavors)):
        raise MetadataError(f"{path}: flavors must be a non-empty unique list")
    major = values.get("major", "")
    if not isinstance(major, str):
        raise MetadataError(f"{path}: major must be a string")

    return Metadata(
        name=str(values["name"]),
        track=track,
        description=description,
        upstream=upstream,
        versions=versions,
        flavors=flavors,
        major=major,
        owner=str(values.get("owner", "tektum")),
        enabled=enabled,
        category=str(values.get("category", "")),
    )


def parse_source(path: Path) -> Source:
    values: dict[str, str | bool | tuple[str, ...]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, raw = line.partition(":")
        if separator:
            values[key.strip()] = parse_scalar(raw)
    image = values.get("image")
    digest = values.get("digest")
    platforms = values.get("platforms")
    if not isinstance(image, str) or not any(
        image.startswith(f"{registry}/") for registry in SOURCE_REGISTRIES
    ):
        raise MetadataError(f"{path}: image must use an approved fully qualified registry")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or len(digest) != 71:
        raise MetadataError(f"{path}: digest must be a pinned sha256")
    if not isinstance(platforms, tuple) or platforms != ("linux/amd64", "linux/arm64"):
        raise MetadataError(f"{path}: platforms must be [linux/amd64, linux/arm64]")
    return Source(image=image, digest=digest, platforms=platforms)


def source_version(image: str, path: Path) -> str:
    tag = image.rsplit(":", 1)[-1]
    match = re.fullmatch(r"v?(\d+(?:\.\d+)*)(?:-.*)?", tag)
    if match is None:
        raise MetadataError(f"{path}: image tag must start with a numeric version")
    return match.group(1)




def changed_paths(base_ref: str) -> set[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base_ref}...HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return set(result.stdout.splitlines())

def is_validation_path(path: str) -> bool:
    return "/tests/" in f"/{path}"



def image_directories() -> list[Path]:
    return sorted(path.parent for root in ("images", "patched") for path in (ROOT / root).glob("**/metadata.yaml"))


def uses_openssl_fips_provider(directory: Path, flavor: str) -> bool:
    config = directory / ("apko.yaml" if flavor == "plain" else f"{flavor}.apko.yaml")
    if not config.is_file():
        config = directory / "apko.yaml"
    return config.is_file() and "openssl-fips-provider=3.1.2-r3" in config.read_text(encoding="utf-8")


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split(".") if part.isdecimal()) or (0,)

def input_digest(directory: Path, flavor: str) -> str:
    digest = hashlib.sha256()
    digest.update(FINGERPRINT_VERSION.encode())
    digest.update(b"\0")
    digest.update(flavor.encode())
    shared_paths = GLOBAL_PATHS | (OPENSSL_FIPS_PATHS if uses_openssl_fips_provider(directory, flavor) else set())
    paths = sorted(
        {
            *(relative for relative in shared_paths if (ROOT / relative).is_file()),
            *(
                path.relative_to(ROOT).as_posix()
                for path in directory.rglob("*")
                if path.is_file()
                and path.name != "metadata.yaml"
                and not is_validation_path(path.relative_to(directory).as_posix())
            ),
        }
    )
    for relative in paths:
        digest.update(b"\0")
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update((ROOT / relative).read_bytes())
    return f"sha256:{digest.hexdigest()}"


def cached_images(path: Path | None, max_age: timedelta) -> dict[tuple[str, str], str]:
    if path is None:
        return {}
    document = json.loads(path.read_text(encoding="utf-8"))
    images = document.get("images")
    if not isinstance(images, list):
        raise MetadataError(f"{path}: catalog images must be an array")
    cutoff = datetime.now(UTC) - max_age
    cached: dict[tuple[str, str], str] = {}
    for image in images:
        if not isinstance(image, dict):
            continue
        try:
            validated_at = datetime.fromisoformat(str(image["validatedAt"]).replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if validated_at.tzinfo is None or validated_at.utcoffset() is None:
            continue
        if validated_at < cutoff:
            continue
        name, version, fingerprint = image.get("name"), image.get("version"), image.get("inputDigest")
        if isinstance(name, str) and isinstance(version, str) and isinstance(fingerprint, str):
            cached[(name, version)] = fingerprint
    return cached


def generate(
    base_ref: str | None, catalog_path: Path | None = None, max_age: timedelta = timedelta(hours=24)
) -> Matrix:
    changed: set[str] = (
        {
            path
            for path in changed_paths(base_ref)
            if not path.endswith("/metadata.yaml") and not is_validation_path(path)
        }
        if base_ref and catalog_path is None
        else set()
    )
    global_changed = bool(changed & GLOBAL_PATHS)
    openssl_fips_changed = bool(changed & OPENSSL_FIPS_PATHS)
    cached = cached_images(catalog_path, max_age)
    catalog = [(directory, parse_metadata(directory / "metadata.yaml")) for directory in image_directories()]
    samples = {
        (metadata.track, flavor): (
            GLOBAL_SAMPLES[(metadata.track, flavor)]
            if (metadata.track, flavor) in GLOBAL_SAMPLES
            else min(
                candidate_directory.relative_to(ROOT).as_posix()
                for candidate_directory, candidate in catalog
                if candidate.enabled and candidate.track == metadata.track and flavor in candidate.flavors
            )
        )
        for _, metadata in catalog
        if metadata.enabled
        for flavor in metadata.flavors
    }
    latest = {
        metadata.name: max(
            (candidate.versions[0] for _, candidate in catalog if candidate.name == metadata.name),
            key=version_key,
        )
        for _, metadata in catalog
    }
    entries: list[MatrixEntry] = []
    for directory, metadata in catalog:
        relative = directory.relative_to(ROOT).as_posix()
        directly_changed = any(path.startswith(f"{relative}/") for path in changed)
        required = directory / ("apko.yaml" if metadata.track == "wolfi" else "source.yaml")
        smoke_test = directory / "tests/test.sh"
        if not required.is_file() or not smoke_test.is_file():
            raise MetadataError(f"{relative}: missing {required.name} or tests/test.sh")
        if (
            metadata.track == "wolfi"
            and not (directory / "melange.yaml").is_file()
            and not (directory / "apko.lock.json").is_file()
        ):
            raise MetadataError(f"{relative}: missing apko.lock.json")
        if not metadata.enabled:
            continue
        platforms = "linux/amd64,linux/arm64"
        if metadata.track == "patched":
            platforms = ",".join(parse_source(required).platforms)
        for flavor in metadata.flavors:
            provider_changed = (
                openssl_fips_changed
                and metadata.track == "wolfi"
                and uses_openssl_fips_provider(directory, flavor)
            )
            if catalog_path is None and base_ref and not directly_changed and (
                not provider_changed
                and (not global_changed or samples[(metadata.track, flavor)] != relative)
            ):
                continue
            fingerprint = input_digest(directory, flavor)
            tag_version = metadata.versions[0] if flavor == "plain" else f"{metadata.versions[0]}-{flavor}"
            if cached.get((metadata.name, tag_version)) == fingerprint:
                continue
            build_name = metadata.name if flavor == "plain" else f"{metadata.name}-{flavor}"
            entries.append(
                {
                    "name": metadata.name,
                    "build_name": build_name,
                    "flavor": flavor,
                    "track": metadata.track,
                    "context": relative,
                    "platforms": platforms,
                    "description": metadata.description,
                    "category": metadata.category,
                    "upstream": metadata.upstream,
                    "version": metadata.versions[0],
                    "tag_version": (
                        metadata.versions[0] if flavor == "plain" else f"{metadata.versions[0]}-{flavor}"
                    ),
                    "major": metadata.major if metadata.versions[0] == latest[metadata.name] else "",
                    "latest": metadata.versions[0] == latest[metadata.name],
                    "owner": metadata.owner,
                    "evidence_file": (
                        f"dist/{build_name}/apko.lock.json"
                        if metadata.track == "wolfi"
                        else f"dist/{build_name}/source-resolved.json"
                    ),
                    "input_digest": fingerprint,
                }
            )
    return {"include": entries}


def main() -> None:
    catalog_path: Path | None = None
    max_age = timedelta(hours=24)
    arguments = sys.argv[1:]
    while len(arguments) >= 2 and arguments[-2] in {"--catalog", "--max-age-hours"}:
        option, value = arguments[-2:]
        arguments = arguments[:-2]
        if option == "--catalog":
            catalog_path = Path(value)
        else:
            max_age = timedelta(hours=int(value))
    match arguments:
        case ["--all"]:
            base_ref = None
        case ["--changed", base_ref] if base_ref:
            pass
        case _:
            raise SystemExit(
                "usage: gen_matrix.py --all | --changed BASE_REF "
                "[--catalog CATALOG] [--max-age-hours HOURS]"
            )
    print(json.dumps(generate(base_ref, catalog_path, max_age), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
