#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

import os
import subprocess

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import validate_version_streams as validator


def melange(name: str, version: str, prefix: str | None = None) -> str:
    update = "" if prefix is None else f"update:\n  github:\n    tag-filter-prefix: {prefix}\n"
    return f'package:\n  name: {name}\n  version: "{version}"\n  epoch: 0\n{update}'


def metadata(version: str) -> str:
    return f"name: example\ntrack: wolfi\nversions: [{version}]\nenabled: true\n"


def main() -> None:
    assert validator.stream("3.7.1") == "3.7"
    assert validator.stream("v3.7.1-rc.1") == "3.7"
    assert validator.stream("9") == "9"

    unchanged = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.6", "3.6.14", "v3.6"),
        melange("etcd-3.6", "3.6.15", "v3.6"),
        metadata("3.6"),
        metadata("3.6"),
        "packages:\n  - etcd-3.6@local\n",
        "packages:\n  - etcd-3.6@local\n",
    )
    assert unchanged == []

    stale = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.6", "3.6.14", "v3.6"),
        melange("etcd-3.6", "3.7.1", "v3.6"),
        metadata("3.6"),
        metadata("3.6"),
        "packages:\n  - etcd-3.6@local\n  - etcd-3.6-compat@local\n",
        "packages:\n  - etcd-3.6@local\n  - etcd-3.6-compat@local\n",
    )
    assert stale == [
        "images/etcd/metadata.yaml: versions must change from 3.6 to 3.7",
        "images/etcd/melange.yaml: package.name must change from etcd-3.6 to etcd-3.7",
        "images/etcd/apko.yaml: package references must change from etcd-3.6 to etcd-3.7",
        "images/etcd/melange.yaml: tag-filter-prefix must change from 3.6 to 3.7",
    ]

    updated = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.6", "3.6.14", "v3.6."),
        melange("etcd-3.7", "3.7.1", "v3.7."),
        metadata("3.6"),
        metadata("3.7"),
        "packages:\n  - etcd-3.6@local\n  - etcd-3.6-compat@local\n",
        "packages:\n  - etcd-3.7@local\n  - etcd-3.7-compat@local\n",
    )
    assert updated == []
    removed_apko = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.6", "3.6.14", "v3.6."),
        melange("etcd-3.7", "3.7.1", "v3.7."),
        metadata("3.6"),
        metadata("3.7"),
        "packages:\n  - etcd-3.6@local\n",
        None,
    )
    assert removed_apko == [
        "images/etcd/apko.yaml: tracked file must not be removed during a stream change"
    ]

    generic_name = validator.validate_transition(
        "images/argocd",
        melange("verity-argocd", "3.3.14", "v3.3."),
        melange("verity-argocd", "3.5.2", "v3.5."),
        metadata("3.3"),
        metadata("3.5"),
        None,
        None,
    )
    assert generic_name == []
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        directory = root / "images" / "etcd"
        directory.mkdir(parents=True)
        current_melange = melange("etcd-3.6", "3.7.1", "v3.6")
        current_metadata = metadata("3.6")
        current_apko = "packages:\n  - etcd-3.6@local\n"
        (directory / "melange.yaml").write_text(current_melange, encoding="utf-8")
        (directory / "metadata.yaml").write_text(current_metadata, encoding="utf-8")
        (directory / "apko.yaml").write_text(current_apko, encoding="utf-8")
        old = {
            "images/etcd/melange.yaml": melange("etcd-3.6", "3.6.14", "v3.6"),
            "images/etcd/metadata.yaml": metadata("3.6"),
            "images/etcd/apko.yaml": current_apko,
        }
        with (
            patch.object(validator, "ROOT", root),
            patch.object(validator, "git", return_value="images/etcd/melange.yaml\n"),
            patch.object(validator, "base_contents", side_effect=lambda _base, path: old.get(path)),
        ):
            assert validator.validate_changed("base") == stale
            (directory / "metadata.yaml").unlink()
            assert validator.validate_changed("base") == [
                "images/etcd/metadata.yaml: tracked file must not be removed during a stream change"
            ]
    stale_baseline = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.5", "3.6.14", "v3.5"),
        melange("etcd-3.5", "3.7.1", "v3.5"),
        metadata("3.5"),
        metadata("3.5"),
        "packages:\n  - etcd-3.5@local\n",
        "packages:\n  - etcd-3.5@local\n",
    )
    assert stale_baseline == [
        "images/etcd/metadata.yaml: versions must change from 3.5 to 3.7",
        "images/etcd/melange.yaml: package.name must change from etcd-3.5 to etcd-3.7",
        "images/etcd/apko.yaml: package references must change from etcd-3.5 to etcd-3.7",
        "images/etcd/melange.yaml: tag-filter-prefix must change from 3.5 to 3.7",
    ]
    spoofed_apko = validator.validate_transition(
        "images/etcd",
        melange("etcd-3.6", "3.6.14", "v3.6"),
        melange("etcd-3.7", "3.7.1", "v3.7"),
        metadata("3.6"),
        metadata("3.7"),
        "packages:\n  - etcd-3.6@local\n  - etcd-3.6-compat@local\n",
        "packages:\n  - other-etcd-3.7@local\n",
    )
    assert spoofed_apko == [
        "images/etcd/apko.yaml: package references must change from etcd-3.6 to etcd-3.7"
    ]
    with (
        patch.dict(os.environ, {}, clear=True),
        patch.object(
            validator.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 1, "", "missing"),
        ),
    ):
        try:
            validator.default_base()
        except validator.StreamError as error:
            assert str(error) == "base ref is unavailable: origin/main"
        else:
            raise AssertionError("missing base ref was accepted")


    try:
        validator.stream("latest")
    except validator.StreamError:
        pass
    else:
        raise AssertionError("non-numeric version stream was accepted")


if __name__ == "__main__":
    main()
