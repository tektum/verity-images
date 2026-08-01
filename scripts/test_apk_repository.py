#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_repository.py

from __future__ import annotations

import gzip
import hashlib
import io
import json
import tarfile
import tempfile
from pathlib import Path

import apk_repository_policy


def apk(path: Path, arch: str, entries: dict[str, bytes], name: str = "openssl-fips-provider") -> None:
    payload = {".PKGINFO": f"pkgname = {name}\npkgver = 3.1.2-r1\narch = {arch}\n".encode()} | entries
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as archive:
        for member_name, contents in payload.items():
            member = tarfile.TarInfo(member_name)
            member.size = len(contents)
            archive.addfile(member, io.BytesIO(contents))
    path.write_bytes(gzip.compress(stream.getvalue()))


def repository(root: Path) -> tuple[Path, str]:
    package = root / "x86_64" / "openssl-fips-provider-3.1.2-r1.apk"
    package.parent.mkdir(parents=True, exist_ok=True)
    apk(package, "x86_64", {entry: b"fixture" for entry in apk_repository_policy.REQUIRED_FILES})
    for arch in apk_repository_policy.ARCHITECTURES:
        directory = root / arch
        directory.mkdir(exist_ok=True)
        (directory / "APKINDEX.tar.gz").write_bytes(b"index")
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    fingerprint = "fixture-key"
    (root / "manifest.json").write_text(
        json.dumps(
            {
                "architectures": sorted(apk_repository_policy.ARCHITECTURES),
                "fingerprint": fingerprint,
                "packages": [{"architecture": "x86_64", "path": package.relative_to(root).as_posix(), "sha256": digest}],
            }
        ),
        encoding="utf-8",
    )
    return package, fingerprint


def rejects(root: Path, fingerprint: str) -> None:
    try:
        apk_repository_policy.validate(root, fingerprint)
    except ValueError:
        return
    raise AssertionError("invalid repository was accepted")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        package, fingerprint = repository(root)
        apk_repository_policy.validate(root, fingerprint)

        package.write_bytes(package.read_bytes()[:-1])
        rejects(root, fingerprint)
        package, fingerprint = repository(root)
        package.write_bytes(package.read_bytes() + b"suffix")
        rejects(root, fingerprint)

        package, fingerprint = repository(root)
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        manifest["fingerprint"] = "wrong-key"
        (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        rejects(root, fingerprint)

        for path in ("/absolute.apk", "x86_64/../escape.apk"):
            package, fingerprint = repository(root)
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["packages"][0]["path"] = path
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            rejects(root, fingerprint)

        for missing in apk_repository_policy.REQUIRED_FILES | {"etc/ssl/fipsmodule.cnf"}:
            package, fingerprint = repository(root)
            entries = {entry: b"fixture" for entry in apk_repository_policy.REQUIRED_FILES if entry != missing}
            if missing == "etc/ssl/fipsmodule.cnf":
                entries[missing] = b"forbidden"
            apk(package, "x86_64", entries)
            rejects(root, fingerprint)

        package, fingerprint = repository(root)
        apk(package, "aarch64", {entry: b"fixture" for entry in apk_repository_policy.REQUIRED_FILES})
        rejects(root, fingerprint)

        package, fingerprint = repository(root)
        duplicate = root / "x86_64" / "duplicate.apk"
        duplicate.write_bytes(package.read_bytes())
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        manifest["packages"].append({"architecture": "x86_64", "path": "x86_64/duplicate.apk", "sha256": hashlib.sha256(duplicate.read_bytes()).hexdigest()})
        (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        rejects(root, fingerprint)


if __name__ == "__main__":
    main()
