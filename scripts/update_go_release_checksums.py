#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from http.client import HTTPException
from pathlib import Path

VERSION = re.compile(r'^  version: "(?P<version>1\.\d+\.\d+)"$', re.MULTILINE)
CHECKSUM = re.compile(
    r"(?P<prefix>          archive=go\$\{\{package\.version\}\}\.linux-"
    r"(?P<arch>amd64|arm64)\.tar\.gz\n          sha256=)(?P<checksum>[a-f0-9]{64})"
)
SHA256 = re.compile(r"[a-f0-9]{64}")


class GoChecksumError(ValueError):
    pass

def update(recipe: Path, opener) -> dict[str, str]:
    source = recipe.read_text(encoding="utf-8")
    version_match = VERSION.search(source)
    if version_match is None:
        raise GoChecksumError(f"missing Go package version in {recipe}")
    version = version_match.group("version")
    with opener("https://go.dev/dl/?mode=json&include=all", timeout=30) as response:
        releases = json.load(response)
    if not isinstance(releases, list):
        raise GoChecksumError("upstream Go release feed is not a list")
    release = next(
        (item for item in releases if isinstance(item, dict) and item.get("version") == f"go{version}"),
        None,
    )
    if release is None or release.get("stable") is not True:
        raise GoChecksumError(f"stable Go {version} is not present in the upstream release feed")
    files = release.get("files")
    if not isinstance(files, list):
        raise GoChecksumError(f"Go {version} release files are malformed")
    digests: dict[str, str] = {}
    for item in files:
        if not isinstance(item, dict) or item.get("os") != "linux":
            continue
        arch = item.get("arch")
        if arch not in {"amd64", "arm64"}:
            continue
        expected_filename = f"go{version}.linux-{arch}.tar.gz"
        checksum = item.get("sha256")
        if item.get("filename") != expected_filename or not isinstance(checksum, str) or SHA256.fullmatch(checksum) is None:
            raise GoChecksumError(f"Go {version} has an invalid Linux {arch} archive entry")
        digests[arch] = checksum
    if set(digests) != {"amd64", "arm64"}:
        raise GoChecksumError(f"Go {version} is missing Linux amd64 or arm64 archives")
    seen: set[str] = set()

    def replace(match: re.Match[str]) -> str:
        arch = match.group("arch")
        seen.add(arch)
        return match.group("prefix") + digests[arch]

    updated = CHECKSUM.sub(replace, source)
    if seen != {"amd64", "arm64"}:
        raise GoChecksumError(f"missing Go archive checksum slots in {recipe}")
    recipe.write_text(updated, encoding="utf-8")
    return digests


def main() -> int:
    parser = argparse.ArgumentParser(description="Update pinned Go release archive checksums")
    parser.add_argument("recipe", type=Path)
    args = parser.parse_args()
    try:
        digests = update(args.recipe, urllib.request.urlopen)
    except (GoChecksumError, HTTPException, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(digests, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
