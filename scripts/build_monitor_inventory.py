#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_monitor_inventory.py CATALOG MATRIX OUTPUT

from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"{path}: {error}") from error


def flavor_matches(version: str, candidate: dict[str, object], candidates: list[dict[str, object]]) -> bool:
    flavor = candidate.get("flavor")
    if not isinstance(flavor, str) or not flavor:
        raise SystemExit("monitor matrix entry has an invalid flavor")
    if flavor != "plain":
        return version.endswith(f"-{flavor}")
    non_plain = {
        str(entry["flavor"])
        for entry in candidates
        if isinstance(entry.get("flavor"), str) and entry["flavor"] != "plain"
    }
    return not any(version.endswith(f"-{other}") for other in non_plain)


def monitor_inventory(catalog: object, matrix: object) -> dict[str, list[dict[str, str]]]:
    if not isinstance(catalog, dict) or not isinstance(catalog.get("images"), list):
        raise SystemExit("catalog images must be an array")
    if not isinstance(matrix, dict) or not isinstance(matrix.get("include"), list):
        raise SystemExit("monitor matrix include must be an array")
    entries = matrix["include"]
    if not all(isinstance(entry, dict) for entry in entries):
        raise SystemExit("monitor matrix entry must be an object")

    inventory: list[dict[str, str]] = []
    identities: set[tuple[str, str]] = set()
    for image in catalog["images"]:
        if not isinstance(image, dict):
            raise SystemExit("catalog image must be an object")
        name = image.get("name")
        version = image.get("version")
        track = image.get("track")
        if not all(isinstance(value, str) and value for value in (name, version, track)):
            raise SystemExit("catalog image must have non-empty name, version, and track")
        identity = str(name), str(version)
        if identity in identities:
            raise SystemExit(f"duplicate catalog image {name} {version}")
        identities.add(identity)

        named = [entry for entry in entries if entry.get("name") == name and entry.get("track") == track]
        exact = [entry for entry in named if entry.get("tag_version") == version]
        candidates = exact or [
            entry for entry in named if flavor_matches(str(version), entry, named)
        ]
        if len(candidates) != 1:
            raise SystemExit(
                f"catalog image {name} {version} maps to {len(candidates)} current contexts"
            )
        context = candidates[0].get("context")
        if not isinstance(context, str) or not context:
            raise SystemExit(f"catalog image {name} {version} has no current context")
        inventory.append({"name": str(name), "tag_version": str(version), "context": context})
    return {"include": inventory}


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: build_monitor_inventory.py CATALOG MATRIX OUTPUT")
    catalog_path, matrix_path, output_path = map(Path, sys.argv[1:])
    result = monitor_inventory(load(catalog_path), load(matrix_path))
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
