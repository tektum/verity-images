from __future__ import annotations

import hashlib
import io
import struct
import tarfile
import zlib
from pathlib import Path


RECIPE_VARS = {
    "openssl-fips-provider": "vars:\n  source-commit: 17a2c5111864d8e016c5f2d29c40a3746b559e9d\n  certificate: \"4985\"\n",
    "gosu": "vars:\n  go-version: go1.26.5\n  source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513\n  x-sys-version: v0.44.0\n",
}


def recipe(name: str, version: str, recipe_vars: str | None = None) -> bytes:
    package_version, epoch = version.rsplit("-r", maxsplit=1)
    identity = f"package:\n  name: {name}\n  version: {package_version}\n  epoch: {epoch}\n"
    return (identity + (RECIPE_VARS.get(name, "") if recipe_vars is None else recipe_vars)).encode()


def gzip_member(raw: bytes) -> bytes:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    body = compressor.compress(raw) + compressor.flush()
    return b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff" + body + struct.pack("<II", zlib.crc32(raw) & 0xFFFFFFFF, len(raw) & 0xFFFFFFFF)


def pack_tar(entries: tuple[tuple[tarfile.TarInfo, bytes | None], ...], *, final: bool) -> bytes:
    output = io.BytesIO()
    archive = tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT)
    for header, contents in entries:
        header.size = len(contents) if contents is not None else 0
        archive.addfile(header, io.BytesIO(contents) if contents is not None else None)
    offset = archive.offset
    archive.close()
    return output.getvalue()[:offset] + (b"\0" * 1024 if final else b"")


def entry(name: str, contents: bytes = b"", *, typeflag: bytes = tarfile.REGTYPE, linkname: str = "", mode: int | None = None) -> tuple[tarfile.TarInfo, bytes | None]:
    header = tarfile.TarInfo(name)
    header.type = typeflag
    header.linkname = linkname
    header.mode = mode if mode is not None else (0o755 if name.endswith("activate") else 0o644)
    header.pax_headers = {"APK-TOOLS.checksum.SHA1": hashlib.sha1(contents).hexdigest()} if typeflag == tarfile.REGTYPE else {}
    return header, contents if typeflag == tarfile.REGTYPE else None


def elf(architecture: str) -> bytes:
    machine = {"x86_64": 62, "aarch64": 183}[architecture]
    return b"\x7fELF\x02\x01\x01" + b"\0" * 11 + machine.to_bytes(2, "little")


def unsigned_package(architecture: str, payload: tuple[tuple[tarfile.TarInfo, bytes | None], ...], *, name: str = "openssl-fips-provider", version: str = "3.1.2-r3", datahash: str | None = None, extra: str = "", recipe_name: str | None = None, recipe_version: str | None = None, recipe_vars: str | None = None) -> bytes:
    data = gzip_member(pack_tar(payload, final=True))
    metadata = f"pkgname = {name}\npkgver = {version}\narch = {architecture}\ndatahash = {datahash or hashlib.sha256(data).hexdigest()}\n{extra}".encode()
    control = gzip_member(pack_tar((entry(".PKGINFO", metadata), entry(".melange.yaml", recipe(recipe_name or name, recipe_version or version, recipe_vars))), final=False))
    return control + data


def signed_shape(archive: bytes) -> bytes:
    signature = gzip_member(pack_tar((entry(".SIGN.RSA256.fixture.rsa.pub", b"signature"),), final=False))
    return signature + archive


def write_unsigned(path: Path, architecture: str, payload: tuple[tuple[tarfile.TarInfo, bytes | None], ...], **kwargs: str) -> None:
    path.write_bytes(unsigned_package(architecture, payload, **kwargs))
