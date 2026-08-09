#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_matrix.py

from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

import gen_matrix

REGISTRIES: Final = ("docker.io", "registry.k8s.io", "docker.elastic.co", "ghcr.io")
REJECTED_REGISTRIES: Final = (
    "docker.io.example",
    "registry.k8s.io.example",
    "docker.elastic.co.example",
    "ghcr.io.example",
    "quay.io",
)


def source_is_valid(path: Path, registry: str) -> bool:
    path.write_text(
        f"image: {registry}/example/image:1\n"
        f"digest: sha256:{'0' * 64}\n"
        "platforms: [linux/amd64, linux/arm64]\n",
        encoding="utf-8",
    )
    try:
        gen_matrix.parse_source(path)
    except gen_matrix.MetadataError:
        return False
    return True


def main() -> None:
    with TemporaryDirectory() as temporary_directory:
        source = Path(temporary_directory) / "source.yaml"
        accepted = {registry for registry in REGISTRIES if source_is_valid(source, registry)}
        assert accepted == set(REGISTRIES), accepted
        assert all(not source_is_valid(source, registry) for registry in REJECTED_REGISTRIES)


if __name__ == "__main__":
    main()
