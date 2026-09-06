#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/gen_apk_matrix.py --all
#   uv run scripts/gen_apk_matrix.py --changed BASE_SHA HEAD_SHA

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


def package_recipes() -> dict[str, str]:
    recipes: dict[str, str] = {}
    for recipe in sorted((ROOT / "packages").glob("*/melange.yaml")):
        package = recipe.parent.name
        if recipe.is_symlink():
            try:
                recipe.resolve(strict=True).relative_to(ROOT.resolve())
            except (OSError, ValueError, RuntimeError) as error:
                raise PackageDiscoveryError(f"invalid package recipe link: {recipe}") from error
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
                source = (ROOT / recipe).resolve()
                if source.relative_to(ROOT.resolve()).as_posix() in changed:
                    selected.add(package)
                elif pipeline_changes:
                    pipelines = re.findall(r"(?m)^\s*-\s+uses:\s*(\S+)", source.read_text(encoding="utf-8"))
                    if any(f"pipelines/{pipeline}.yaml" in pipeline_changes for pipeline in pipelines):
                        selected.add(package)
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


def main() -> None:
    arguments = sys.argv[1:]
    if arguments == ["--all"]:
        print(json.dumps(generate(None, None), separators=(",", ":"), sort_keys=True))
        return
    if len(arguments) == 3 and arguments[0] == "--changed" and arguments[1] and arguments[2]:
        print(json.dumps(generate(arguments[1], arguments[2]), separators=(",", ":"), sort_keys=True))
        return
    raise SystemExit("usage: gen_apk_matrix.py --all | --changed BASE_SHA HEAD_SHA")


if __name__ == "__main__":
    main()
