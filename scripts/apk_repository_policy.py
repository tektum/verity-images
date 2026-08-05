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

from apk_archive import ARCHITECTURES, IndexRecord, PackageInfo, index_records, package_info, read_archive

OPENSSL_FIPS_PACKAGE: Final = "openssl-fips-provider"
MAX_SPDX_SIZE: Final = 64 * 1024
MELANGE_RECIPE_FIELDS: Final = (
    b"vars:\n",
    b"  source-commit: 17a2c5111864d8e016c5f2d29c40a3746b559e9d\n",
    b'  certificate: "4985"\n',
)
REQUIRED_FILES: Final = frozenset(
    {
        "usr/lib/ossl-modules/fips.so",
        "usr/bin/openssl-fips-activate",
        "usr/share/openssl-fips/fips.so.sha256",
        "usr/share/openssl-fips/openssl-fips.cnf.in",
    }
)
PAYLOAD_DIRECTORIES: Final = frozenset(
    {
        "usr",
        "usr/bin",
        "usr/lib",
        "usr/lib/ossl-modules",
        "usr/share",
        "usr/share/openssl-fips",
        "var",
        "var/lib",
        "var/lib/db",
        "var/lib/db/sbom",
    }
)


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
        "cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e",
        "apk",
        "--keys-dir",
        "/keys",
        "verify",
        f"/repository/{archive.name}",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"signature verification failed: {archive.name}")


def validate_package(info: PackageInfo) -> PackageInfo:
    if info.name != OPENSSL_FIPS_PACKAGE:
        return info
    if not all(field in info.recipe.contents for field in MELANGE_RECIPE_FIELDS):
        raise ValueError("invalid OpenSSL FIPS recipe")
    payload_files = {entry.name: entry.contents for entry in info.payload if entry.contents is not None}
    payload_directories = {entry.name for entry in info.payload if entry.contents is None}
    spdx = f"var/lib/db/sbom/{info.name}-{info.version}.spdx.json"
    spdx_contents = payload_files.get(spdx)
    if len(info.payload) != len(payload_files) + len(payload_directories) or set(payload_files) != REQUIRED_FILES | {spdx} or payload_directories != PAYLOAD_DIRECTORIES or spdx_contents is None or not 0 < len(spdx_contents) <= MAX_SPDX_SIZE:
        raise ValueError("invalid FIPS payload")
    module = payload_files.get("usr/lib/ossl-modules/fips.so", b"")
    machines = {"x86_64": 62, "aarch64": 183}
    if len(module) < 20 or module[:5] != b"\x7fELF\x02" or module[5] != 1 or int.from_bytes(module[18:20], "little") != machines[info.architecture]:
        raise ValueError("invalid FIPS module ELF")
    return info


def checked_package(apk: Path, architecture: str) -> PackageInfo:
    return validate_package(package_info(read_archive(apk), architecture))


def validate(repository: Path, keys: Path, manifest_digest: str) -> None:
    manifest_path = repository / "manifest.json"
    if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != manifest_digest:
        raise ValueError("external manifest digest mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    architectures = manifest.get("architectures") if isinstance(manifest, dict) else None
    if not isinstance(architectures, list) or len(architectures) != len(ARCHITECTURES) or set(architectures) != ARCHITECTURES:
        raise ValueError("unexpected architecture set")
    packages = manifest.get("packages")
    if not isinstance(packages, list):
        raise ValueError("invalid manifest package list")
    listed: set[str] = set()
    by_identity: dict[tuple[str, str], PackageInfo] = {}
    versions: dict[str, str] = {}
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("invalid manifest package")
        architecture = package.get("architecture")
        name = package.get("name")
        version = package.get("version")
        epoch = package.get("epoch")
        relative = package.get("path")
        digest = package.get("sha256")
        if architecture not in ARCHITECTURES or not isinstance(name, str) or not isinstance(version, str) or type(epoch) is not int or not isinstance(relative, str) or not isinstance(digest, str):
            raise ValueError("invalid manifest fields")
        if not safe_name(relative) or Path(relative).parts[0] != architecture:
            raise ValueError("unsafe manifest path")
        apk = repository / relative
        data = read_archive(apk)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"manifest digest mismatch: {relative}")
        verify(apk, keys)
        info = validate_package(package_info(data, architecture))
        if (name, version, epoch) != (info.name, info.version, info.epoch):
            raise ValueError("manifest package identity mismatch")
        identity = (info.name, architecture)
        if relative in listed or identity in by_identity or versions.setdefault(info.name, info.version) != info.version:
            raise ValueError("duplicate package")
        listed.add(relative)
        by_identity[identity] = info
    actual = {path.relative_to(repository).as_posix() for path in repository.glob("*/*.apk")}
    if not versions or actual != listed or any({architecture for (package_name, architecture) in by_identity if package_name == name} != ARCHITECTURES for name in versions):
        raise ValueError("manifest package set mismatch")
    for architecture in ARCHITECTURES:
        index = repository / architecture / "APKINDEX.tar.gz"
        verify(index, keys)
        records = index_records(read_archive(index))
        expected = {
            IndexRecord(info.name, info.version, architecture, expected_control_digest(info.control), info.size)
            for (package_name, package_architecture), info in by_identity.items()
            if package_architecture == architecture
        }
        if len(records) != len(expected) or set(records) != expected:
            raise ValueError(f"index binding mismatch: {architecture}")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: apk_repository_policy.py REPOSITORY KEYS MANIFEST_SHA256")
    validate(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])


if __name__ == "__main__":
    main()
