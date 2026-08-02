#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_repository.py

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

import apk_archive
import apk_repository_policy
from apk_test_fixtures import elf, entry, gzip_member, pack_tar, signed_shape, unsigned_package, write_unsigned

ROOT = Path(__file__).resolve().parents[1]
ASSEMBLE = ROOT / ".github/scripts/assemble-apk-repository.sh"


def payload(architecture: str) -> tuple[tuple[tarfile.TarInfo, bytes | None], ...]:
    return (
        entry("usr", typeflag=tarfile.DIRTYPE),
        entry("usr/bin", typeflag=tarfile.DIRTYPE),
        entry("usr/lib/ossl-modules/fips.so", elf(architecture)),
        entry("usr/bin/openssl-fips-activate", b"#!/bin/sh\n"),
        entry("usr/lib", typeflag=tarfile.DIRTYPE),
        entry("usr/lib/ossl-modules", typeflag=tarfile.DIRTYPE),
        entry("usr/share", typeflag=tarfile.DIRTYPE),
        entry("usr/share/openssl-fips", typeflag=tarfile.DIRTYPE),
        entry("usr/share/openssl-fips/fips.so.sha256", b"sha256  /usr/lib/ossl-modules/fips.so\n"),
        entry("usr/share/openssl-fips/openssl-fips.cnf.in", b"openssl_conf = default\n"),
        entry("var", typeflag=tarfile.DIRTYPE),
        entry("var/lib", typeflag=tarfile.DIRTYPE),
        entry("var/lib/db", typeflag=tarfile.DIRTYPE),
        entry("var/lib/db/sbom", typeflag=tarfile.DIRTYPE),
        entry(apk_archive.MELANGE_SPDX, b"{}"),
    )


def rejects_package(data: bytes, architecture: str = "x86_64") -> None:
    try:
        apk_archive.package_info(data, architecture, apk_repository_policy.REQUIRED_FILES)
    except ValueError:
        return
    raise AssertionError("invalid package was accepted")


def rejects_identity(data: bytes) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        package = Path(temporary) / "package.apk"
        package.write_bytes(data)
        try:
            apk_repository_policy.checked_package(package, "x86_64")
        except ValueError:
            return
    raise AssertionError("invalid package identity was accepted")


def sign(path: Path, key: Path) -> None:
    subprocess.run(["melange", "sign", "--signing-key", str(key), str(path)], check=True)


def repository(root: Path) -> tuple[Path, Path, str]:
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir()
    key = root / "fixture.rsa"
    keys = root / "keys"
    keys.mkdir()
    subprocess.run(["melange", "keygen", str(key)], check=True)
    shutil.copy2(key.with_suffix(".rsa.pub"), keys / "fixture.rsa.pub")
    packages: list[dict[str, str]] = []
    for architecture in sorted(apk_repository_policy.ARCHITECTURES):
        directory = root / architecture
        directory.mkdir()
        package = directory / "openssl-fips-provider-3.1.2-r2.apk"
        write_unsigned(package, architecture, payload(architecture))
        sign(package, key)
        subprocess.run(["melange", "index", "--arch", architecture, "--signing-key", str(key), "--output", str(directory / "APKINDEX.tar.gz"), str(package)], check=True)
        packages.append({"architecture": architecture, "path": package.relative_to(root).as_posix(), "sha256": hashlib.sha256(package.read_bytes()).hexdigest()})
    manifest = root / "manifest.json"
    manifest.write_text(json.dumps({"architectures": sorted(apk_repository_policy.ARCHITECTURES), "packages": packages}, sort_keys=True), encoding="utf-8")
    return root / "x86_64" / "openssl-fips-provider-3.1.2-r2.apk", keys, hashlib.sha256(manifest.read_bytes()).hexdigest()


def rejects_repository(root: Path, keys: Path, digest: str) -> None:
    try:
        apk_repository_policy.validate(root, keys, digest)
    except ValueError:
        return
    raise AssertionError("invalid repository was accepted")


def real_repository(root: Path) -> tuple[Path, Path, str]:
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir()
    key = root / "verity-apk-2026.rsa"
    keys = root / "keys"
    keys.mkdir()
    subprocess.run(["melange", "keygen", str(key)], check=True)
    shutil.copy2(key.with_suffix(".rsa.pub"), keys / "verity-apk-2026.rsa.pub")

    build = root / "build"
    recipe = Path(__file__).resolve().parents[1] / "packages/openssl-fips-provider/melange.yaml"
    subprocess.run(
        ["melange", "build", str(recipe), "--arch", "x86_64", "--runner", "docker", "--out-dir", str(build / "packages"), "--cache-dir", str(build / "cache")],
        check=True,
    )
    packages = root / "packages"
    package = packages / "x86_64" / "openssl-fips-provider-3.1.2-r2.apk"
    package.parent.mkdir(parents=True)
    shutil.copy2(next((build / "packages").rglob(package.name)), package)
    assert len(apk_archive.gzip_members(package.read_bytes(), 2)) == 2

    other = packages / "aarch64" / package.name
    other.parent.mkdir()
    write_unsigned(other, "aarch64", payload("aarch64"))
    for archive in (package, other):
        assert len(apk_archive.gzip_members(archive.read_bytes(), 2)) == 2
        sign(archive, key)
        assert len(apk_archive.gzip_members(archive.read_bytes(), 3)) == 3
    repository = root / "repository"
    subprocess.run([str(ASSEMBLE), str(packages), str(repository), str(key), "fixture"], check=True)
    package = repository / "x86_64" / package.name
    index = repository / "x86_64" / "APKINDEX.tar.gz"
    apk_repository_policy.verify(package, keys)
    apk_repository_policy.verify(index, keys)
    return package, keys, hashlib.sha256((repository / "manifest.json").read_bytes()).hexdigest()


