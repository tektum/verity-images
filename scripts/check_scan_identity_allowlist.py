#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   BASE_SHA=<base> python3 scripts/check_scan_identity_allowlist.py [BASE]
"""Fail when a change adds a file under scripts/scan_identity_allowlist.d/.

The allowlist may only shrink, and an image-local pull request deletes only its own file,
so no test edit is needed to keep a deleted entry from coming back. The base is the
argument, else $BASE_SHA (the pull request base, the merge group base, or the push
"before" commit, as in build.yaml). Without a usable base the check falls back to the
merge base with origin/main, and when that is absent too it skips with a notice: the
frozen sets in scripts/test_scan_identity.py still bound which entries can exist. A base
that is given but not present in the clone is an error, never a silent pass. An added file
whose first line is `no-feed` is allowed, since adding a no-feed image is a deliberate edit
of FROZEN_NO_FEED; the test bounds it. The change that introduces the directory may add
only the contexts the legacy .txt listed at its base.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
DIRECTORY: Final = "scripts/scan_identity_allowlist.d"
MARKER: Final = f"{DIRECTORY}/README.md"
LEGACY: Final = "scripts/scan_identity_allowlist.txt"
NO_BASE: Final = {"", "0" * 40}


def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)


def added_entries(root: Path, base: str) -> list[str] | None:
    """Files added under the allowlist since the merge base with `base`; None when there is no base to compare."""
    if base in NO_BASE:
        probe = git(root, "merge-base", "origin/main", "HEAD")
        if probe.returncode != 0:
            return None
        base = probe.stdout.strip()
    elif git(root, "cat-file", "-e", f"{base}^{{commit}}").returncode != 0:
        raise SystemExit(f"base {base} is not in this clone; fetch with fetch-depth: 0")
    merge_base = git(root, "merge-base", base, "HEAD")
    if merge_base.returncode != 0:
        raise SystemExit(f"no merge base between {base} and HEAD; fetch with fetch-depth: 0")
    start = merge_base.stdout.strip()
    # Without the directory at the merge base, the pull request that introduces it may add exactly the
    # entries the legacy file listed there. With neither, fail: the marker cannot be deleted to switch this off.
    legacy: set[str] | None = None
    if git(root, "cat-file", "-e", f"{start}:{MARKER}").returncode != 0:
        listing = git(root, "show", f"{start}:{LEGACY}")
        if listing.returncode != 0:
            raise SystemExit(f"neither {MARKER} nor {LEGACY} exists at {start}; restore the allowlist directory")
        legacy = {line.split()[0] for line in listing.stdout.splitlines() if line.strip() and not line.startswith("#")}
    diff = git(root, "diff", "--no-renames", "--diff-filter=A", "--name-only", start, "HEAD", "--", DIRECTORY)
    if diff.returncode != 0:
        raise SystemExit(f"git diff failed: {diff.stderr.strip()}")
    added = []
    for path in diff.stdout.splitlines():
        name = path.removeprefix(f"{DIRECTORY}/")
        if name == "README.md" or (legacy is not None and name.replace("__", "/") in legacy):
            continue
        # A deliberate no-feed addition passes here; the FROZEN_NO_FEED subset in test_scan_identity.py bounds it.
        shown = git(root, "show", f"HEAD:{path}")
        if shown.returncode == 0 and shown.stdout.partition("\n")[0] == "no-feed":
            continue
        added.append(path)
    return added


def main() -> None:
    base = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("BASE_SHA", "")
    added = added_entries(ROOT, base)
    if added is None:
        print("skipped scripts/check_scan_identity_allowlist.py: no base to compare against")
        return
    if added:
        print(
            f"::error title=Scan identity allowlist::the allowlist may only shrink; added: {', '.join(added)}. "
            "Declare scan-identity or stamp the Go main module version instead.",
            file=sys.stderr,
        )
        sys.exit(1)
    print("passed scripts/check_scan_identity_allowlist.py")


if __name__ == "__main__":
    main()
