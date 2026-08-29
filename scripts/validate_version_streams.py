#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = re.compile(r"^(?:v)?(\d+)(?:\.(\d+))?(?:\.\d+)?(?:[-+].*)?$")
APKO_PACKAGE = re.compile(
    r"^\s*-\s+([A-Za-z0-9][A-Za-z0-9+_.-]*)(?:[@=~<>].*)?\s*$", re.MULTILINE
)

PACKAGE_NAME = re.compile(r"^\s{2}name:\s*([^\s#]+)")
PACKAGE_VERSION = re.compile(r'^\s{2}version:\s*"?([^"\s#]+)"?')
METADATA_VERSIONS = re.compile(r"^versions:\s*\[\s*([^,\]\s]+)\s*\]\s*$", re.MULTILINE)
TAG_PREFIX = re.compile(r"^\s+tag-filter-prefix:\s*(\S+)\s*$", re.MULTILINE)


class StreamError(ValueError):
    pass


def stream(version: str) -> str:
    match = VERSION.fullmatch(version)
    if match is None:
        raise StreamError(f"invalid version: {version}")
    return ".".join(part for part in match.groups() if part is not None)


def package_identity(contents: str) -> tuple[str, str]:
    name = version = None
    in_package = False
    for line in contents.splitlines():
        if line == "package:":
            in_package = True
            continue
        if in_package and line and not line[0].isspace():
            break
        if in_package:
            if match := PACKAGE_NAME.fullmatch(line):
                name = match.group(1)
            elif match := PACKAGE_VERSION.fullmatch(line):
                version = match.group(1)
    if name is None or version is None:
        raise StreamError("melange package must declare name and version")
    return name, version


def metadata_stream(contents: str) -> str:
    match = METADATA_VERSIONS.search(contents)
    if match is None:
        raise StreamError("metadata must declare exactly one inline version")
    return match.group(1)


def tag_stream(contents: str) -> str | None:
    match = TAG_PREFIX.search(contents)
    if match is None:
        return None
    value = match.group(1).removeprefix("v").rstrip(".")
    return stream(value)


def versioned_name(name: str) -> tuple[str, str] | None:
    match = re.fullmatch(r"(.+-)(\d+(?:\.\d+)?)", name)
    return (match.group(1), match.group(2)) if match else None

def apko_packages(contents: str) -> set[str]:
    return {match.group(1) for match in APKO_PACKAGE.finditer(contents)}



def validate_transition(
    directory: str,
    old_melange: str,
    new_melange: str,
    old_metadata: str,
    new_metadata: str,
    old_apko: str | None,
    new_apko: str | None,
) -> list[str]:
    old_name, old_version = package_identity(old_melange)
    new_name, new_version = package_identity(new_melange)
    old_stream = stream(old_version)
    new_stream = stream(new_version)
    if old_stream == new_stream:
        return []

    errors: list[str] = []
    current_metadata_stream = metadata_stream(new_metadata)
    if current_metadata_stream != new_stream:
        errors.append(f"{directory}/metadata.yaml: versions must change from {current_metadata_stream} to {new_stream}")

    old_name_parts = versioned_name(old_name)
    if old_name_parts is not None:
        expected_name = f"{old_name_parts[0]}{new_stream}"
        if new_name != expected_name:
            errors.append(f"{directory}/melange.yaml: package.name must change from {old_name} to {expected_name}")
        if old_apko is not None and new_apko is None:
            errors.append(f"{directory}/apko.yaml: tracked file must not be removed during a stream change")
        elif old_apko is not None and new_apko is not None:
            old_packages = apko_packages(old_apko)
            new_packages = apko_packages(new_apko)
            old_family = {
                package
                for package in old_packages
                if package == old_name or package.startswith(f"{old_name}-")
            }
            expected_family = {
                f"{expected_name}{package[len(old_name):]}" for package in old_family
            }
            if old_family & new_packages or not expected_family.issubset(new_packages):
                errors.append(f"{directory}/apko.yaml: package references must change from {old_name} to {expected_name}")

    old_tag_stream = tag_stream(old_melange)
    current_tag_stream = tag_stream(new_melange)
    if (old_tag_stream is not None or current_tag_stream is not None) and current_tag_stream != new_stream:
        errors.append(f"{directory}/melange.yaml: tag-filter-prefix must change from {current_tag_stream or 'missing'} to {new_stream}")
    return errors


def git(*arguments: str) -> str:
    return subprocess.run(
        ["git", *arguments], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout


def base_contents(base: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "show", f"{base}:{path}"], cwd=ROOT, capture_output=True, text=True
    )
    return result.stdout if result.returncode == 0 else None


def validate_changed(base: str) -> list[str]:
    changed = git("diff", "--name-only", f"{base}...HEAD").splitlines()
    directories = sorted(
        {
            str(Path(path).parent)
            for path in changed
            if path.startswith("images/") and path.endswith("/melange.yaml")
        }
    )
    errors: list[str] = []
    for directory in directories:
        melange_path = f"{directory}/melange.yaml"
        metadata_path = f"{directory}/metadata.yaml"
        apko_path = f"{directory}/apko.yaml"
        old_melange = base_contents(base, melange_path)
        old_metadata = base_contents(base, metadata_path)
        if old_melange is None or old_metadata is None:
            continue
        current_melange = ROOT / melange_path
        current_metadata = ROOT / metadata_path
        if not current_melange.is_file():
            continue
        if not current_metadata.is_file():
            errors.append(f"{directory}/metadata.yaml: tracked file must not be removed during a stream change")
            continue
        errors.extend(
            validate_transition(
                directory,
                old_melange,
                current_melange.read_text(encoding="utf-8"),
                old_metadata,
                current_metadata.read_text(encoding="utf-8"),
                base_contents(base, apko_path),
                (ROOT / apko_path).read_text(encoding="utf-8") if (ROOT / apko_path).is_file() else None,
            )
        )
    return errors


def default_base() -> str:
    base_branch = os.environ.get("GITHUB_BASE_REF")
    candidate = f"origin/{base_branch}" if base_branch else "origin/main"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", candidate], cwd=ROOT, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise StreamError(f"base ref is unavailable: {candidate}")
    return candidate


def main() -> None:
    if len(sys.argv) > 2:
        raise SystemExit("usage: validate_version_streams.py [BASE_REF]")
    base = sys.argv[1] if len(sys.argv) == 2 else default_base()
    errors = validate_changed(base)
    if errors:
        raise SystemExit("\n".join(errors))
    print("version stream validation passed")


if __name__ == "__main__":
    main()
