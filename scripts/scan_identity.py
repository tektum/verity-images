#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run (build_candidate.sh calls this once per platform, right after Syft):
#   uv run scripts/scan_identity.py CONTEXT RECIPE SBOM SYFT_JSON
"""Declare the main software of a source-built image to the scanners, or fail closed.

Melange stamps a .note.package into every binary it builds, so Syft reports the
main software as a renamed apk that no vulnerability feed knows. A declared
`scan-identity` in metadata.yaml adds one SPDX package per entry, versioned from
the recipe, so Grype matches the software itself. Without a declared identity the
image must expose a versioned main component natively, or sit on the shrink-only
allowlist in scripts/scan_identity_allowlist.txt.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Final

import gen_matrix

ROOT: Final = Path(__file__).resolve().parents[1]
ALLOWLIST: Final = ROOT / "scripts/scan_identity_allowlist.txt"
VERSION: Final = re.compile(r"[0-9][0-9A-Za-z._-]*")
UNVERSIONED: Final = {"", "UNKNOWN", "(devel)"}
FOLLOW_UPS: Final = frozenset({"identity", "go-version", "unverified"})
NOT_APPLICABLE: Final = "not-applicable"


class CoverageError(Exception):
    """The image's main software is invisible to the scanners, or its coverage declaration is invalid."""


def recipe_version(recipe: Path) -> str:
    """The upstream version a recipe builds: vars.upstream-version, else package.version."""
    contents = recipe.read_text(encoding="utf-8")
    version = gen_matrix.block_scalar(contents, "vars", "upstream-version") or gen_matrix.block_scalar(
        contents, "package", "version"
    )
    if version is None or not VERSION.fullmatch(version):
        raise CoverageError(f"{recipe}: package.version {version!r} cannot version a scan identity")
    return version


def recipe_package(recipe: Path) -> str:
    name = gen_matrix.block_scalar(recipe.read_text(encoding="utf-8"), "package", "name")
    if name is None:
        raise CoverageError(f"{recipe}: package.name is missing")
    return name


def identity_package(identity: str, version: str, index: int, source: str) -> dict:
    """One SPDX package for a declared identity; the shape Grype matches through its stock and Go matchers."""
    if (cpe := gen_matrix.SCAN_IDENTITY_CPE.fullmatch(identity)) is not None:
        vendor, product = cpe.groups()
        name = product
        refs = [
            ("SECURITY", "cpe23Type", f"cpe:2.3:a:{vendor}:{product}:{version}:*:*:*:*:*:*:*"),
            ("PACKAGE-MANAGER", "purl", f"pkg:generic/{product}@{version}"),
        ]
    else:
        kind, name = identity[len("pkg:") :].split("/", 1)
        version = f"v{version}" if kind == "golang" else version
        refs = [("PACKAGE-MANAGER", "purl", f"pkg:{kind}/{name}@{version}")]
    return {
        "name": name,
        "SPDXID": f"SPDXRef-Package-scan-identity-{index}",
        "versionInfo": version,
        "supplier": "NOASSERTION",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "sourceInfo": f"declared by scan-identity in {source}",
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "externalRefs": [
            {"referenceCategory": category, "referenceType": kind_, "referenceLocator": locator}
            for category, kind_, locator in refs
        ],
    }


def inject(sbom: dict, identities: tuple[str, ...], version: str, source: str) -> None:
    packages = [identity_package(item, version, index, source) for index, item in enumerate(identities)]
    sbom.setdefault("packages", []).extend(packages)
    root = next(
        (r["relatedSpdxElement"] for r in sbom.get("relationships", []) if r.get("relationshipType") == "DESCRIBES"),
        None,
    )
    if root is not None:
        sbom["relationships"].extend(
            {"spdxElementId": root, "relatedSpdxElement": p["SPDXID"], "relationshipType": "CONTAINS"}
            for p in packages
        )


