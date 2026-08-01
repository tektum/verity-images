#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_fips_matrix.py

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import gen_matrix


def main() -> None:
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        image = root / "images" / "fixture"
        (image / "tests").mkdir(parents=True)
        (image / "metadata.yaml").write_text(
            "name: fixture\n"
            "track: wolfi\n"
            "description: fixture\n"
            "upstream: https://example.com/\n"
            "versions: [1]\n"
            "flavors: [plain, fips]\n"
            "enabled: true\n",
            encoding="utf-8",
        )
        (image / "apko.yaml").write_text("contents: {}\n", encoding="utf-8")
        (image / "fips.apko.yaml").write_text(
            "contents:\n  packages: [openssl-fips-provider@local]\n",
            encoding="utf-8",
        )
        (image / "melange.yaml").touch()
        (image / "tests" / "test.sh").touch()
        with (
            patch.object(gen_matrix, "ROOT", root),
            patch.object(gen_matrix, "image_directories", return_value=[image]),
            patch.object(
                gen_matrix,
                "changed_paths",
                return_value={"packages/openssl-fips-provider/melange.yaml"},
            ),
        ):
            entries = gen_matrix.generate("base")["include"]
        assert [(entry["name"], entry["flavor"]) for entry in entries] == [
            ("fixture", "fips")
        ]


if __name__ == "__main__":
    main()
