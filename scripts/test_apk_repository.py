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


def gosu_payload(binary: bytes, version: str = "1.19-r0", mode: int = 0o755) -> tuple[tuple[tarfile.TarInfo, bytes | None], ...]:
    return (
        entry("usr", typeflag=tarfile.DIRTYPE),
        entry("usr/bin", typeflag=tarfile.DIRTYPE),
        entry("usr/bin/gosu", binary, mode=mode),
        entry("var", typeflag=tarfile.DIRTYPE),
        entry("var/lib", typeflag=tarfile.DIRTYPE),
        entry("var/lib/db", typeflag=tarfile.DIRTYPE),
        entry("var/lib/db/sbom", typeflag=tarfile.DIRTYPE),
        entry(f"var/lib/db/sbom/gosu-{version}.spdx.json", b"{}"),
    )


def gosu_package(payload: tuple[tuple[tarfile.TarInfo, bytes | None], ...], architecture: str = "x86_64", version: str = "1.19-r0", **kwargs: str) -> bytes:
    return signed_shape(unsigned_package(architecture, payload, name="gosu", version=version, **kwargs))


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


_KEYPAIR: tuple[bytes, bytes] | None = None


def keypair() -> tuple[bytes, bytes]:
    # melange keygen spends about half a second on a 4096 bit prime and the
    # fixtures only need a well formed RSA key, so one keypair is generated per
    # process and every repository reuses it under its own key name.
    global _KEYPAIR
    if _KEYPAIR is None:
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "fixture.rsa"
            subprocess.run(["melange", "keygen", str(key)], check=True)
            _KEYPAIR = (key.read_bytes(), key.with_suffix(".rsa.pub").read_bytes())
    return _KEYPAIR


def repository(root: Path, key_name: str = "fixture.rsa") -> tuple[Path, Path, str]:
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir()
    key = root / key_name
    keys = root / "keys"
    keys.mkdir()
    private, public = keypair()
    key.write_bytes(private)
    key.with_suffix(".rsa.pub").write_bytes(public)
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


def gosu_tests() -> None:
    binary = elf("x86_64") + b"\0" * 64
    arm_binary = elf("aarch64") + b"\0" * 64
    digests = {"x86_64": hashlib.sha256(binary).hexdigest(), "aarch64": hashlib.sha256(arm_binary).hexdigest()}
    # The published binary digests cannot be forged, so the pinned table is
    # swapped for the fixture digests to exercise every other gosu rule.
    with patch.dict(apk_repository_policy.GOSU_BINARY_SHA256, digests):
        info = apk_repository_policy.validate_package(apk_archive.package_info(gosu_package(gosu_payload(binary)), "x86_64"))
        assert (info.name, info.version, info.epoch, info.architecture) == ("gosu", "1.19-r0", 0, "x86_64")
        arm = apk_repository_policy.validate_package(apk_archive.package_info(gosu_package(gosu_payload(arm_binary), "aarch64"), "aarch64"))
        assert (arm.name, arm.version, arm.epoch, arm.architecture) == ("gosu", "1.19-r0", 0, "aarch64")
        rejects_package(gosu_package(gosu_payload(arm_binary)))
        rejects_package(gosu_package(gosu_payload(binary) + (entry("etc/evil", b"bad"),)))
        rejects_package(gosu_package(gosu_payload(binary)[:-1]))
        rejects_package(gosu_package(gosu_payload(binary) + (entry("usr/bin/other", b"extra"),)))
        rejects_package(gosu_package(gosu_payload(binary), recipe_vars="vars:\n  x-sys-version: v0.43.0\n"))
        rejects_package(gosu_package(gosu_payload(binary), "aarch64"), "aarch64")
        # A non-executable binary is unusable once installed.
        rejects_package(gosu_package(gosu_payload(binary, mode=0o644)))
        # The published identity is pinned, so a rebuilt version cannot be reserved.
        rejects_package(gosu_package(gosu_payload(binary, version="1.20-r0"), version="1.20-r0"))
    # The real pinned digests reject any other binary.
    rejects_package(gosu_package(gosu_payload(binary)))


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
    except ValueError as error:
        assert str(error) == "invalid package recipe"
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

        for missing in (("name",), ("version",), ("epoch",), ("name", "version"), ("name", "epoch"), ("version", "epoch"), ("name", "version", "epoch")):
            _, keys, _ = repository(root)
            values = json.loads(manifest.read_text(encoding="utf-8"))
            values["packages"] = [{field: value for field, value in package.items() if field not in missing} for package in values["packages"]]
            manifest.write_text(json.dumps(values, sort_keys=True), encoding="utf-8")
            (apk_repository_policy.validate if len(missing) == 3 else rejects_repository)(root, keys, hashlib.sha256(manifest.read_bytes()).hexdigest())


def main() -> None:
    manifest_identity_tests()
    unit_tests()
    gosu_tests()
    crypto_tests()


if __name__ == "__main__":
    main()
