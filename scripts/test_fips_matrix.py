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
            "contents:\n"
            "  repositories:\n"
            "    - https://tektum.github.io/verity-images/apk\n"
            "    - https://packages.wolfi.dev/os\n"
            "  keyring:\n"
            "    - packages/keys/verity-apk-2026.rsa.pub\n"
            "    - https://packages.wolfi.dev/os/wolfi-signing.rsa.pub\n"
            "  packages: [openssl-fips-provider=3.1.2-r2]\n",
            encoding="utf-8",
        )
        (image / "melange.yaml").touch()
        (image / "tests" / "test.sh").touch()
        patched = root / "patched" / "fixture"
        (patched / "tests").mkdir(parents=True)
        (patched / "metadata.yaml").write_text(
            "name: patched-fixture\n"
            "track: patched\n"
            "description: fixture\n"
            "upstream: docker.io/library/busybox:1\n"
            "versions: [1]\n"
            "enabled: true\n",
            encoding="utf-8",
        )
        (patched / "source.yaml").write_text(
            "image: docker.io/library/busybox:1\n"
            f"digest: sha256:{'0' * 64}\n"
            "platforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
        (patched / "tests" / "test.sh").touch()
        for changed_path in (
            "packages/repository-state.json",
            "packages/repository-state.schema.json",
            "packages/keys/verity-apk-2026.rsa.pub",
        ):
            with (
                patch.object(gen_matrix, "ROOT", root),
                patch.object(gen_matrix, "image_directories", return_value=[image, patched]),
                patch.object(gen_matrix, "changed_paths", return_value={changed_path}),
            ):
                entries = gen_matrix.generate("base")["include"]
            assert [(entry["name"], entry["flavor"]) for entry in entries] == [
                ("fixture", "fips")
            ]


if __name__ == "__main__":
    main()
