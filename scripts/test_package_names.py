#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_package_names.py
"""Fail when an image-local melange package reuses a Wolfi package name.

Wolfi's security data is keyed by package name and version, so Grype applies
Wolfi's advisories to any local package that shares a Wolfi name. Raising the
local epoch above Wolfi's fixed revision then hides real Wolfi fixes along with
the false matches. A local package uses a distinct name instead (for example
`verity-vexctl`), and the scanner sees the main software through its Go module
or the declared `scan-identity`.

The names come from the Wolfi x86_64 APKINDEX (package and origin names) and
the Wolfi security database, which keeps names Wolfi no longer publishes.
`ALLOWLIST` holds the image contexts that predate this check. It may only
shrink: an entry that no longer collides fails the check.
"""

from __future__ import annotations

import io
import json
import re
import sys
import tarfile
import zlib
from pathlib import Path
from typing import Final


import classify_monitor_remediation as remediation

ROOT: Final = Path(__file__).resolve().parent.parent
APKINDEX_URL: Final = f"{remediation.WOLFI_REPOSITORY}/x86_64/APKINDEX.tar.gz"
SECDB_URL: Final = f"{remediation.WOLFI_REPOSITORY}/security.json"
# Image contexts whose epoch-0 package still shares a Wolfi name. Rename the
# package to `verity-<name>` and delete its entry here in the same change.
ALLOWLIST: Final = frozenset(
    {
        "images/envoy",
        "images/fluent-bit",
        "images/imagemagick",
        "images/kubernetes-reflector",
        "images/loki",
        "images/mailpit",
        "images/nginx-prometheus-exporter",
        "images/opa",
        "images/pgbouncer",
        "images/postgres/17",
        "images/proxysql",
        "images/sonar-scanner-cli",
        "images/valkey",
        "images/vector",
    }
)


def recipe_names(recipe: Path) -> list[str]:
    """Return the package name and every subpackage name a recipe produces.

    Reads only the top-level `package.name` and the `- name:` entries of the
    top-level `subpackages` list, the shapes every recipe here uses.
    """
    name = ""
    subnames: list[str] = []
    block = ""
    for raw in recipe.read_text(encoding="utf-8").splitlines():
        if raw and not raw[0].isspace() and not raw.startswith("#"):
            block = raw.split(":", maxsplit=1)[0]
            continue
        value = re.fullmatch(r"  (?:- )?name:\s*(\S(?:.*\S)?)", raw.split(" #", maxsplit=1)[0])
        if value is None:
            continue
        found = value.group(1).strip("\"'")
        if block == "package" and not raw.startswith("  - ") and not name:
            name = found
        elif block == "subpackages" and raw.startswith("  - "):
            subnames.append(found)
    if not name:
        return []
    return [name, *(subname.replace("${{package.name}}", name) for subname in subnames)]


def index_names(data: bytes) -> set[str]:
    """Return package and origin names from a gzip-concatenated APKINDEX.tar.gz."""
    names: set[str] = set()
    remaining = data
    while remaining:
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
        plain = inflater.decompress(remaining)
        remaining = inflater.unused_data
        with tarfile.open(fileobj=io.BytesIO(plain), mode="r:") as archive:
            member = next((item for item in archive.getmembers() if item.name == "APKINDEX"), None)
            if member is None:
                continue
            source = archive.extractfile(member)
            assert source is not None
            text = source.read().decode("utf-8")
            names.update(re.findall(r"^[Po]:(\S+)$", text, flags=re.MULTILINE))
    if not names:
        raise SystemExit("Wolfi APKINDEX has no package names")
    return names


def secdb_names(data: bytes) -> set[str]:
    names = {entry["pkg"]["name"] for entry in json.loads(data)["packages"]}
    if not names:
        raise SystemExit("Wolfi security database has no package names")
    return names


def collisions(root: Path, wolfi: set[str]) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for recipe in sorted(root.glob("images/**/*melange.yaml")):
        clashes = [name for name in recipe_names(recipe) if name in wolfi]
        if clashes:
            found.setdefault(recipe.parent.relative_to(root).as_posix(), []).extend(clashes)
    return found


def check(found: dict[str, list[str]], allowlist: frozenset[str]) -> list[str]:
    errors = [
        f"{context}: package name {', '.join(names)} is also a Wolfi package name; "
        "use a distinct name such as verity-<name> with epoch 0 instead of an epoch bump"
        for context, names in sorted(found.items())
        if context not in allowlist
    ]
    errors += [
        f"{context}: no longer shares a Wolfi package name; delete it from ALLOWLIST in {Path(__file__).name}"
        for context in sorted(allowlist - found.keys())
    ]
    return errors


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        recipes = {
            "images/clash": "package:\n  name: cosign\nsubpackages:\n  - name: ${{package.name}}-build-metadata\n",
            "images/distinct": "package:\n  name: verity-vexctl\n",
            "images/sub/1": "package:\n  name: verity-x\nsubpackages:\n  - name: libpq-17\n",
            "images/flavor": "package:\n  name: verity-y\n",
        }
        for context, text in recipes.items():
            (root / context).mkdir(parents=True)
            (root / context / "melange.yaml").write_text(text, encoding="utf-8")
        (root / "images/flavor/fips.melange.yaml").write_text("package:\n  name: yq\n", encoding="utf-8")
        wolfi = {"cosign", "libpq-17", "yq", "vexctl"}
        found = collisions(root, wolfi)
        assert found == {
            "images/clash": ["cosign"],
            "images/flavor": ["yq"],
            "images/sub/1": ["libpq-17"],
        }, found
        assert check(found, frozenset({"images/clash", "images/flavor", "images/sub/1"})) == []
        errors = check(found, frozenset({"images/clash", "images/distinct"}))
        assert len(errors) == 3, errors
        assert any(error.startswith("images/distinct: no longer") for error in errors), errors
        assert any(error.startswith("images/flavor: package name yq") for error in errors), errors

    index = io.BytesIO()
    with tarfile.open(fileobj=index, mode="w:") as archive:
        payload = b"C:Q1\nP:cosign-3\nV:3.1.4-r2\no:cosign\n\nP:yq\nV:4-r0\no:yq\n"
        info = tarfile.TarInfo("APKINDEX")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    signature = io.BytesIO()
    with tarfile.open(fileobj=signature, mode="w:") as archive:
        info = tarfile.TarInfo(".SIGN.RSA256.key.pub")
        info.size = 1
        archive.addfile(info, io.BytesIO(b"x"))

    def gzip(data: bytes) -> bytes:
        compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
        return compressor.compress(data) + compressor.flush()

    assert index_names(gzip(signature.getvalue()) + gzip(index.getvalue())) == {"cosign-3", "cosign", "yq"}
    assert secdb_names(b'{"packages":[{"pkg":{"name":"prometheus-blackbox-exporter"}}]}') == {
        "prometheus-blackbox-exporter"
    }


def main() -> None:
    self_test()
    try:
        wolfi = index_names(remediation.fetch_url(APKINDEX_URL, remediation.MAX_INDEX_DOWNLOAD))
        wolfi |= secdb_names(remediation.fetch_url(SECDB_URL, remediation.MAX_INDEX_DOWNLOAD))
    except remediation.RepositoryError as error:
        raise SystemExit(f"cannot read Wolfi package names: {error}") from error
    if errors := check(collisions(ROOT, wolfi), ALLOWLIST):
        for error in errors:
            print(f"::error title=Wolfi package name collision::{error}", file=sys.stderr)
        sys.exit(1)
    print(f"no image-local package shares one of {len(wolfi)} Wolfi package names")


if __name__ == "__main__":
    main()
