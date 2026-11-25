#!/usr/bin/env python3
"""Every recipe `npm install` installs from a lockfile, not a fresh resolution.

`npm install` against an upstream package.json without a lockfile re-resolves
every version range on every build: two builds of the same recipe can ship
different dependency versions, and a compromised or newly vulnerable transitive
release slips in without any recipe change. `npm ci` never resolves; it installs
exactly the lockfile. So a recipe must either use `npm ci`, or put a lockfile
(`package-lock.json` or `npm-shrinkwrap.json`) in place before `npm install`
in the same `runs:` block, with a `cp`, `install`, `mv`, `ln`, `test` or `[`
command naming it. A mention elsewhere (a comment, `rm`, `echo`) proves nothing.

This test scans every melange recipe of each image (flavor recipes included)
with comments stripped, finds every project-tree `npm install`, and requires
that proof earlier in the same block. Tooling installs (`npm install --global
<pkg>@<version>`) pin their own package and install no project tree, so they
are out of scope. Installs that disable the lockfile always fail.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import gen_matrix

ROOT = Path(__file__).resolve().parents[1]
LOCKFILES = ("package-lock.json", "npm-shrinkwrap.json")
# A project-tree install: `npm [opts] install`/`npm [opts] i`. Comments are stripped first.
NPM_INSTALL = re.compile(
    r"(?<![\w-])npm(?:\s+-{1,2}[\w-]+(?:[=\s][^-\s][^\s;&|)]*)?)*\s+(?:install|i)(?=[\s)&;|]|$)"
    r"(?P<args>[^\n;&|)]*)"
)
GLOBAL = re.compile(r"(?<![\w-])(?:--global|-g)(?![\w=-])")
NO_LOCK = re.compile(r"--no-package-lock|--package-lock=false")
# A lockfile only proves a pinned resolution when a command puts it in place or asserts it exists.
PROOF = re.compile(r"(?m)^\s*(?:\(?\s*cd\s+\S+\s*&&\s*)?(?:cp|install|mv|ln|test|\[)\s[^\n]*(?:%s)" % "|".join(map(re.escape, LOCKFILES)))


def uncommented(contents: str) -> str:
    """The recipe with comment lines and trailing ` # ...` comments removed."""
    return "\n".join(
        "" if line.strip().startswith("#") else re.sub(r"\s+#.*$", "", line)
        for line in contents.splitlines()
    )


def violations(recipe: Path) -> list[str]:
    contents = uncommented(recipe.read_text(encoding="utf-8"))
    failures = []
    for match in NPM_INSTALL.finditer(contents):
        command = match.group(0)
        if GLOBAL.search(command):
            continue
        if NO_LOCK.search(command):
            failures.append(f"{recipe}: npm install disables the lockfile")
            continue
        # Only a proof in the same `runs:` block, before the install, counts.
        block = contents[max(contents.rfind("runs:", 0, match.start()), 0) : match.start()]
        if not PROOF.search(block):
            failures.append(f"{recipe}: npm install without a lockfile put in place before it")
    return failures


def check() -> None:
    # The lint itself must catch an unlocked install and accept the reproducible forms.
    from tempfile import TemporaryDirectory

    def count(body: str) -> int:
        with TemporaryDirectory() as directory:
            recipe = Path(directory) / "melange.yaml"
            recipe.write_text(f"pipeline:\n  - runs: |\n{body}", encoding="utf-8")
            return len(violations(recipe))

    assert count("      npm install --omit=dev\n") == 1
    assert count("      (cd ui && npm install)\n") == 1
    assert count("      cp npm-shrinkwrap.json package-lock.json\n      npm install --omit=dev\n") == 0
    assert count("      npm ci --omit=dev\n") == 0
    assert count('      npm install --global "npm@12.0.0" --ignore-scripts\n') == 0
    # A lockfile named only after the install proves nothing.
    assert count("      npm install\n      cp package-lock.json /out/\n") == 1
    # A comment, inline or whole-line, naming a lockfile must not satisfy the check.
    assert count("      # upstream ships no package-lock.json\n      npm install\n") == 1
    assert count("      cd ui  # no package-lock.json upstream\n      npm install\n") == 1
    assert count("      rm -f package-lock.json\n      npm install\n") == 1
    assert count("      cp package-lock.json ui/\n      npm install\n") == 0
    assert count("      cp package-lock.json ui/\n      npm install --no-package-lock\n") == 1
    assert count("      npm --prefix ui install\n") == 1
    assert count("      npm install --global-style\n") == 1
    # A proof in an earlier block does not cover a later one.
    assert count("      cp package-lock.json ui/\n  - runs: npm install\n") == 1


def main() -> None:
    check()
    failures = [
        failure
        for directory in gen_matrix.image_directories()
        for recipe in sorted(directory.glob("*melange.yaml"))
        for failure in violations(recipe)
    ]
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(f"{len(failures)} recipe(s) run npm install without a lockfile")
    print("passed scripts/test_npm_lockfile.py")


if __name__ == "__main__":
    main()
