#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run (build_candidate.sh calls this once per platform, right after Syft):
#   uv run scripts/scan_identity.py CONTEXT RECIPE SBOM SYFT_JSON
# trim_sbom.py calls apply_apko() on every SBOM before the gate scans and attests it.
"""Declare the main software of an image to the scanners, or fail closed.

Melange stamps a .note.package into every binary it builds, so Syft reports the
main software as a renamed apk that no vulnerability feed knows. A declared
`scan-identity` in metadata.yaml adds one SPDX package per entry, versioned from
the recipe, so Grype matches the software itself. Without a declared identity the
image must expose a versioned main component natively, or sit on the shrink-only
allowlist in scripts/scan_identity_allowlist.d/, one file per image.

A pure APKO image is scanned from its real Wolfi package database, which Grype
matches through the Wolfi secdb and through CPEs Syft guesses from the apk name.
When that guess names the wrong vendor or product, the image may opt in with
`scan-identity` plus `scan-package`, the Wolfi package that ships the software.
The identity is then versioned from that package's version in the SBOM, which
is the locked version, so the declaration cannot drift from what ships.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Final

import gen_matrix

ROOT: Final = Path(__file__).resolve().parents[1]
ALLOWLIST: Final = ROOT / "scripts/scan_identity_allowlist.d"
VERSION: Final = re.compile(r"[0-9][0-9A-Za-z._-]*")
UNVERSIONED: Final = {"", "UNKNOWN", "(devel)"}
FOLLOW_UPS: Final = frozenset({"identity", "go-version", "unverified", "no-feed"})
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
        # CPE 2.3 escapes '/' in a component; a purl percent-encodes it in the name.
        cpe_product, purl_name = product.replace("/", "\\/"), product.replace("/", "%2F")
        refs = [
            ("SECURITY", "cpe23Type", f"cpe:2.3:a:{vendor}:{cpe_product}:{version}:*:*:*:*:*:*:*"),
            ("PACKAGE-MANAGER", "purl", f"pkg:generic/{purl_name}@{version}"),
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


def entry_name(context: str) -> str:
    """The allowlist file name of an image context: '/' written as '__'. Never decoded, see read_allowlist."""
    return context.replace("/", "__")


def read_allowlist(directory: Path) -> dict[str, str]:
    """Entry file name -> follow-up, one file per image named by entry_name(context).

    Names are looked up by encoding the queried context, never decoded: '__' is not reversible
    when a path segment starts or ends with '_'. The first line of a file is the follow-up kind;
    the rest is the reason and must not be empty.
    """
    entries: dict[str, str] = {}
    for path in sorted(directory.iterdir()):
        if path.name == "README.md":
            continue
        if not path.is_file():
            raise CoverageError(f"{path}: expected a file named after the image context, '/' written as '__'")
        kind, _, reason = path.read_text(encoding="utf-8").partition("\n")
        if kind not in FOLLOW_UPS or not reason.strip():
            raise CoverageError(f"{path}: expected '{'|'.join(sorted(FOLLOW_UPS))}' on the first line, then the reason")
        entries[path.name] = kind
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
        stale = "; stale allowlist entry, delete it" if entry_name(key) in listed else ""
        return f"{key}: scanner sees its main software natively: {', '.join(components)}{stale}"
    if entry_name(key) in listed:
        return f"{key}: ALLOWLISTED, main software not scanned (follow-up: {listed[entry_name(key)]})"
    raise CoverageError(
        f"{key}: the scanner cannot see this image's main software. Syft reports the melange package under a "
        "renamed apk and finds no versioned Go main module or Rust crate in files that package owns, so "
        "'0 fixable' would prove nothing. Declare scan-identity in metadata.yaml (see CONTRIBUTING.md) or, "
        "for Go, stamp the main module version."
    )


def built_lock(sbom_path: Path) -> Path:
    """The lock a wolfi build used: build_candidate.sh writes dist/BUILD/apko.lock.json and dist/BUILD/sbom/*."""
    return sbom_path.parent.parent / "apko.lock.json"


def apk_versions(sbom: dict, package: str) -> set[str]:
    """Versions of the installed apk named package in an SPDX SBOM."""
    return {
        str(item.get("versionInfo", ""))
        for item in sbom.get("packages", [])
        if item.get("name") == package
        and any(ref.get("referenceLocator", "").startswith("pkg:apk/") for ref in item.get("externalRefs", []))
    }


def built_variants(directory: Path, metadata: gen_matrix.Metadata) -> list[tuple[str, Path]]:
    """(build name, committed lock) per flavor, chosen as scripts/build_candidate.sh and gen_matrix.py choose them."""
    variants = []
    for flavor in metadata.flavors:
        lock = directory / "apko.lock.json"
        if flavor != "plain" and (directory / f"{flavor}.apko.yaml").is_file():
            lock = directory / f"{flavor}.apko.lock.json"
        variants.append((metadata.name if flavor == "plain" else f"{metadata.name}-{flavor}", lock))
    return variants


def apko_declaration(lock: Path, directories: list[Path]) -> tuple[Path, gen_matrix.Metadata] | None:
    """The opted-in pure APKO image built into dist/BUILD/ from a committed lock byte-identical to BUILD's lock.

    Every pure APKO variant with that build name and lock is a candidate, declared or not, so an image that
    did not opt in never receives another image's identity: candidates that disagree fail closed.
    """
    build, built = lock.parent.name, lock.read_bytes()
    found = []
    for directory in directories:
        if not gen_matrix.is_pure_apko(directory):
            continue
        metadata = gen_matrix.parse_metadata(directory / "metadata.yaml")
        if any(
            name == build and candidate.is_file() and candidate.read_bytes() == built
            for name, candidate in built_variants(directory, metadata)
        ):
            found.append((directory, metadata))
    if len({(metadata.scan_identity, metadata.scan_package) for _, metadata in found}) > 1:
        names = ", ".join(relative_context(directory) for directory, _ in found)
        raise CoverageError(f"{lock}: built as {build} by {names}, which do not declare the same scan identity")
    return found[0] if found and found[0][1].scan_package else None


def apply_apko(sbom_path: Path, directories: list[Path] | None = None) -> str | None:
    """Inject the declared identity of an opted-in pure APKO image; None for every other SBOM, left untouched."""
    lock = built_lock(sbom_path)
    if not lock.is_file():
        return None
    declaration = apko_declaration(lock, gen_matrix.image_directories() if directories is None else directories)
    if declaration is None:
        return None
    directory, metadata = declaration
    key, package, identities = relative_context(directory), metadata.scan_package, metadata.scan_identity
    sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
    installed = apk_versions(sbom, package)
    if len(installed) != 1:
        raise CoverageError(f"{key}: the SBOM lists scan-package {package} at {sorted(installed)}, expected one version")
    apk = installed.pop()
    if apk not in gen_matrix.locked_versions(lock, package).values():
        raise CoverageError(f"{key}: the SBOM lists {package} {apk}, which {lock} does not lock")
    version = gen_matrix.apk_upstream_version(apk)
    if version is None:
        raise CoverageError(f"{key}: {package} {apk} has no upstream version to scan (see gen_matrix.APK_UPSTREAM_VERSION)")
    status = f"{key}: scanning declared identity {', '.join(identities)} at {version} ({package} {apk})"
    if not declared_missing(sbom, identities, version):
        return status
    inject(sbom, identities, version, f"{key}/metadata.yaml")
    sbom_path.write_text(json.dumps(sbom, indent=2) + "\n", encoding="utf-8")
    if missing := declared_missing(json.loads(sbom_path.read_text(encoding="utf-8")), identities, version):
        raise CoverageError(f"{key}: declared scan-identity missing from the SBOM: {', '.join(missing)}")
    return status


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
