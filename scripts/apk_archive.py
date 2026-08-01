from __future__ import annotations

import hashlib
import io
import tarfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ARCHITECTURES: Final = frozenset({"x86_64", "aarch64"})
MAX_ARCHIVE_SIZE: Final = 64 * 1024 * 1024
MAX_MEMBER_SIZE: Final = 32 * 1024 * 1024
MAX_ENTRIES: Final = 128
MAX_ENTRY_SIZE: Final = 16 * 1024 * 1024


@dataclass(frozen=True, slots=True)
class GzipMember:
    compressed: bytes
    plain: bytes


@dataclass(frozen=True, slots=True)
class PackageInfo:
    name: str
    version: str
    control: bytes
    size: int


@dataclass(frozen=True, slots=True)
class IndexRecord:
    name: str
    version: str
    architecture: str
    control: str
    size: int


def gzip_members(data: bytes, count: int) -> tuple[GzipMember, ...]:
    if not data or len(data) > MAX_ARCHIVE_SIZE:
        raise ValueError("invalid compressed archive size")
    members: list[GzipMember] = []
    remaining = data
    while remaining:
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            plain = inflater.decompress(remaining, MAX_MEMBER_SIZE + 1) + inflater.flush()
        except zlib.error as error:
            raise ValueError("invalid gzip member") from error
        consumed = len(remaining) - len(inflater.unused_data)
        if not inflater.eof or consumed == 0 or len(plain) > MAX_MEMBER_SIZE:
            raise ValueError("invalid gzip member")
        members.append(GzipMember(remaining[:consumed], plain))
        remaining = inflater.unused_data
    if len(members) != count:
        raise ValueError("unexpected gzip member count")
    return tuple(members)


def safe_name(name: str) -> bool:
    path = Path(name)
    return not path.is_absolute() and ".." not in path.parts and name not in {"", "."}


def tar_files(raw: bytes) -> tuple[tuple[str, bytes], ...]:
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            entries: list[tuple[str, bytes]] = []
            for entry in archive:
                if len(entries) >= MAX_ENTRIES or not safe_name(entry.name) or entry.issym() or entry.islnk() or entry.isdev():
                    raise ValueError("unsafe tar entry")
                if entry.size > MAX_ENTRY_SIZE:
                    raise ValueError("oversized tar entry")
                if entry.isfile():
                    source = archive.extractfile(entry)
                    if source is None:
                        raise ValueError("unreadable tar entry")
                    entries.append((entry.name, source.read()))
                elif not entry.isdir():
                    raise ValueError("unsupported tar entry")
    except (tarfile.TarError, OSError) as error:
        raise ValueError("invalid tar archive") from error
    return tuple(entries)


def fields(raw: bytes) -> dict[str, str]:
    try:
        return dict(line.split(" = ", maxsplit=1) for line in raw.decode("utf-8").splitlines() if " = " in line)
    except UnicodeDecodeError as error:
        raise ValueError("invalid package metadata") from error


def package_info(data: bytes, architecture: str, required_files: frozenset[str]) -> PackageInfo:
    signature, control, payload = gzip_members(data, 3)
    del signature
    control_files = tar_files(control.plain)
    if not control_files or control_files[0][0] != ".PKGINFO" or len(control_files) != 1:
        raise ValueError("invalid control archive")
    metadata = fields(control_files[0][1])
    if metadata.get("arch") != architecture or metadata.get("datahash") != hashlib.sha256(payload.compressed).hexdigest():
        raise ValueError("invalid package metadata")
    payload_files = tar_files(payload.plain)
    names = [name for name, _ in payload_files]
    if len(names) != len(set(names)) or set(names) != required_files:
        raise ValueError("invalid FIPS payload")
    module = dict(payload_files).get("usr/lib/ossl-modules/fips.so", b"")
    machines = {"x86_64": 62, "aarch64": 183}
    if len(module) < 20 or module[:5] != b"\x7fELF\x02" or module[5] != 1 or int.from_bytes(module[18:20], "little") != machines[architecture]:
        raise ValueError("invalid FIPS module ELF")
    name, version = metadata.get("pkgname", ""), metadata.get("pkgver", "")
    if not name or not version:
        raise ValueError("invalid package identity")
    return PackageInfo(name, version, control.compressed, len(data))


def index_records(data: bytes) -> tuple[IndexRecord, ...]:
    signature, index = gzip_members(data, 2)
    del signature
    files = tar_files(index.plain)
    if not files or files[0][0] != "APKINDEX" or {name for name, _ in files} - {"APKINDEX", "DESCRIPTION"}:
        raise ValueError("invalid index archive")
    records: list[IndexRecord] = []
    for paragraph in files[0][1].decode("utf-8").strip().split("\n\n"):
        values = dict(line.split(":", maxsplit=1) for line in paragraph.splitlines() if ":" in line)
        try:
            records.append(IndexRecord(values["P"], values["V"], values["A"], values["C"], int(values["S"])))
        except (KeyError, ValueError) as error:
            raise ValueError("invalid index record") from error
    if not records:
        raise ValueError("empty index")
    return tuple(records)
