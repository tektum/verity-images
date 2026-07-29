#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/gen_matrix.py --all
#   uv run scripts/gen_matrix.py --changed origin/main

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal, TypedDict

ROOT: Final = Path(__file__).resolve().parents[1]
GLOBAL_PATHS: Final = {
    ".github/actions/publish-image/action.yaml",
    ".github/workflows/build.yaml",
    "scripts/gen_matrix.py",
}
REQUIRED_FIELDS: Final = {"name", "track", "description", "upstream", "versions", "enabled"}

type Track = Literal["wolfi", "patched"]


class MatrixEntry(TypedDict):
    name: str
    track: Track
    context: str
    platforms: str
    description: str
    upstream: str
    version: str
    latest: bool
    owner: str


class Matrix(TypedDict):
    include: list[MatrixEntry]


@dataclass(frozen=True, slots=True)
class Metadata:
    name: str
    track: Track
    description: str
    upstream: str
    versions: tuple[str, ...]
    owner: str
    enabled: bool


class MetadataError(ValueError):
    ...


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

    missing = REQUIRED_FIELDS - values.keys()
    unknown = values.keys() - (REQUIRED_FIELDS | {"owner"})
    if missing or unknown:
        raise MetadataError(f"{path}: missing={sorted(missing)} unknown={sorted(unknown)}")

    match values["track"]:
        case "wolfi":
            track: Track = "wolfi"
        case "patched":
            track = "patched"
        case _:
            raise MetadataError(f"{path}: track must be wolfi or patched")
    versions = values["versions"]
    if not isinstance(versions, tuple) or len(versions) != 1:
        raise MetadataError(f"{path}: versions must contain exactly one version")
    enabled = values["enabled"]
    if not isinstance(enabled, bool):
        raise MetadataError(f"{path}: enabled must be true or false")

    return Metadata(
        name=str(values["name"]),
        track=track,
        description=str(values["description"]),
        upstream=str(values["upstream"]),
        versions=versions,
        owner=str(values.get("owner", "tektum")),
        enabled=enabled,
    )


def changed_paths(base_ref: str) -> set[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base_ref}...HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return set(result.stdout.splitlines())


def image_directories() -> list[Path]:
    return sorted(path.parent for root in ("images", "patched") for path in (ROOT / root).glob("**/metadata.yaml"))


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split(".") if part.isdecimal()) or (0,)


def generate(base_ref: str | None) -> Matrix:
    changed: set[str] = changed_paths(base_ref) if base_ref else set()
    all_changed = bool(changed & GLOBAL_PATHS)
    catalog = [(directory, parse_metadata(directory / "metadata.yaml")) for directory in image_directories()]
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
        if base_ref and not all_changed and not any(path.startswith(f"{relative}/") for path in changed):
            continue
        required = directory / ("apko.yaml" if metadata.track == "wolfi" else "source.yaml")
        smoke_test = directory / "tests/test.sh"
        if not required.is_file() or not smoke_test.is_file():
            raise MetadataError(f"{relative}: missing {required.name} or tests/test.sh")
        if not metadata.enabled:
            continue
        entries.append(
            {
                "name": metadata.name,
                "track": metadata.track,
                "context": relative,
                "platforms": "linux/amd64,linux/arm64" if metadata.track == "wolfi" else "upstream",
                "description": metadata.description,
                "upstream": metadata.upstream,
                "version": metadata.versions[0],
                "latest": metadata.versions[0] == latest[metadata.name],
                "owner": metadata.owner,
            }
        )
    return {"include": entries}


def main() -> None:
    match sys.argv[1:]:
        case ["--all"]:
            base_ref = None
        case ["--changed", base_ref] if base_ref:
            pass
        case _:
            raise SystemExit("usage: gen_matrix.py --all | --changed BASE_REF")
    print(json.dumps(generate(base_ref), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
