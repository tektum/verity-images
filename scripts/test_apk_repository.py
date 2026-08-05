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
from unittest.mock import patch
from pathlib import Path

import apk_archive
import apk_repository_policy
from apk_test_fixtures import elf, entry, gzip_member, pack_tar, signed_shape, unsigned_package, write_unsigned

ROOT = Path(__file__).resolve().parents[1]
ASSEMBLE = ROOT / ".github/scripts/assemble-apk-repository.sh"


def payload(architecture: str, name: str = "openssl-fips-provider") -> tuple[tuple[tarfile.TarInfo, bytes | None], ...]:
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
        entry(f"var/lib/db/sbom/{name}-3.1.2-r3.spdx.json", b"{}"),
    )


def generic_payload() -> tuple[tuple[tarfile.TarInfo, bytes | None], ...]:
    return (
        entry("usr", typeflag=tarfile.DIRTYPE),
        entry("usr/bin", typeflag=tarfile.DIRTYPE),
        entry("usr/bin/example-package", b"#!/bin/sh\n"),
    )


def rejects_package(data: bytes, architecture: str = "x86_64") -> None:
    try:
        apk_repository_policy.validate_package(apk_archive.package_info(data, architecture))
    except ValueError:
        return
    raise AssertionError("invalid package was accepted")


def sign(path: Path, key: Path) -> None:
    subprocess.run(["melange", "sign", "--signing-key", str(key), str(path)], check=True)


