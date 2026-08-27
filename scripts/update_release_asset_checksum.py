#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

ALLOWED_ASSETS = {
    "images/traefik/melange.yaml": (
        "traefik/traefik",
        "traefik-v{version}.src.tar.gz",
    ),
}
VERSION = re.compile(r'^  version: "(?P<version>[^"]+)"$', re.MULTILINE)
FETCH = re.compile(
    r"(?P<prefix>      uri: >-\n        )(?P<url>\S+)\n"
    r"(?P<checksum_prefix>      expected-sha256: )(?P<checksum>[a-f0-9]{64})"
)


class ChecksumUpdateError(ValueError):
    pass


def canonical_asset(recipe: Path, root: Path) -> tuple[str, str]:
    try:
        relative = recipe.resolve().relative_to(root.resolve()).as_posix()
        repository, filename_template = ALLOWED_ASSETS[relative]
    except (ValueError, KeyError) as error:
        raise ChecksumUpdateError(f"unsupported recipe: {recipe}") from error
    return repository, filename_template


def update(recipe: Path, root: Path, opener=urllib.request.urlopen) -> str:
    repository, filename_template = canonical_asset(recipe, root)
    source = recipe.read_text(encoding="utf-8")
    version_match = VERSION.search(source)
    fetch_match = FETCH.search(source)
    if version_match is None or fetch_match is None:
        raise ChecksumUpdateError(f"missing package version or release asset checksum in {recipe}")

    version = version_match.group("version")
    filename = filename_template.format(version=version)
    expected_url = f"https://github.com/{repository}/releases/download/v{version}/{filename}"
    declared_url = fetch_match.group("url").replace("${{package.version}}", version)
    parsed = urlparse(declared_url)
    if (
        declared_url != expected_url
        or parsed.scheme != "https"
        or parsed.hostname != "github.com"
    ):
        raise ChecksumUpdateError(f"unsupported release asset URL: {fetch_match.group('url')}")

    digest = hashlib.sha256()
    with opener(expected_url) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    checksum = digest.hexdigest()
    updated = source[: fetch_match.start("checksum")] + checksum + source[fetch_match.end("checksum") :]
    recipe.write_text(updated, encoding="utf-8")
    return checksum


def main() -> int:
    parser = argparse.ArgumentParser(description="Update an allowlisted GitHub release asset checksum")
    parser.add_argument("recipe", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        checksum = update(args.recipe, root)
    except (ChecksumUpdateError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
