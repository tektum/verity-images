#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_matrix.py

from pathlib import Path
import json
from datetime import UTC, datetime, timedelta
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

        static = gen_matrix.ROOT / "images/static"
        fingerprint = gen_matrix.input_digest(static, "plain")
        assert fingerprint == gen_matrix.input_digest(static, "plain")
        assert fingerprint.startswith("sha256:") and len(fingerprint) == 71

        catalog = Path(temporary_directory) / "catalog.json"
        catalog.write_text(
            json.dumps(
                {
                    "images": [
                        {
                            "name": "static",
                            "version": gen_matrix.parse_metadata(static / "metadata.yaml").versions[0],
                            "inputDigest": fingerprint,
                            "validatedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        cached = gen_matrix.cached_images(catalog, timedelta(hours=24))
        assert cached[("static", gen_matrix.parse_metadata(static / "metadata.yaml").versions[0])] == fingerprint
        assert not any(entry["context"] == "images/static" for entry in gen_matrix.generate(None, catalog)["include"])
        assert any(
            entry["context"] == "images/static"
            for entry in gen_matrix.generate(None, catalog, timedelta(seconds=-1))["include"]
        )
        document = json.loads(catalog.read_text(encoding="utf-8"))
        document["images"][0]["validatedAt"] = "2026-08-13T00:00:00"
        catalog.write_text(json.dumps(document), encoding="utf-8")
        assert gen_matrix.cached_images(catalog, timedelta(hours=24)) == {}


if __name__ == "__main__":
    main()