def repository(root: Path, key_name: str = "fixture.rsa") -> tuple[Path, Path, str]:
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir()
    key = root / key_name
    keys = root / "keys"
    keys.mkdir()
    subprocess.run(["melange", "keygen", str(key)], check=True)
    shutil.copy2(key.with_suffix(".rsa.pub"), keys / key.with_suffix(".rsa.pub").name)
    packages: list[dict[str, str]] = []
    for architecture in sorted(apk_repository_policy.ARCHITECTURES):
        directory = root / architecture
        directory.mkdir()
        archives: list[Path] = []
        for name, version in (("example-package", "1.0.0-r1"), ("openssl-fips-provider", "3.1.2-r3")):
            package = directory / f"{name}-{version}.apk"
            write_unsigned(package, architecture, generic_payload() if name == "example-package" else payload(architecture), name=name, version=version)
            sign(package, key)
            archives.append(package)
            packages.append({"architecture": architecture, "name": name, "version": version, "epoch": int(version.rsplit("-r", maxsplit=1)[1]), "path": package.relative_to(root).as_posix(), "sha256": hashlib.sha256(package.read_bytes()).hexdigest()})
        subprocess.run(["melange", "index", "--arch", architecture, "--signing-key", str(key), "--output", str(directory / "APKINDEX.tar.gz"), *(str(package) for package in archives)], check=True)
    manifest = root / "manifest.json"
    manifest.write_text(json.dumps({"architectures": sorted(apk_repository_policy.ARCHITECTURES), "packages": packages}, sort_keys=True), encoding="utf-8")
    return root / "x86_64" / "openssl-fips-provider-3.1.2-r3.apk", keys, hashlib.sha256(manifest.read_bytes()).hexdigest()


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
    package = packages / "x86_64" / "openssl-fips-provider-3.1.2-r3.apk"
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
    entries = []
    for archive in (package, other):
        architecture = archive.parent.name
        entries.append({"architecture": architecture, "name": "openssl-fips-provider", "version": "3.1.2-r3", "epoch": 3, "path": archive.relative_to(packages).as_posix(), "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "origin": {"type": "legacy-snapshot", "releaseId": 1, "releaseTag": "apk-repo-v0002", "targetCommit": "0" * 40, "assetId": 1, "assetSha256": "sha256:" + "0" * 64, "manifestSha256": "0" * 64, "sourcePath": archive.relative_to(packages).as_posix()}})
    metadata = root / "metadata.json"
    public = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
    fingerprint = hashlib.sha256(public).hexdigest()
    metadata.write_text(json.dumps({"schemaVersion": 2, "architectures": ["aarch64", "x86_64"], "fingerprint": fingerprint, "packages": entries}, sort_keys=True), encoding="utf-8")
    repository = root / "repository"
    subprocess.run([str(ASSEMBLE), str(packages), str(metadata), str(repository), str(root / "repository.tar.zst"), str(key), fingerprint], check=True)
    package = repository / "x86_64" / package.name
    index = repository / "x86_64" / "APKINDEX.tar.gz"
    apk_repository_policy.verify(package, keys)
    apk_repository_policy.verify(index, keys)
    return package, keys, hashlib.sha256((repository / "manifest.json").read_bytes()).hexdigest()


def unit_tests() -> None:
    valid = signed_shape(unsigned_package("x86_64", payload("x86_64")))
    assert apk_repository_policy.validate_package(apk_archive.package_info(valid, "x86_64")).name == "openssl-fips-provider"
    generic = signed_shape(unsigned_package("x86_64", generic_payload(), name="example-package", version="1.0.0-r1"))
    info = apk_repository_policy.validate_package(apk_archive.package_info(generic, "x86_64"))
    assert (info.name, info.version, info.epoch, info.architecture) == ("example-package", "1.0.0-r1", 1, "x86_64")
    disagreement = signed_shape(unsigned_package("x86_64", generic_payload(), name="example-package", version="1.0.0-r1", recipe_name="forged-package"))
    try:
        apk_archive.package_info(disagreement, "x86_64")
    except ValueError as error:
        assert str(error) == "package recipe identity mismatch"
    else:
        raise AssertionError("package recipe disagreement was accepted")
    try:
        apk_archive.recipe_info(b"package:\n  nested:\n    name: example-package\n    version: 1.0.0\n    epoch: 1\n")
    except ValueError:
        pass
    else:
        raise AssertionError("nested package identity was accepted")
    signature, _, data = apk_archive.gzip_members(valid, 3)
    missing_pkginfo = signature.compressed + gzip_member(pack_tar((entry(".melange.yaml", b"recipe"),), final=False)) + data.compressed
    rejects_package(missing_pkginfo)
    rejects_package(valid[:-1])
    rejects_package(valid + b"suffix")
    assert apk_archive.package_info(signed_shape(unsigned_package("x86_64", payload("x86_64", "other"), name="other")), "x86_64").name == "other"
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
    extra_member = gzip_member(b"extra member")
    with patch.object(apk_archive.zlib, "decompressobj", wraps=apk_archive.zlib.decompressobj) as decompressobj:
        rejects_package(valid + extra_member)
        assert decompressobj.call_count == 3

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        manifest = root / "manifest.json"
        manifest.write_text(
            json.dumps({"architectures": ["aarch64", "x86_64", "x86_64"], "packages": []}),
            encoding="utf-8",
        )
        try:
            apk_repository_policy.validate(root, root, hashlib.sha256(manifest.read_bytes()).hexdigest())
        except ValueError as error:
            assert str(error) == "unexpected architecture set"
        else:
            raise AssertionError("duplicate architecture rows were accepted")


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

        package, keys, digest = repository(root)
        manifest = root / "manifest.json"
        values = json.loads(manifest.read_text(encoding="utf-8"))
        values["packages"].pop()
        manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
        rejects_repository(root, keys, hashlib.sha256(manifest.read_bytes()).hexdigest())


def manifest_identity_tests() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        for field, forged in (("name", "forged-package"), ("version", "9.9.9-r9"), ("epoch", 9), ("epoch", True)):
            _, keys, _ = repository(root)
            manifest = root / "manifest.json"
            values = json.loads(manifest.read_text(encoding="utf-8"))
            values["packages"][0][field] = forged
            manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
            rejects_repository(root, keys, hashlib.sha256(manifest.read_bytes()).hexdigest())


def real_melange_tests() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        package, keys, digest = real_repository(root)
        repository = root / "repository"
        apk_repository_policy.verify(package, keys)
        assert apk_archive.package_info(package.read_bytes(), "x86_64").version == "3.1.2-r3"
        apk_repository_policy.validate(repository, keys, digest)
        renamed = package.with_name("fixture.apk")
        package.rename(renamed)
        manifest = repository / "manifest.json"
        values = json.loads(manifest.read_text(encoding="utf-8"))
        next(entry for entry in values["packages"] if entry["path"] == package.relative_to(repository).as_posix())["path"] = renamed.relative_to(repository).as_posix()
        manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
        package = renamed
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
    manifest_identity_tests()
    unit_tests()
    crypto_tests()
    real_melange_tests()


if __name__ == "__main__":
    main()
