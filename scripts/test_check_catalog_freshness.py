#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_check_catalog_freshness.py

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import check_catalog_freshness
import gen_matrix
from test_gen_matrix import write_image


def main() -> None:
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory) / "repo"
        for name in ("fresh", "stranded"):
            write_image(root / f"images/{name}", name=name, versions="1", package_version="1.0.0")

        def git(*arguments: str) -> str:
            return subprocess.run(
                ["git", "-c", "user.email=test@example.com", "-c", "user.name=test", *arguments],
                cwd=root,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

        git("init", "--quiet", "--initial-branch=main")
        git("add", ".")
        git("commit", "--quiet", "-m", "built")
        built = git("rev-parse", "HEAD")
        (root / "images/stranded/apko.yaml").write_text("contents:\n  packages:\n    - curl\n", encoding="utf-8")
        git("add", ".")
        git("commit", "--quiet", "-m", "stranded merge")
        head = git("rev-parse", "HEAD")

        catalog = Path(temporary_directory) / "catalog.json"

        def write(records: list[tuple[str, str]]) -> None:
            catalog.write_text(
                json.dumps(
                    {"images": [{"name": name, "version": "1", "sourceCommit": commit} for name, commit in records]}
                ),
                encoding="utf-8",
            )

        with patch.object(gen_matrix, "ROOT", root):
            # The top-level source advancing to head does not hide a record built before the merge.
            write([("fresh", built), ("stranded", built)])
            assert check_catalog_freshness.stale_records(catalog) == [("stranded", "1", built)]
            write([("fresh", built), ("stranded", head)])
            assert check_catalog_freshness.stale_records(catalog) == []
            write([("stranded", "0" * 40)])
            try:
                check_catalog_freshness.stale_records(catalog)
            except SystemExit as error:
                assert "not an ancestor" in str(error)
            else:
                raise AssertionError("an unreachable sourceCommit was accepted")


if __name__ == "__main__":
    main()
