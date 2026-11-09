#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/check_catalog_freshness.py catalog.json [BUILT_COMMIT]
#
# Fails when a published catalog record is older than the last main commit that
# changed its build inputs. A record sourceCommit is the commit its image was last
# built from, so a record whose inputs changed after it was stranded: its push run
# was replaced or cancelled and the top-level catalog source advanced anyway.
# Selection reuses scripts/gen_matrix.py, so the inputs are exactly what a build uses.
# Input changes are only counted up to BUILT_COMMIT (default HEAD), the newest commit
# known to be fully built, so a merge still being built is not reported as stranded.
from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from unittest.mock import patch

import gen_matrix


def changed_until(built: str):
    def changed(base_ref: str) -> set[str]:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"{base_ref}...{built}"],
            cwd=gen_matrix.ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return set(result.stdout.splitlines())

    return changed


def stale_records(catalog: Path, built: str = "HEAD") -> list[tuple[str, str, str]]:
    document = json.loads(catalog.read_text(encoding="utf-8"))
    images = document.get("images")
    if not isinstance(images, list):
        raise SystemExit(f"{catalog}: catalog images must be an array")
    by_commit: dict[str, set[tuple[str, str]]] = defaultdict(set)
    for image in images:
        commit = image.get("sourceCommit") if isinstance(image, dict) else None
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise SystemExit(f"{catalog}: record {image!r} has no valid sourceCommit")
        by_commit[commit].add((image["name"], image["version"]))
    enabled = {(entry["name"], entry["tag_version"]) for entry in gen_matrix.generate(None)["include"]}
    stale: list[tuple[str, str, str]] = []
    for commit, records in sorted(by_commit.items()):
        known = subprocess.run(
            ["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=gen_matrix.ROOT, check=False, capture_output=True
        )
        if known.returncode != 0:
            raise SystemExit(f"{catalog}: sourceCommit {commit} is not a commit in this repository")
        reachable = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, built],
            cwd=gen_matrix.ROOT,
            check=False,
            capture_output=True,
        )
        if reachable.returncode != 0:
            continue  # newer than the fully built point: nothing to compare yet
        with patch.object(gen_matrix, "changed_paths", changed_until(built)):
            changed = {(entry["name"], entry["tag_version"]) for entry in gen_matrix.generate(commit)["include"]}
        stale.extend((name, version, commit) for name, version in sorted(records & changed & enabled))
    return stale


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: check_catalog_freshness.py CATALOG [BUILT_COMMIT]")
    stale = stale_records(Path(sys.argv[1]), *sys.argv[2:])
    for name, version, commit in stale:
        print(
            f"::error title=Stale catalog record::{name}@{version} was last built at {commit}, "
            "but its inputs changed on main since."
        )
    if stale:
        raise SystemExit(f"{len(stale)} stale catalog record(s); rebuild with -f image=NAME@VERSION dispatches")
    print("Every catalog record is at least as new as its last input change.")


if __name__ == "__main__":
    main()
