#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/check_catalog_freshness.py catalog.json
#
# Fails when a published catalog record is older than the last main commit that
# changed its build inputs. A record sourceCommit is the commit its image was last
# built from, so a record whose inputs changed after it was stranded: its push run
# was replaced or cancelled and the top-level catalog source advanced anyway.
# Selection reuses scripts/gen_matrix.py, so the inputs are exactly what a build uses.
from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import gen_matrix


def stale_records(catalog: Path) -> list[tuple[str, str, str]]:
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
        reachable = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, "HEAD"], cwd=gen_matrix.ROOT, check=False, capture_output=True
        )
        if reachable.returncode != 0:
            raise SystemExit(f"{catalog}: sourceCommit {commit} is not an ancestor of HEAD")
        changed = {(entry["name"], entry["tag_version"]) for entry in gen_matrix.generate(commit)["include"]}
        stale.extend((name, version, commit) for name, version in sorted(records & changed & enabled))
    return stale


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_catalog_freshness.py CATALOG")
    stale = stale_records(Path(sys.argv[1]))
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
