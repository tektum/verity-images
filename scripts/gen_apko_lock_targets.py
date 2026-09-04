#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/gen_apko_lock_targets.py --all
#   uv run scripts/gen_apko_lock_targets.py --image images/httpd

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Final, TypedDict

import gen_matrix

ROOT: Final = gen_matrix.ROOT
BRANCH_PREFIX: Final = "apko-lock/"
PLACEHOLDER: Final = re.compile(r"@[A-Z][A-Z0-9_]*@")


class LockTarget(TypedDict):
    flavor: str
    config: str
    lockfile: str


class ImageTarget(TypedDict):
    context: str
    branch: str
    locks: list[LockTarget]


class Targets(TypedDict):
    images: list[ImageTarget]


class LockDiscoveryError(ValueError):
    pass


def build_inputs(directory: Path, flavor: str) -> tuple[Path, Path, Path]:
    """Config, lockfile, and recipe exactly as scripts/build_candidate.sh resolves them."""
    config = directory / "apko.yaml"
    lockfile = directory / "apko.lock.json"
    if flavor != "plain" and (flavored := directory / f"{flavor}.apko.yaml").is_file():
        config = flavored
        lockfile = directory / f"{flavor}.apko.lock.json"
        if (wrapper := directory / f"{flavor}-wrapper.apko.yaml").is_file():
            config = wrapper
    recipe = directory / "melange.yaml"
    if (flavored_recipe := directory / f"{flavor}.melange.yaml").is_file():
        recipe = flavored_recipe
    return config, lockfile, recipe


def branch_name(context: str) -> str:
    return f"{BRANCH_PREFIX}{context.replace('/', '-')}"


def lock_targets(directory: Path) -> list[LockTarget]:
    """Committed locks that publication consumes verbatim, so a refresh must regenerate them.

    A variant whose flavor or image recipe exists resolves its lock during the build from an
    ephemerally signed local package, so it has no committed lock to refresh.
    """
    metadata = gen_matrix.parse_metadata(directory / "metadata.yaml")
    relative = directory.relative_to(ROOT).as_posix()
    if metadata.track != "wolfi" or not metadata.enabled:
        return []
    targets: list[LockTarget] = []
    for flavor in metadata.flavors:
        config, lockfile, recipe = build_inputs(directory, flavor)
        if recipe.is_file():
            continue
        if not config.is_file():
            raise LockDiscoveryError(f"{relative}: missing {config.name} for the {flavor} flavor")
        if not lockfile.is_file():
            raise LockDiscoveryError(f"{relative}: missing {lockfile.name} for the {flavor} flavor")
        if PLACEHOLDER.search(config.read_text(encoding="utf-8")):
            raise LockDiscoveryError(
                f"{relative}: {config.name} needs build-time substitution but has no melange recipe"
            )
        targets.append(
            {
                "flavor": flavor,
                "config": config.relative_to(ROOT).as_posix(),
                "lockfile": lockfile.relative_to(ROOT).as_posix(),
            }
        )
    return targets


def generate(image: str | None = None) -> Targets:
    images: list[ImageTarget] = []
    for directory in gen_matrix.image_directories():
        context = directory.relative_to(ROOT).as_posix()
        if image is not None and context != image:
            continue
        locks = lock_targets(directory)
        if not locks:
            continue
        images.append({"context": context, "branch": branch_name(context), "locks": locks})
    branches = {entry["branch"] for entry in images}
    if len(branches) != len(images):
        raise LockDiscoveryError("image contexts collide on one refresh branch name")
    if image is not None and not images:
        raise LockDiscoveryError(f"{image}: not an enabled pure APKO image context")
    return {"images": images}


def main() -> None:
    arguments = sys.argv[1:]
    match arguments:
        case ["--all"]:
            targets = generate()
        case ["--image", image] if image:
            targets = generate(image)
        case _:
            raise SystemExit("usage: gen_apko_lock_targets.py --all | --image CONTEXT")
    print(json.dumps(targets, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
