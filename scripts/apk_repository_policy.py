#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/apk_repository_policy.py REPOSITORY KEYS MANIFEST_SHA256

from __future__ import annotations

import base64
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Final

from apk_archive import ARCHITECTURES, PackageInfo, index_records, package_info

REQUIRED_FILES: Final = frozenset(
    {
        "usr/lib/ossl-modules/fips.so",
        "usr/bin/openssl-fips-activate",
        "usr/share/openssl-fips/openssl-fips.cnf.in",
    }
)
PACKAGE_NAME: Final = "openssl-fips-provider"
PACKAGE_VERSION: Final = "3.1.2-r1"


def safe_name(name: str) -> bool:
    path = Path(name)
    return not path.is_absolute() and ".." not in path.parts and name not in {"", "."}


def expected_control_digest(control: bytes) -> str:
    return "Q1" + base64.b64encode(hashlib.sha1(control).digest()).decode("ascii")


def verify(archive: Path, keys: Path) -> None:
    if len(tuple(keys.glob("*.pub"))) != 1:
        raise ValueError("keys directory must contain exactly one public key")
    apk = shutil.which("apk")
    command = [apk, "--keys-dir", str(keys), "verify", str(archive)] if apk else [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{keys.resolve()}:/keys:ro",
        "-v",
        f"{archive.parent.resolve()}:/repository:ro",
        "cgr.dev/chainguard/wolfi-base:latest",
        "apk",
        "--keys-dir",
        "/keys",
        "verify",
        f"/repository/{archive.name}",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"signature verification failed: {archive.name}")


def checked_package(apk: Path, architecture: str) -> PackageInfo:
    info = package_info(apk.read_bytes(), architecture, REQUIRED_FILES)
    if info.name != PACKAGE_NAME or info.version != PACKAGE_VERSION:
        raise ValueError(f"invalid package identity: {apk.name}")
    return info


def validate(repository: Path, keys: Path, manifest_digest: str) -> None:
    manifest_path = repository / "manifest.json"
    if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != manifest_digest:
        raise ValueError("external manifest digest mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or set(manifest.get("architectures", ())) != ARCHITECTURES:
        raise ValueError("unexpected architecture set")
    packages = manifest.get("packages")
    if not isinstance(packages, list):
        raise ValueError("invalid manifest package list")
    listed: set[str] = set()
    by_arch: dict[str, PackageInfo] = {}
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("invalid manifest package")
        architecture = package.get("architecture")
        relative = package.get("path")
        digest = package.get("sha256")
        if architecture not in ARCHITECTURES or not isinstance(relative, str) or not isinstance(digest, str):
            raise ValueError("invalid manifest fields")
        if not safe_name(relative) or Path(relative).parts[0] != architecture:
            raise ValueError("unsafe manifest path")
        apk = repository / relative
        if hashlib.sha256(apk.read_bytes()).hexdigest() != digest:
            raise ValueError(f"manifest digest mismatch: {relative}")
        verify(apk, keys)
        if relative in listed or architecture in by_arch:
            raise ValueError("duplicate package")
        listed.add(relative)
        by_arch[architecture] = checked_package(apk, architecture)
    actual = {path.relative_to(repository).as_posix() for path in repository.glob("*/*.apk")}
    if actual != listed or set(by_arch) != ARCHITECTURES:
        raise ValueError("manifest package set mismatch")
    for architecture, info in by_arch.items():
        index = repository / architecture / "APKINDEX.tar.gz"
        verify(index, keys)
        records = index_records(index.read_bytes())
        matches = [record for record in records if record.name == info.name and record.version == info.version]
        if len(matches) != 1:
            raise ValueError(f"index package missing: {architecture}")
        record = matches[0]
        if record.architecture != architecture or record.control != expected_control_digest(info.control) or record.size != info.size:
            raise ValueError(f"index binding mismatch: {architecture}")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: apk_repository_policy.py REPOSITORY KEYS MANIFEST_SHA256")
    validate(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])


if __name__ == "__main__":
    main()