def declared_missing(sbom: dict, identities: tuple[str, ...], version: str) -> list[str]:
    """Declared identities with no matching package in the SBOM."""
    present = {
        ref["referenceLocator"] for package in sbom.get("packages", []) for ref in package.get("externalRefs", [])
    }
    return [
        item
        for item in identities
        if identity_package(item, version, 0, "")["externalRefs"][0]["referenceLocator"] not in present
    ]


def native_components(syft: dict, origin: str, version: str) -> list[str]:
    """Versioned main components that live in files owned by the image-local recipe's apk."""
    artifacts = syft.get("artifacts", [])
    owned = {
        entry["path"]
        for artifact in artifacts
        if artifact.get("type") == "apk"
        and (artifact["name"] == origin or artifact.get("metadata", {}).get("originPackage") == origin)
        for entry in artifact.get("metadata", {}).get("files") or []
    }
    found = []
    for artifact in artifacts:
        name, found_version = artifact["name"], artifact.get("version", "")
        if not owned.intersection(location["path"] for location in artifact.get("locations", [])):
            continue
        match artifact.get("type"):
            case "go-module" if name == "stdlib":
                main = found_version == f"go{version}"
            case "go-module":
                main = artifact.get("metadata", {}).get("mainModule") == name and found_version not in UNVERSIONED
            case "rust-crate":
                main = found_version == version
            case _:
                main = False
        if main:
            found.append(f"{name}@{found_version}")
    return sorted(set(found))


def read_allowlist(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2 or fields[1] not in FOLLOW_UPS or fields[0] in entries:
            raise CoverageError(f"{path}:{number}: expected a unique 'CONTEXT {'|'.join(sorted(FOLLOW_UPS))}' entry")
        entries[fields[0]] = fields[1]
    return entries


def relative_context(context: Path) -> str:
    try:
        return context.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return context.as_posix()


def apply(context: Path, recipe: Path, sbom_path: Path, syft_path: Path, allowlist: Path = ALLOWLIST) -> str:
    """Inject the declared identity and enforce the coverage rule; returns a one-line status."""
    if recipe.name != "melange.yaml":
        return NOT_APPLICABLE
    version = recipe_version(recipe)
    sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
    identities = gen_matrix.parse_metadata(context / "metadata.yaml").scan_identity
    key = relative_context(context)
    if identities:
        inject(sbom, identities, version, f"{key}/metadata.yaml")
        sbom_path.write_text(json.dumps(sbom, indent=2) + "\n", encoding="utf-8")
        if missing := declared_missing(json.loads(sbom_path.read_text(encoding="utf-8")), identities, version):
            raise CoverageError(f"{key}: declared scan-identity missing from the SBOM: {', '.join(missing)}")
        return f"{key}: scanning declared identity {', '.join(identities)} at {version}"
    syft = json.loads(syft_path.read_text(encoding="utf-8"))
    listed = read_allowlist(allowlist)
    if components := native_components(syft, recipe_package(recipe), version):
        stale = "; stale allowlist entry, delete it" if key in listed else ""
        return f"{key}: scanner sees its main software natively: {', '.join(components)}{stale}"
    if key in listed:
        return f"{key}: ALLOWLISTED, main software not scanned (follow-up: {listed[key]})"
    raise CoverageError(
        f"{key}: the scanner cannot see this image's main software. Syft reports the melange package under a "
        "renamed apk and finds no versioned Go main module or Rust crate in files that package owns, so "
        "'0 fixable' would prove nothing. Declare scan-identity in metadata.yaml (see CONTRIBUTING.md) or, "
        "for Go, stamp the main module version."
    )


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("usage: scan_identity.py CONTEXT RECIPE SBOM SYFT_JSON")
    context, recipe, sbom, syft = (Path(argument) for argument in sys.argv[1:])
    try:
        status = apply(context, recipe, sbom, syft)
    except CoverageError as error:
        print(f"::error title=Scan coverage::{error}", file=sys.stderr)
        sys.exit(1)
    if status != NOT_APPLICABLE:
        print(status)


if __name__ == "__main__":
    main()
