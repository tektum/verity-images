#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_package_names.py            # check against the snapshot
#   uv run scripts/test_package_names.py --refresh  # rewrite the snapshot from Wolfi
"""Fail when an image-local melange package reuses a Wolfi package name.

Wolfi's security data is keyed by package name and version, so Grype applies
Wolfi's advisories to any local package that shares a Wolfi name. Raising the
local epoch above Wolfi's fixed revision then hides real Wolfi fixes along with
the false matches. A local package uses a distinct name instead (for example
`verity-vexctl`), and the scanner sees the main software through its Go module
or the declared `scan-identity`.

The names come from the Wolfi x86_64 APKINDEX (package and origin names) and
the Wolfi security database, which keeps names Wolfi no longer publishes. The
check reads the committed snapshot in `wolfi_package_names.txt`, so its result
depends only on the commit; `--refresh` rewrites the snapshot, and the refresh
change is where a newly published Wolfi name surfaces as a collision.
`ALLOWLIST` holds the names that predate this check, per image context. It may
only shrink: an entry that no longer collides fails the check.
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
SNAPSHOT: Final = Path(__file__).resolve().parent / "wolfi_package_names.txt"
APKINDEX_URL: Final = f"{remediation.WOLFI_REPOSITORY}/x86_64/APKINDEX.tar.gz"
SECDB_URL: Final = f"{remediation.WOLFI_REPOSITORY}/security.json"
NAME: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
# Package names that still share a Wolfi name, per image context. Rename the
# package to `verity-<name>` and delete its entry here in the same change. The
# remaining epoch-bumped entries go with their open rename pull requests.
ALLOWLIST: Final[dict[str, frozenset[str]]] = {
    "images/envoy": frozenset({"envoy-1.37", "envoy-1.37-config"}),
    "images/fluent-bit": frozenset({"fluent-bit-4.2"}),
    "images/imagemagick": frozenset({"imagemagick-7"}),
    "images/ko": frozenset({"ko"}),
    "images/kubernetes-reflector": frozenset({"kubernetes-reflector"}),
    "images/loki": frozenset({"loki-3.6"}),
    "images/mailpit": frozenset({"mailpit"}),
    "images/nginx-prometheus-exporter": frozenset({"nginx-prometheus-exporter"}),
    "images/opa": frozenset({"opa"}),
    "images/pgbouncer": frozenset({"pgbouncer"}),
    "images/postgres/17": frozenset(
        {
            "ecpg-17",
            "libecpg-17",
            "libpq-17",
            "postgresql-17",
            "postgresql-17-base",
            "postgresql-17-client",
            "postgresql-17-client-base",
            "postgresql-17-contrib",
            "postgresql-17-dev",
            "postgresql-17-oci-entrypoint-compat",
        }
    ),
    "images/proxysql": frozenset({"proxysql"}),
    "images/sonar-scanner-cli": frozenset({"sonar-scanner-cli"}),
    "images/valkey": frozenset({"valkey-9.0", "valkey-9.0-cli"}),
    "images/vector": frozenset({"vector"}),
    "images/velero": frozenset({"velero"}),
}


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
        value = re.fullmatch(r"  (?:- )?name:\s*(\S(?:.*\S)?)", raw.split(" #", maxsplit=1)[0].rstrip())
        if value is None:
            continue
        found = value.group(1).strip("\"'")
        if block == "package" and not raw.startswith("  - ") and not name:
            name = found
        elif block == "subpackages" and raw.startswith("  - "):
            subnames.append(found)
    if not name:
        raise SystemExit(f"{recipe}: cannot read package.name")
    return [name, *(subname.replace("${{package.name}}", name) for subname in subnames)]


def index_names(data: bytes) -> set[str]:
    """Return package and origin names from a gzip-concatenated APKINDEX.tar.gz."""
    names: set[str] = set()
    remaining = data
    while remaining:
        _, plain, remaining = remediation.gzip_member(remaining, remediation.MAX_INDEX_CONTENTS)
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


def check(found: dict[str, list[str]], allowlist: dict[str, frozenset[str]]) -> list[str]:
    errors = []
    for context, names in sorted(found.items()):
        if new := [name for name in names if name not in allowlist.get(context, frozenset())]:
            errors.append(
                f"{context}: package name {', '.join(new)} is also a Wolfi package name; "
                "use a distinct name such as verity-<name> with epoch 0 instead of an epoch bump"
            )
    for context, names in sorted(allowlist.items()):
        if stale := sorted(names - set(found.get(context, []))):
            errors.append(
                f"{context}: {', '.join(stale)} no longer shares a Wolfi package name; "
                f"delete it from ALLOWLIST in {Path(__file__).name}"
            )
    return errors


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        recipes = {
            "images/clash": "package:\n  name: cosign  # c\nsubpackages:\n  - name: ${{package.name}}-build-metadata\n",
            "images/distinct": "package:\n  name: verity-vexctl\n",
            "images/sub/1": "package:\n  name: verity-x\nsubpackages:\n  - name: libpq-17  # c\n",
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
        allowed = {
            "images/clash": frozenset({"cosign"}),
            "images/flavor": frozenset({"yq"}),
            "images/sub/1": frozenset({"libpq-17"}),
        }
        assert check(found, allowed) == []
        errors = check(found, allowed | {"images/sub/1": frozenset({"libpq-17", "ecpg-17"})})
        assert len(errors) == 1 and errors[0].startswith("images/sub/1: ecpg-17 no longer"), errors
        errors = check(found | {"images/sub/1": ["libpq-17", "libecpg-17"]}, allowed)
        assert len(errors) == 1 and errors[0].startswith("images/sub/1: package name libecpg-17 is"), errors
        errors = check(found, {"images/clash": frozenset({"cosign"}), "images/distinct": frozenset({"vexctl"})})
        assert len(errors) == 3, errors
        assert any(error.startswith("images/distinct: vexctl no longer") for error in errors), errors
        assert any(error.startswith("images/flavor: package name yq") for error in errors), errors
        (root / "images/distinct/melange.yaml").write_text("package:\n  name:\n    verity-vexctl\n", encoding="utf-8")
        try:
            collisions(root, wolfi)
        except SystemExit as error:
            assert "cannot read package.name" in str(error), error
        else:
            raise AssertionError("a recipe without a readable package.name passed")

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

    complete = gzip(signature.getvalue()) + gzip(index.getvalue())
    assert index_names(complete) == {"cosign-3", "cosign", "yq"}
    try:
        index_names(complete[:-8])
    except remediation.RepositoryError:
        pass
    else:
        raise AssertionError("an APKINDEX cut before its gzip trailer passed")
    assert secdb_names(b'{"packages":[{"pkg":{"name":"prometheus-blackbox-exporter"}}]}') == {
        "prometheus-blackbox-exporter"
    }
    assert snapshot_names("cosign\nyq\n") == {"cosign", "yq"}
    for text in ("", "yq\ncosign\n", "cosign\ncosign\n", "cosign\n\n", "cosign # c\n"):
        try:
            snapshot_names(text)
        except SystemExit:
            continue
        raise AssertionError(f"snapshot {text!r} passed")


def snapshot_names(text: str) -> set[str]:
    """Return the names of a sorted, duplicate-free, one-name-per-line snapshot."""
    lines = text.splitlines()
    if not lines or lines != sorted(set(lines)) or not all(NAME.fullmatch(line) for line in lines):
        raise SystemExit(f"{SNAPSHOT.name} must list one Wolfi package name per line, sorted and unique")
    return set(lines)


def refresh() -> None:
    try:
        wolfi = index_names(remediation.fetch_url(APKINDEX_URL, remediation.MAX_INDEX_DOWNLOAD))
        wolfi |= secdb_names(remediation.fetch_url(SECDB_URL, remediation.MAX_INDEX_DOWNLOAD))
    except remediation.RepositoryError as error:
        raise SystemExit(f"cannot read Wolfi package names: {error}") from error
    text = "".join(f"{name}\n" for name in sorted(wolfi))
    snapshot_names(text)
    SNAPSHOT.write_text(text, encoding="utf-8")
    print(f"wrote {len(wolfi)} Wolfi package names to {SNAPSHOT.relative_to(ROOT)}")


def main() -> None:
    self_test()
    if sys.argv[1:] == ["--refresh"]:
        refresh()
    elif sys.argv[1:]:
        raise SystemExit("usage: test_package_names.py [--refresh]")
    wolfi = snapshot_names(SNAPSHOT.read_text(encoding="utf-8"))
    if errors := check(collisions(ROOT, wolfi), ALLOWLIST):
        for error in errors:
            print(f"::error title=Wolfi package name collision::{error}", file=sys.stderr)
        sys.exit(1)
    print(f"no image-local package shares one of {len(wolfi)} Wolfi package names")


if __name__ == "__main__":
    main()
