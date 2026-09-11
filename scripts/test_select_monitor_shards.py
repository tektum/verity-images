#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_select_monitor_shards.py

from __future__ import annotations

from copy import deepcopy

from select_monitor_shards import changed_shards, shard_for


def image(name: str, version: str, digest: str = "sha256:old") -> dict[str, object]:
    return {"name": name, "version": version, "digest": digest}


def catalog(*images: dict[str, object], published: str = "old") -> dict[str, object]:
    return {"publishedAt": published, "images": list(images)}


def unchanged_images_ignore_catalog_metadata() -> None:
    previous = catalog(image("example", "1.0"), published="old")
    current = deepcopy(previous)
    current["publishedAt"] = "new"
    assert changed_shards(previous, current) == []


def changed_publication_selects_owning_shard() -> None:
    previous = catalog(image("example", "1.0"))
    current = catalog(image("example", "1.0", "sha256:new"))
    assert changed_shards(previous, current) == [shard_for("example", "1.0")]


def version_change_selects_old_and_new_categories() -> None:
    previous = catalog(image("example", "1.0"))
    current = catalog(image("example", "3.0"))
    assert shard_for("example", "1.0") != shard_for("example", "3.0")
    assert changed_shards(previous, current) == sorted(
        {shard_for("example", "1.0"), shard_for("example", "3.0")}
    )


def additions_and_removals_are_reconciled() -> None:
    previous = catalog(image("removed", "1"), image("kept", "1"))
    current = catalog(image("added", "1"), image("kept", "1"))
    assert changed_shards(previous, current) == sorted(
        {shard_for("removed", "1"), shard_for("added", "1")}
    )


def invalid_catalog_is_rejected() -> None:
    duplicate = catalog(image("example", "1"), image("example", "2"))
    try:
        changed_shards(duplicate, catalog())
    except SystemExit as error:
        assert "duplicate catalog image name example" in str(error)
    else:
        raise AssertionError("duplicate catalog image names were accepted")


def main() -> None:
    unchanged_images_ignore_catalog_metadata()
    changed_publication_selects_owning_shard()
    version_change_selects_old_and_new_categories()
    additions_and_removals_are_reconciled()
    invalid_catalog_is_rejected()
    print("passed scripts/test_select_monitor_shards.py")


if __name__ == "__main__":
    main()
