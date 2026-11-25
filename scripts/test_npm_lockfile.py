#!/usr/bin/env python3
"""Every recipe `npm install` installs from a lockfile, not a fresh resolution.

`npm install` against an upstream package.json without a lockfile re-resolves
every version range on every build: two builds of the same recipe can ship
different dependency versions, and a compromised or newly vulnerable transitive
release slips in without any recipe change. `npm ci` never resolves; it installs
exactly the lockfile. So a recipe must either use `npm ci`, or name a lockfile
(`package-lock.json` or `npm-shrinkwrap.json`) before the `npm install` command:
fetched with the upstream source, copied into place, or generated. Naming it
proves the recipe author pinned the resolution; the build then fails on its own
if the file is absent, because `npm install` has no lockfile to resolve from.

This test walks each recipe's `runs:` blocks, finds every project-tree
`npm install`, and requires a lockfile name earlier in the recipe. Tooling
installs (`npm install --global <pkg>@<version>`) pin their own package and
install no project tree, so they are out of scope. A lockfile generated inside
the same block after the install does not count: the check is order-sensitive.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import gen_matrix

ROOT = Path(__file__).resolve().parents[1]
LOCKFILES = ("package-lock.json", "npm-shrinkwrap.json")
# A project-tree install: `npm install`/`npm i` with no --global flag. Comments are stripped first.
NPM_INSTALL = re.compile(r"(?<![\w-])npm\s+(?:install|i)(?=[\s)&;|]|$)(?P<args>[^\n;&|)]*)")
RUNS_BLOCK = re.compile(r"(?m)^(?P<indent>\s*)-?\s*runs:\s*\|\s*$")


def recipe_blocks(contents: str) -> list[str]:
    """The bodies of every `runs: |` block in a melange recipe."""
    lines = contents.splitlines(keepends=True)
    blocks, current, indent = [], [], None
    for line in lines:
        match = RUNS_BLOCK.match(line)
        if match:
            if current:
                blocks.append("".join(current))
            current, indent = [], len(match.group("indent"))
            continue
        if indent is None:
            continue
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            if current:
                blocks.append("".join(current))
            current, indent = [], None
            continue
        current.append(line)
    if current:
        blocks.append("".join(current))
    return blocks


def uncommented(contents: str) -> str:
    """The recipe with comment-only lines blanked, so string positions stay aligned."""
    return "\n".join("" if line.strip().startswith("#") else line for line in contents.splitlines())


def installs(block: str):
    """Yield (position in block, args) for every project-tree `npm install`."""
    for match in NPM_INSTALL.finditer(block):
        args = match.group("args")
        if "--global" in args or re.search(r"(?<![\w-])-g(?![\w-])", args):
            continue
        yield match.start(), args


def violations(recipe: Path) -> list[str]:
    contents = uncommented(recipe.read_text(encoding="utf-8"))
    failures = []
    for block in recipe_blocks(contents):
        start = contents.index(block)
        for position, _ in installs(block):
            before = contents[: start + position]
            if any(name in before for name in LOCKFILES):
                continue
            failures.append(f"{recipe}: npm install without a lockfile named before it")
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
    # A comment naming a lockfile must not satisfy the check.
    assert count("      # upstream ships no package-lock.json\n      npm install\n") == 1
    # Two installs in one block, the second unlocked by a cd into a fresh tree.
    assert count("      cp package-lock.json ui/\n      npm install\n") == 0


def main() -> None:
    check()
    failures = [
        failure
        for directory in gen_matrix.image_directories()
        if (directory / "melange.yaml").is_file()
        for failure in violations(directory / "melange.yaml")
    ]
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(f"{len(failures)} recipe(s) run npm install without a lockfile")
    print("passed scripts/test_npm_lockfile.py")


if __name__ == "__main__":
    main()
