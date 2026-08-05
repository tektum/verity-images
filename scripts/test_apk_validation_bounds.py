#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_validation_bounds.py

from __future__ import annotations

import tempfile
from collections.abc import Callable
from pathlib import Path
from unittest.mock import patch

import apk_archive
import apk_repository_policy
import validate_repository_state
from apk_test_fixtures import signed_shape, unsigned_package


def rejects(expected: str, action: Callable[[], None]) -> None:
    try:
        action()
    except ValueError as error:
        assert str(error) == expected
    else:
        raise AssertionError("invalid input was accepted")


def package(recipe_version: str = "1.0.0-r1", architecture: str = "x86_64") -> bytes:
    return signed_shape(
        unsigned_package(
            architecture,
            (),
            name="example-package",
            version="1.0.0-r1",
            recipe_version=recipe_version,
        )
    )


def recipe_version_mismatch_fails() -> None:
    rejects(
        "package recipe identity mismatch",
        lambda: apk_archive.package_info(package("1.0.1-r1"), "x86_64"),
    )


def recipe_epoch_mismatch_fails() -> None:
    rejects(
        "package recipe identity mismatch",
        lambda: apk_archive.package_info(package("1.0.0-r2"), "x86_64"),
    )


def package_architecture_mismatch_fails() -> None:
    rejects(
        "invalid package metadata",
        lambda: apk_archive.package_info(package(architecture="aarch64"), "x86_64"),
    )


def oversized(path: Path) -> None:
    with path.open("wb") as output:
        output.truncate(apk_archive.MAX_ARCHIVE_SIZE + 1)


def bounded_read(action: Callable[[], None]) -> None:
    with patch.object(Path, "read_bytes", side_effect=AssertionError("full file read")):
        rejects("invalid compressed archive size", action)


def oversized_package_rejects_before_reading() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "package.apk"
        oversized(path)
        bounded_read(lambda: apk_repository_policy.checked_package(path, "x86_64"))


def oversized_index_rejects_before_reading() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "APKINDEX.tar.gz"
        oversized(path)
        bounded_read(lambda: apk_archive.read_archive(path))


def oversized_repository_archive_rejects_before_reading() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "repository.tar.zst"
        oversized(path)
        bounded_read(lambda: validate_repository_state.validate_archive({"archive": {"root": "apk"}}, path))


def main() -> None:
    recipe_version_mismatch_fails()
    recipe_epoch_mismatch_fails()
    package_architecture_mismatch_fails()
    oversized_package_rejects_before_reading()
    oversized_index_rejects_before_reading()
    oversized_repository_archive_rejects_before_reading()


if __name__ == "__main__":
    main()
