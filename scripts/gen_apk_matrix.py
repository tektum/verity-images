#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/gen_apk_matrix.py --all
#   uv run scripts/gen_apk_matrix.py --changed BASE_SHA HEAD_SHA
#   uv run scripts/gen_apk_matrix.py --unpublished packages/repository-state.json

import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Final, TypedDict

ROOT: Final = Path(__file__).resolve().parents[1]
ARCHITECTURES: Final = ("aarch64", "x86_64")
PACKAGE_PATTERN: Final = re.compile(r"[a-z0-9][a-z0-9+._-]*")
RECIPE_FIELD: Final = re.compile(r"(name|version|epoch):\s*(.*?)\s*(?:#.*)?")
SHARED_PATHS: Final = frozenset(
    {
        "scripts/build_apk_package.sh",
        "scripts/gen_apk_matrix.py",
    }
)


class MatrixEntry(TypedDict):
    package: str
    recipe: str
    architecture: str


class Matrix(TypedDict):
    include: list[MatrixEntry]


class PackageDiscoveryError(ValueError):
    ...


def changed_paths(base_ref: str, head_ref: str) -> set[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "-z", f"{base_ref}...{head_ref}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return {os.fsdecode(path) for path in result.stdout.split(b"\0") if path}


def _source_recipe(recipe: Path) -> str:
    try:
        return recipe.resolve(strict=True).relative_to(ROOT.resolve()).as_posix()
    except (OSError, ValueError, RuntimeError) as error:
        raise PackageDiscoveryError(f"invalid package recipe path: {recipe}") from error


def package_recipes() -> dict[str, str]:
    recipes: dict[str, str] = {}
    for recipe in sorted((ROOT / "packages").glob("*/melange.yaml")):
        package = recipe.parent.name
        if recipe.is_file() or recipe.is_symlink():
            _source_recipe(recipe)
        if recipe.is_file() and PACKAGE_PATTERN.fullmatch(package) is None:
            raise PackageDiscoveryError(f"invalid package directory: {package}")
        if recipe.is_file():
            recipes[package] = recipe.relative_to(ROOT).as_posix()
    return recipes


def generate(base_ref: str | None, head_ref: str | None) -> Matrix:
    recipes = package_recipes()
    selected = set(recipes)
    if base_ref is not None and head_ref is not None:
        changed = changed_paths(base_ref, head_ref)
        if not changed & SHARED_PATHS:
            selected = {
                parts[1]
                for path in changed
                if len(parts := PurePosixPath(path).parts) > 2
                and parts[0] == "packages"
                and parts[1] in recipes
            }
            pipeline_changes = {path for path in changed if path.startswith("pipelines/")}
            for package, recipe in recipes.items():
                source = _source_recipe(ROOT / recipe)
                if source in changed:
                    selected.add(package)
                elif pipeline_changes:
                    pipelines = re.findall(r"(?m)^\s*-\s+uses:\s*(\S+)", (ROOT / source).read_text(encoding="utf-8"))
                    if any(f"pipelines/{pipeline}.yaml" in pipeline_changes for pipeline in pipelines):
                        selected.add(package)
    return _matrix(recipes, selected)


def _matrix(recipes: dict[str, str], selected: set[str]) -> Matrix:
    return {
        "include": [
            {
                "package": package,
                "recipe": recipes[package],
                "architecture": architecture,
            }
            for package in sorted(selected)
            for architecture in ARCHITECTURES
        ]
    }


def recipe_identity(recipe: str) -> tuple[str, str]:
    """Return the package name and APK version-release declared by a recipe's top-level package block."""
    fields: dict[str, str] = {}
    in_package = False
    for line in (ROOT / recipe).read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            in_package = line.rstrip() == "package:"
            continue
        if in_package and line.startswith("  ") and not line[2].isspace():
            if (match := RECIPE_FIELD.fullmatch(line[2:])) is not None:
                fields.setdefault(match[1], match[2].strip("\"'"))
    name = fields.get("name", "")
    version = fields.get("version", "")
    epoch = fields.get("epoch", "0")
    if not name or not version or not epoch.isdigit():
        raise PackageDiscoveryError(f"recipe lacks a literal package name, version, or epoch: {recipe}")
    return name, f"{version}-r{int(epoch)}"


def unpublished(state: Path) -> Matrix:
    """Select every package whose recipe version-release is absent from the pinned published repository state."""
    recipes = package_recipes()
    packages = json.loads(state.read_text(encoding="utf-8"))["packages"]
    published = {(entry["name"], entry["version"], entry["architecture"]) for entry in packages}
    selected: set[str] = set()
    for package, recipe in recipes.items():
        name, version = recipe_identity(recipe)
        if name != package:
            raise PackageDiscoveryError(f"recipe package name {name} does not match directory {package}")
        if any((name, version, architecture) not in published for architecture in ARCHITECTURES):
            selected.add(package)
    return _matrix(recipes, selected)


def main() -> None:
    arguments = sys.argv[1:]
    if arguments == ["--all"]:
        print(json.dumps(generate(None, None), separators=(",", ":"), sort_keys=True))
        return
    if len(arguments) == 3 and arguments[0] == "--changed" and arguments[1] and arguments[2]:
        print(json.dumps(generate(arguments[1], arguments[2]), separators=(",", ":"), sort_keys=True))
        return
    if len(arguments) == 2 and arguments[0] == "--unpublished" and arguments[1]:
        print(json.dumps(unpublished(Path(arguments[1])), separators=(",", ":"), sort_keys=True))
        return
    raise SystemExit("usage: gen_apk_matrix.py --all | --changed BASE_SHA HEAD_SHA | --unpublished STATE_JSON")


if __name__ == "__main__":
    main()
