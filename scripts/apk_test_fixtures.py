from __future__ import annotations

import hashlib
import io
import struct
import tarfile
import zlib
from pathlib import Path


RECIPE_VARS = {
    "openssl-fips-provider": "vars:\n  source-commit: 17a2c5111864d8e016c5f2d29c40a3746b559e9d\n  certificate: \"4985\"\n",
}
GOSU_RECIPE_VARS = {
    "1.19-r0": (
        "vars:\n  go-version: go1.26.5\n  source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513\n"
        "  x-sys-version: v0.44.0\nexpected-sha256: 33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b\n"
        "toolchain_sha256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053\n"
        "toolchain_sha256=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49\n"
        "expected=8db7d29ba324c44235b2407ec826f955a7025da25f2832cdab8e0cbcbcbc6025\n"
        "expected=420aa319c70e55403461e67ea2f1b50159b7b8c07317567c5c62397f2abdc859\n"
    ),
    "1.19-r1": (
        "vars:\n  go-version: go1.27.1\n  source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513\n"
        "  x-sys-version: v0.44.0\nexpected-sha256: 33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b\n"
        "toolchain_sha256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445\n"
        "toolchain_sha256=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec\n"
        "expected=80240f7a59b9f73624ea615a583f7a11f26fd6f49585eed84ff000692c0fe0d3\n"
        "expected=0b7e07759394360077fc6138729e86339468f6305a37448c1de3849eb725a4be\n"
    ),
    "1.19-r2": (
        "vars:\n  go-version: go1.27.2\n  source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513\n"
        "  x-sys-version: v0.44.0\n"
        "  moby-sys-user-version: v0.4.1\n"
        "expected-sha256: 33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b\n"
        "toolchain_sha256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5\n"
        "toolchain_sha256=94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8\n"
        "expected=b0b82bb02e5d240534facd299ef1124ec0f220253e05ba4e1b7abfadc2d60d7a\n"
        "expected=4001b2743924e7dc43e68685712ab87899b065faaa76b961516a0f87db3c5ba1\n"
    ),
    "1.19-r3": (
        "vars:\n  go-version: go1.27.3\n  source-commit: 6456aaa0f3c854d199d0f037f068eb97515b7513\n"
        "  x-sys-version: v0.44.0\n"
        "  moby-sys-user-version: v0.4.1\n"
        "expected-sha256: 33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b\n"
        "toolchain_sha256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40\n"
        "toolchain_sha256=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49\n"
        "expected=5361b0f18e47d19130845ab42e853b218414bfcb97c548c1cc26d284f83e8cea\n"
        "expected=f7561674748c361e192375e5a0eddadd07f2683055431396c61a580004122f69\n"
    ),
}


def recipe(name: str, version: str, recipe_vars: str | None = None) -> bytes:
    package_version, epoch = version.rsplit("-r", maxsplit=1)
    identity = f"package:\n  name: {name}\n  version: {package_version}\n  epoch: {epoch}\n"
    default_vars = GOSU_RECIPE_VARS.get(version, "") if name == "gosu" else RECIPE_VARS.get(name, "")
    return (identity + (default_vars if recipe_vars is None else recipe_vars)).encode()


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