def unit_tests() -> None:
    valid = signed_shape(unsigned_package("x86_64", payload("x86_64")))
    assert apk_archive.package_info(valid, "x86_64", apk_repository_policy.REQUIRED_FILES).name == "openssl-fips-provider"
    rejects_package(valid[:-1])
    rejects_package(valid + b"suffix")
    rejects_identity(signed_shape(unsigned_package("x86_64", payload("x86_64"), name="other")))
    rejects_package(signed_shape(unsigned_package("aarch64", payload("aarch64"))))
    rejects_package(signed_shape(unsigned_package("x86_64", payload("x86_64")[:-1])))
    rejects_package(signed_shape(unsigned_package("x86_64", payload("x86_64") + (entry("etc/evil", b"bad"),))))
    rejects_package(signed_shape(unsigned_package("x86_64", payload("x86_64") + (entry("var/lib/db/sbom/other.spdx.json", b"{}"),))))
    rejects_package(signed_shape(unsigned_package("x86_64", payload("x86_64") + (entry("usr/share/openssl-fips/fipsmodule.cnf", b"generated"),))))
    rejects_package(signed_shape(unsigned_package("x86_64", payload("x86_64") + (entry("usr/lib/ossl-modules/fips.so", elf("x86_64")),))))
    rejects_package(signed_shape(unsigned_package("x86_64", (entry("../escape", b"bad"),) + payload("x86_64")[1:])))
    rejects_package(signed_shape(unsigned_package("x86_64", (entry("usr/lib/ossl-modules/fips.so", typeflag=tarfile.SYMTYPE, linkname="/etc/passwd"),) + payload("x86_64")[1:])))
    rejects_package(signed_shape(unsigned_package("x86_64", (entry("usr/lib/ossl-modules/fips.so", typeflag=tarfile.CHRTYPE),) + payload("x86_64")[1:])))
    rejects_package(b"\x1f\x8b\x08\x00" + b"x" * (apk_archive.MAX_ARCHIVE_SIZE + 1))


def crypto_tests() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        package, keys, digest = repository(root)
        apk_repository_policy.validate(root, keys, digest)
        rejects_repository(root, keys, "0" * 64)
        signed = package.read_bytes()
        package.write_bytes(signed[:20] + bytes([signed[20] ^ 1]) + signed[21:])
        rejects_repository(root, keys, digest)

        package, keys, digest = repository(root)
        signature, control, data = apk_archive.gzip_members(package.read_bytes(), 3)
        changed_payload = tuple(entry(name, contents + b"changed" if name.endswith("fips.so") else contents) for name, contents in apk_archive.tar_files(data.plain))
        changed_data = gzip_member(pack_tar(changed_payload, final=True))
        package.write_bytes(signature.compressed + control.compressed + changed_data)
        rejects_repository(root, keys, digest)

        package, keys, digest = repository(root)
        _, _, data = apk_archive.gzip_members(package.read_bytes(), 3)
        replacement = unsigned_package("x86_64", payload("x86_64"), datahash=hashlib.sha256(data.compressed).hexdigest(), extra="pkgdesc = changed\n")
        package.write_bytes(replacement)
        sign(package, root / "fixture.rsa")
        manifest = root / "manifest.json"
        values = json.loads(manifest.read_text(encoding="utf-8"))
        target = next(entry for entry in values["packages"] if entry["architecture"] == "x86_64")
        target["sha256"] = hashlib.sha256(package.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
        digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
        apk_repository_policy.verify(package, keys)
        rejects_repository(root, keys, digest)


def real_melange_tests() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        package, keys, digest = real_repository(root)
        repository = root / "repository"
        apk_repository_policy.verify(package, keys)
        assert apk_archive.package_info(package.read_bytes(), "x86_64", apk_repository_policy.REQUIRED_FILES).version == "3.1.2-r2"
        apk_repository_policy.validate(repository, keys, digest)
        command = [
            "bash",
            str(ROOT / "scripts/verify_apk_repository.sh"),
            str(repository),
            str(keys / "verity-apk-2026.rsa.pub"),
        ]
        subprocess.run(command, check=True)
        signed = package.read_bytes()
        package.write_bytes(signed[:20] + bytes([signed[20] ^ 1]) + signed[21:])
        result = subprocess.run(command, check=False)
        assert result.returncode != 0


def main() -> None:
    unit_tests()
    crypto_tests()
    real_melange_tests()


if __name__ == "__main__":
    main()
