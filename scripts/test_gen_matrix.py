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
from shutil import copytree
from tempfile import TemporaryDirectory
from typing import Final
from unittest.mock import patch

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


def write_image(
    directory: Path,
    *,
    name: str,
    versions: str,
    package_version: str | None = None,
    upstream_version: str | None = None,
) -> Path:
    (directory / "tests").mkdir(parents=True)
    (directory / "tests/test.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (directory / "apko.yaml").write_text("contents:\n  packages:\n    - busybox\n", encoding="utf-8")
    metadata = directory / "metadata.yaml"
    metadata.write_text(
        f"name: {name}\ntrack: wolfi\ndescription: Example.\n"
        f"upstream: https://example.com/\nversions: [{versions}]\nenabled: true\n",
        encoding="utf-8",
    )
    if package_version is None:
        (directory / "apko.lock.json").write_text("{}\n", encoding="utf-8")
        return metadata
    variables = "" if upstream_version is None else f"vars:\n  upstream-version: {upstream_version}\n"
    (directory / "melange.yaml").write_text(
        f'package:\n  name: {name}\n  version: "{package_version}"\n  epoch: 0\n{variables}'
        "pipeline:\n  - uses: git-checkout\n    with:\n      tag: v${{package.version}}\n",
        encoding="utf-8",
    )
    return metadata


def derived_version(root: Path, index: int, **arguments: str | None) -> str:
    directory = root / "images" / f"example-{index}"
    return gen_matrix.parse_metadata(write_image(directory, **arguments)).versions[0]


def rejected_version(root: Path, index: int, **arguments: str | None) -> str:
    directory = root / "images" / f"rejected-{index}"
    try:
        gen_matrix.parse_metadata(write_image(directory, **arguments))
    except gen_matrix.MetadataError as error:
        return str(error)
    raise AssertionError(f"invalid image {index} was accepted")


def check_version_derivation() -> None:
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        # A minor stream transition follows melange without a metadata edit.
        assert derived_version(root, 1, name="etcd", versions="3.6", package_version="3.7.1") == "3.7"
        # Declared granularity is preserved: exact, major.minor, and major channels.
        assert derived_version(root, 2, name="gitea", versions="1.24.7", package_version="1.27.2") == "1.27.2"
        assert derived_version(root, 3, name="valkey", versions="9.0", package_version="9.1.1") == "9.1"
        assert derived_version(root, 4, name="deno", versions="2", package_version="2.9.4") == "2"
        # A literal channel stays literal for a source-built image and for pure APKO.
        assert derived_version(root, 5, name="configmap-reload", versions="latest", package_version="0.15.0") == "latest"
        assert derived_version(root, 6, name="static", versions="wolfi") == "wolfi"
        assert derived_version(root, 7, name="go", versions="1.26") == "1.26"
        # APK version syntax differs from upstream syntax, so metadata stays authoritative.
        assert (
            derived_version(
                root,
                8,
                name="tidb",
                versions="9.0.0-beta.1",
                package_version="9.0.0_beta1",
                upstream_version="26.3.10",
            )
            == "9.0.0-beta.1"
        )
        # APK-only version syntax without the documented exception is rejected.
        assert "declare vars.upstream-version" in rejected_version(
            root, 9, name="tidb", versions="9.0.0", package_version="9.0.0_beta1"
        )

        # A nested directory owns its stream, so a derived version must stay inside it.
        stream = root / "images/kubectl/1.35"
        assert gen_matrix.parse_metadata(
            write_image(stream, name="kubectl", versions="1.35", package_version="1.35.7")
        ).versions == ("1.35",)
        drifted = root / "images/kubectl/1.34"
        try:
            gen_matrix.parse_metadata(write_image(drifted, name="kubectl", versions="1.34", package_version="1.36.0"))
        except gen_matrix.MetadataError as error:
            assert str(error).endswith("version 1.36 must stay inside the 1.34 stream directory")
        else:
            raise AssertionError("a stream directory accepted a foreign version")


def check_source_bump_matrix() -> None:
    metadata = (gen_matrix.ROOT / "images/etcd/metadata.yaml").read_bytes()
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        copytree(gen_matrix.ROOT / "images/etcd", root / "images/etcd")
        melange = root / "images/etcd/melange.yaml"
        bumped = melange.read_text(encoding="utf-8").replace('version: "3.6.14"', 'version: "3.7.1"')
        assert 'version: "3.7.1"' in bumped
        melange.write_text(bumped, encoding="utf-8")
        with patch.object(gen_matrix, "ROOT", root):
            entries = gen_matrix.generate(None)["include"]
        assert [(entry["version"], entry["tag_version"]) for entry in entries] == [("3.7", "3.7")]
        assert (root / "images/etcd/metadata.yaml").read_bytes() == metadata


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
        metadata.write_text(
            "name: example\ntrack: patched\ndescription: Example 1.2.3.\n"
            "enabled: true\n",
            encoding="utf-8",
        )
        try:
            gen_matrix.parse_metadata(metadata)
        except gen_matrix.MetadataError as error:
            assert str(error).endswith("description must not contain a version")
        else:
            raise AssertionError("version-bearing metadata description was accepted")
        metadata.write_text(
            "name: example\ntrack: patched\ndescription: S3-compatible example.\n"
            "enabled: true\n",
            encoding="utf-8",
        )


        with patch.object(
            gen_matrix,
            "changed_paths",
            return_value={"images/trivy/metadata.yaml"},
        ):
            assert gen_matrix.generate("base")["include"] == []
        with patch.object(
            gen_matrix,
            "changed_paths",
            return_value={"images/trivy/tests/test.sh"},
        ):
            assert gen_matrix.generate("base")["include"] == []
        with patch.object(
            gen_matrix,
            "changed_paths",
            return_value={"images/trivy/tests/fixture.json"},
        ):
            assert gen_matrix.generate("base")["include"] == []
        with patch.object(
            gen_matrix,
            "changed_paths",
            return_value={"images/trivy/apko.yaml"},
        ):
            changed = gen_matrix.generate("base")["include"]
        assert len(changed) == 1
        assert changed[0]["context"] == "images/trivy"

        static = gen_matrix.ROOT / "images/static"
        fingerprint = gen_matrix.input_digest(static, "plain")
        metadata_contents = (gen_matrix.ROOT / "images/static/metadata.yaml").read_bytes()
        (gen_matrix.ROOT / "images/static/metadata.yaml").write_bytes(metadata_contents + b"\n")
        try:
            assert fingerprint == gen_matrix.input_digest(static, "plain")
        finally:
            (gen_matrix.ROOT / "images/static/metadata.yaml").write_bytes(metadata_contents)
        assert fingerprint == gen_matrix.input_digest(static, "plain")
        smoke_test = static / "tests/test.sh"
        smoke_contents = smoke_test.read_bytes()
        smoke_test.write_bytes(smoke_contents + b"\n")
        try:
            assert fingerprint == gen_matrix.input_digest(static, "plain")
        finally:
            smoke_test.write_bytes(smoke_contents)
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

    check_version_derivation()
    check_source_bump_matrix()


if __name__ == "__main__":
    main()
