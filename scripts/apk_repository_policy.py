#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/apk_repository_policy.py REPOSITORY EXPECTED_FINGERPRINT

from __future__ import annotations

import hashlib
import io
import json
import sys
import tarfile
import zlib
from pathlib import Path
from typing import Final

ARCHITECTURES: Final = frozenset({"x86_64", "aarch64"})
REQUIRED_FILES: Final = frozenset(
    {
        "usr/lib/ossl-modules/fips.so",
        "usr/bin/openssl-fips-activate",
        "usr/share/openssl-fips/openssl-fips.cnf.in",
    }
)


def gzip_members(data: bytes) -> tuple[bytes, ...]:
    members: list[bytes] = []
    remaining = data
    while remaining:
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            member = inflater.decompress(remaining)
        except zlib.error as error:
            raise ValueError("invalid gzip member") from error
        member += inflater.flush()
        if not inflater.eof or not inflater.unused_data and len(member) == 0:
            raise ValueError("invalid gzip member")
        members.append(member)
        remaining = inflater.unused_data
    return tuple(members)


def safe_name(name: str) -> bool:
    path = Path(name)
    return not path.is_absolute() and ".." not in path.parts and name not in {"", "."}


def package_info(apk: Path, architecture: str) -> tuple[str, str]:
    files: set[str] = set()
    info = ""
    for member in gzip_members(apk.read_bytes()):
        with tarfile.open(fileobj=io.BytesIO(member), mode="r:") as archive:
            for entry in archive.getmembers():
                if not safe_name(entry.name) or entry.issym() or entry.islnk() or entry.isdev():
                    raise ValueError(f"unsafe APK member: {entry.name}")
                if entry.isfile():
                    files.add(entry.name)
                    if entry.name == ".PKGINFO":
                        source = archive.extractfile(entry)
                        if source is not None:
                            info = source.read().decode("utf-8")
    fields = dict(line.split(" = ", maxsplit=1) for line in info.splitlines() if " = " in line)
    name, version = fields.get("pkgname", ""), fields.get("pkgver", "")
    if not name or not version or fields.get("arch") != architecture:
        raise ValueError(f"invalid package identity: {apk.name}")
    if "etc/ssl/fipsmodule.cnf" in files or not REQUIRED_FILES <= files:
        raise ValueError(f"invalid FIPS payload: {apk.name}")
    return name, version


def validate(repository: Path, fingerprint: str) -> None:
    manifest_path = repository / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("fingerprint") != fingerprint:
        raise ValueError("unexpected signing key fingerprint")
    if set(manifest.get("architectures", ())) != ARCHITECTURES:
        raise ValueError("unexpected architecture set")
    packages = manifest.get("packages", [])
    if not isinstance(packages, list):
        raise ValueError("invalid manifest package list")
    identities: set[tuple[str, str, str]] = set()
    listed: set[str] = set()
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("invalid manifest package")
        arch, relative, digest = package.get("architecture"), package.get("path"), package.get("sha256")
        if arch not in ARCHITECTURES or not isinstance(relative, str) or not isinstance(digest, str):
            raise ValueError("invalid manifest fields")
        if not safe_name(relative) or Path(relative).parts[0] != arch:
            raise ValueError("unsafe manifest path")
        apk = repository / relative
        if hashlib.sha256(apk.read_bytes()).hexdigest() != digest:
            raise ValueError(f"manifest digest mismatch: {relative}")
        name, version = package_info(apk, arch)
        identity = (arch, name, version)
        if identity in identities:
            raise ValueError(f"duplicate package identity: {identity}")
        identities.add(identity)
        listed.add(relative)
    actual = {path.relative_to(repository).as_posix() for path in repository.glob("*/*.apk")}
    if actual != listed:
        raise ValueError("manifest package set mismatch")
    for arch in ARCHITECTURES:
        if not (repository / arch / "APKINDEX.tar.gz").is_file():
            raise ValueError(f"missing signed index: {arch}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: apk_repository_policy.py REPOSITORY EXPECTED_FINGERPRINT")
    validate(Path(sys.argv[1]), sys.argv[2])


if __name__ == "__main__":
    main()
