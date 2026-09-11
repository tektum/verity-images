#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/select_monitor_shards.py PREVIOUS_CATALOG CURRENT_CATALOG

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Final

SHARDS: Final = 8


def shard_for(name: str, version: str) -> int:
    stream = hashlib.sha256(f"{name}@{version}".encode()).hexdigest()[:8]
    return int(stream, 16) % SHARDS


def images_by_name(document: object, source: Path) -> dict[str, dict[str, object]]:
    if not isinstance(document, dict) or not isinstance(document.get("images"), list):
        raise SystemExit(f"{source}: catalog images must be an array")
    images: dict[str, dict[str, object]] = {}
    for image in document["images"]:
        if not isinstance(image, dict):
            raise SystemExit(f"{source}: catalog image must be an object")
        name = image.get("name")
        version = image.get("version")
        if not isinstance(name, str) or not name:
            raise SystemExit(f"{source}: catalog image name must be a non-empty string")
        if not isinstance(version, str) or not version:
            raise SystemExit(f"{source}: catalog image {name} has an invalid version")
        if name in images:
            raise SystemExit(f"{source}: duplicate catalog image name {name}")
        images[name] = image
    return images


def changed_shards(previous: object, current: object) -> list[int]:
    previous_images = images_by_name(previous, Path("previous catalog"))
    current_images = images_by_name(current, Path("current catalog"))
    shards: set[int] = set()
    for name in previous_images.keys() | current_images.keys():
        old = previous_images.get(name)
        new = current_images.get(name)
        if old == new:
            continue
        for image in (old, new):
            if image is not None:
                shards.add(shard_for(str(image["name"]), str(image["version"])))
    return sorted(shards)


def load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"{path}: {error}") from error


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: select_monitor_shards.py PREVIOUS_CATALOG CURRENT_CATALOG"
        )
    previous_path, current_path = map(Path, sys.argv[1:])
    print(
        json.dumps(
            changed_shards(load(previous_path), load(current_path)),
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
