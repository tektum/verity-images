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


def target_selections(targets: object) -> dict[str, set[tuple[str, str, str]]]:
    """Validate monitor-selected lock inputs and index them by image context."""
    if not isinstance(targets, list) or not targets:
        raise LockDiscoveryError("refresh targets must be a non-empty array")
    selected: dict[str, set[tuple[str, str, str]]] = {}
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"context", "locks"}:
            raise LockDiscoveryError("refresh target must contain context and locks")
        context = target["context"]
        locks = target["locks"]
        if not isinstance(context, str) or not context or context in selected:
            raise LockDiscoveryError("refresh target contexts must be non-empty and unique")
        if not isinstance(locks, list) or not locks:
            raise LockDiscoveryError(f"{context}: refresh target locks must be a non-empty array")
        identities: set[tuple[str, str, str]] = set()
        for lock in locks:
            if not isinstance(lock, dict) or set(lock) != {"flavor", "config", "lockfile"}:
                raise LockDiscoveryError(f"{context}: invalid refresh lock selection")
            identity = (lock["flavor"], lock["config"], lock["lockfile"])
            if not all(isinstance(value, str) and value for value in identity) or identity in identities:
                raise LockDiscoveryError(f"{context}: invalid refresh lock selection")
            identities.add(identity)
        selected[context] = identities
    return selected


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


def generate(
    contexts: list[str] | None = None,
    targets: object | None = None,
) -> Targets:
    if contexts is not None and targets is not None:
        raise LockDiscoveryError("refresh contexts and targets are mutually exclusive")
    if contexts is not None and (not contexts or len(contexts) != len(set(contexts))):
        raise LockDiscoveryError("refresh contexts must be a non-empty unique array")
    selections = target_selections(targets) if targets is not None else None
    requested = set(contexts or (selections or {}))
    images: list[ImageTarget] = []
    for directory in gen_matrix.image_directories():
        context = directory.relative_to(ROOT).as_posix()
        if (contexts is not None or selections is not None) and context not in requested:
            continue
        locks = lock_targets(directory)
        if selections is not None and context in selections:
            available = {
                (lock["flavor"], lock["config"], lock["lockfile"]): lock for lock in locks
            }
            missing = selections[context] - available.keys()
            if missing:
                raise LockDiscoveryError(f"{context}: selected lock does not match build inputs")
            locks = [available[identity] for identity in sorted(selections[context])]
        if not locks:
            continue
        images.append({"context": context, "branch": branch_name(context), "locks": locks})
    branches = {entry["branch"] for entry in images}
    if len(branches) != len(images):
        raise LockDiscoveryError("image contexts collide on one refresh branch name")
    found = {entry["context"] for entry in images}
    if (contexts is not None or selections is not None) and found != requested:
        missing = sorted(requested - found)
        raise LockDiscoveryError(
            f"{', '.join(missing)}: not an enabled pure APKO image context"
        )
    return {"images": images}


def main() -> None:
    arguments = sys.argv[1:]
    match arguments:
        case ["--all"]:
            targets = generate()
        case ["--contexts", raw_contexts]:
            try:
                contexts = json.loads(raw_contexts)
            except json.JSONDecodeError as error:
                raise SystemExit(f"contexts must be JSON: {error}") from error
            if not isinstance(contexts, list) or not all(isinstance(context, str) for context in contexts):
                raise SystemExit("contexts must be a JSON array of strings")
            targets = generate(contexts=contexts)
        case ["--targets", raw_targets]:
            try:
                selected = json.loads(raw_targets)
            except json.JSONDecodeError as error:
                raise SystemExit(f"targets must be JSON: {error}") from error
            targets = generate(targets=selected)
        case _:
            raise SystemExit(
                "usage: gen_apko_lock_targets.py --all | --contexts JSON_ARRAY | --targets JSON_ARRAY"
            )
    print(json.dumps(targets, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
