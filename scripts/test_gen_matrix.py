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
        root = Path(temporary_directory)
        source = root / "source.yaml"
        accepted = {registry for registry in REGISTRIES if source_is_valid(source, registry)}
        assert accepted == set(REGISTRIES), accepted
        assert all(not source_is_valid(source, registry) for registry in REJECTED_REGISTRIES)

        for tag, expected in (
            ("10.0.65", "10.0.65"),
            ("v10.0.65", "10.0.65"),
            ("12-slim", "12"),
            ("12.3-ubi10", "12.3"),
        ):
            assert gen_matrix.source_version(f"docker.io/example/image:{tag}", source) == expected
        try:
            gen_matrix.source_version("docker.io/example/image:latest", source)
        except gen_matrix.MetadataError:
            pass
        else:
            raise AssertionError("non-version source tag was accepted")

        patched = root / "patched"
        patched.mkdir()
        (patched / "source.yaml").write_text(
            "image: docker.io/example/image:12.3-ubi10\n"
            f"digest: sha256:{'0' * 64}\n"
            "platforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
        metadata = patched / "metadata.yaml"
        metadata.write_text(
            "name: example\ntrack: patched\ndescription: Example.\nenabled: true\n",
            encoding="utf-8",
        )
        (patched / "source.yaml").unlink()
        try:
            gen_matrix.parse_metadata(metadata)
        except gen_matrix.MetadataError as error:
            assert str(error).endswith("missing source.yaml")
        else:
            raise AssertionError("missing patched source was accepted")
        (patched / "source.yaml").write_text(
            "image: docker.io/example/image:12.3-ubi10\n"
            f"digest: sha256:{'0' * 64}\n"
            "platforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
        parsed = gen_matrix.parse_metadata(metadata)
        assert parsed.upstream == "docker.io/example/image:12.3-ubi10"
        assert parsed.versions == ("12.3",)
        metadata.write_text(
            "name: example\ntrack: patched\ndescription: Example.\n"
            "upstream: docker.io/example/stale:1\nversions: [1]\nenabled: true\n",
            encoding="utf-8",
        )
        parsed = gen_matrix.parse_metadata(metadata)
        assert parsed.upstream == "docker.io/example/image:12.3-ubi10"
        assert parsed.versions == ("12.3",)

        static = gen_matrix.ROOT / "images/static"
        fingerprint = gen_matrix.input_digest(static, "plain")
        assert fingerprint == gen_matrix.input_digest(static, "plain")
        assert fingerprint.startswith("sha256:") and len(fingerprint) == 71

        catalog = root / "catalog.json"
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
        document = json.loads(catalog.read_text(encoding="utf-8"))
        document["images"][0]["validatedAt"] = (datetime.now(UTC) - timedelta(hours=25)).isoformat()
        catalog.write_text(json.dumps(document), encoding="utf-8")
        assert gen_matrix.cached_images(catalog, timedelta(hours=24)) == {}

        document["images"][0]["validatedAt"] = datetime.now().isoformat()
        catalog.write_text(json.dumps(document), encoding="utf-8")
        assert gen_matrix.cached_images(catalog, timedelta(hours=24)) == {}

if __name__ == "__main__":
    main()
