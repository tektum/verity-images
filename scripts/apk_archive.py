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
MAX_MELANGE_RECIPE_SIZE: Final = 8 * 1024
MELANGE_RECIPE: Final = ".melange.yaml"


@dataclass(frozen=True, slots=True)
class GzipMember:
    compressed: bytes
    plain: bytes


@dataclass(frozen=True, slots=True)
class TarEntry:
    name: str
    contents: bytes | None


@dataclass(frozen=True, slots=True)
class RecipeInfo:
    name: str
    version: str
    epoch: int
    contents: bytes


@dataclass(frozen=True, slots=True)
class PackageInfo:
    name: str
    version: str
    epoch: int
    architecture: str
    recipe: RecipeInfo
    payload: tuple[TarEntry, ...]
    control: bytes
    size: int


@dataclass(frozen=True, slots=True)
class IndexRecord:
    name: str
    version: str
    architecture: str
    control: str
    size: int


def read_archive(path: Path) -> bytes:
    if path.stat().st_size > MAX_ARCHIVE_SIZE:
        raise ValueError("invalid compressed archive size")
    return path.read_bytes()


def gzip_members(data: bytes, count: int) -> tuple[GzipMember, ...]:
    if not data or len(data) > MAX_ARCHIVE_SIZE:
        raise ValueError("invalid compressed archive size")
    members: list[GzipMember] = []
    remaining = data
    while remaining:
        if len(members) >= count:
            raise ValueError("unexpected gzip member count")
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            plain = inflater.decompress(remaining, MAX_MEMBER_SIZE + 1)
            if inflater.unconsumed_tail:
                raise ValueError("invalid gzip member")
            plain += inflater.flush()
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


def tar_entries(raw: bytes) -> tuple[TarEntry, ...]:
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            entries: list[TarEntry] = []
            for entry in archive:
                if len(entries) >= MAX_ENTRIES or not safe_name(entry.name) or entry.issym() or entry.islnk() or entry.isdev():
                    raise ValueError("unsafe tar entry")
                if entry.size > MAX_ENTRY_SIZE:
                    raise ValueError("oversized tar entry")
                if entry.isfile():
                    source = archive.extractfile(entry)
                    if source is None:
                        raise ValueError("unreadable tar entry")
                    entries.append(TarEntry(entry.name, source.read()))
                elif entry.isdir():
                    entries.append(TarEntry(entry.name, None))
                else:
                    raise ValueError("unsupported tar entry")
    except (tarfile.TarError, OSError) as error:
        raise ValueError("invalid tar archive") from error
    return tuple(entries)


def tar_files(raw: bytes) -> tuple[tuple[str, bytes], ...]:
    return tuple((entry.name, entry.contents) for entry in tar_entries(raw) if entry.contents is not None)


def fields(raw: bytes) -> dict[str, str]:
    try:
        return dict(line.split(" = ", maxsplit=1) for line in raw.decode("utf-8").splitlines() if " = " in line)
    except UnicodeDecodeError as error:
        raise ValueError("invalid package metadata") from error


def recipe_info(raw: bytes) -> RecipeInfo:
    if not 0 < len(raw) <= MAX_MELANGE_RECIPE_SIZE:
        raise ValueError("invalid package recipe")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ValueError("invalid package recipe") from error
    values: dict[str, str] = {}
    in_package = False
    for line in lines:
        if line == "package:":
            in_package = True
        elif in_package and not line.startswith("  "):
            break
        elif in_package and ": " in line:
            key, value = line.strip().split(": ", maxsplit=1)
            if key in {"name", "version", "epoch"}:
                if key in values:
                    raise ValueError("invalid package recipe")
                values[key] = value.strip('"')
    epoch = values.get("epoch", "")
    if not values.get("name") or not values.get("version") or not epoch.isdecimal():
        raise ValueError("invalid package recipe")
    return RecipeInfo(values["name"], values["version"], int(epoch), raw)


def package_info(data: bytes, architecture: str) -> PackageInfo:
    signature, control, payload = gzip_members(data, 3)
    del signature
    control_entries = tar_entries(control.plain)
    control_files = {entry.name: entry.contents for entry in control_entries if entry.contents is not None}
    if set(control_files) != {".PKGINFO", MELANGE_RECIPE} or len(control_entries) != len(control_files):
        raise ValueError("invalid control archive")
    metadata = fields(control_files[".PKGINFO"])
    name, version = metadata.get("pkgname", ""), metadata.get("pkgver", "")
    package_version, separator, epoch = version.rpartition("-r")
    recipe_contents = control_files.get(MELANGE_RECIPE)
    if not name or not package_version or not separator or not epoch.isdecimal() or recipe_contents is None:
        raise ValueError("invalid control archive")
    recipe = recipe_info(recipe_contents)
    release = int(epoch)
    if (recipe.name, recipe.version, recipe.epoch) != (name, package_version, release):
        raise ValueError("package recipe identity mismatch")
    if metadata.get("arch") != architecture or metadata.get("datahash") != hashlib.sha256(payload.compressed).hexdigest():
        raise ValueError("invalid package metadata")
    payload_entries = tar_entries(payload.plain)
    return PackageInfo(name, version, release, architecture, recipe, payload_entries, control.compressed, len(data))


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
