#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_gen_matrix.py

from pathlib import Path
import json
import re
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
    version_literal: str | None = None,
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
    if package_version is None and version_literal is None:
        (directory / "apko.lock.json").write_text("{}\n", encoding="utf-8")
        return metadata
    literal = f'"{package_version}"' if version_literal is None else version_literal
    variables = "" if upstream_version is None else f"vars:\n  upstream-version: {upstream_version}\n"
    (directory / "melange.yaml").write_text(
        f"package:\n  name: {name}\n  version: {literal}\n  epoch: 0  # remediation\n{variables}"
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

        # Every valid YAML scalar form of package.version is read, including a
        # single-quoted value and an unquoted value with an inline comment.
        assert derived_version(root, 10, name="quoted", versions="1.2", version_literal="'1.2.3'") == "1.2"
        assert derived_version(root, 11, name="commented", versions="1.2.3", version_literal="1.2.3 # pinned") == "1.2.3"
        assert derived_version(root, 12, name="both", versions="1.2", version_literal='"1.2.3"  # pinned') == "1.2"


def check_source_bump_matrix() -> None:
    # A Renovate melange-only bump, in the shape of etcd 3.6.14 -> 3.7.1: the
    # metadata channel stays [3.6] and the matrix must publish 3.7 anyway. The
    # fixture is synthetic on purpose, so a later real etcd release cannot turn
    # this regression into a silent no-op.
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        image = root / "images/etcd"
        metadata = write_image(image, name="etcd", versions="3.6", package_version="3.6.14")
        declared = metadata.read_bytes()
        with patch.object(gen_matrix, "ROOT", root):
            before = gen_matrix.generate(None)["include"]
            (image / "melange.yaml").write_text(
                (image / "melange.yaml").read_text(encoding="utf-8").replace('"3.6.14"', '"3.7.1"'),
                encoding="utf-8",
            )
            entries = gen_matrix.generate(None)["include"]
        assert [(entry["version"], entry["tag_version"]) for entry in before] == [("3.6", "3.6")]
        assert [(entry["version"], entry["tag_version"]) for entry in entries] == [("3.7", "3.7")]
        assert metadata.read_bytes() == declared

    # The derived channel names the build report, the scan bundle, and the report
    # version that the build-gate summary table renders, so that bump reports 3.7
    # with report-etcd-3.7 and scan-etcd-3.7 instead of a stale 3.6.
    build = (gen_matrix.ROOT / ".github/workflows/build.yaml").read_text(encoding="utf-8")
    action = (gen_matrix.ROOT / ".github/actions/publish-image/action.yaml").read_text(encoding="utf-8")
    entry = entries[0]
    assert build.count("name: report-${{ matrix.name }}-${{ matrix.tag_version }}") == 2
    assert build.count("tag-version: ${{ matrix.tag_version }}") == 2
    assert build.count("VERSION: ${{ matrix.tag_version }}") == 2
    assert "name: scan-${{ inputs.image-name }}-${{ inputs.tag-version }}" in action
    assert (
        f"report-{entry['name']}-{entry['tag_version']}",
        f"scan-{entry['name']}-{entry['tag_version']}",
    ) == ("report-etcd-3.7", "scan-etcd-3.7")


def check_major_tag() -> None:
    # `major` opts in to a floating major tag whose value is derived, so it can
    # never point at a different major than the published version.
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        image = root / "images/gitea"
        metadata = write_image(image, name="gitea", versions="1.24.7", package_version="1.27.2")
        metadata.write_text(metadata.read_text(encoding="utf-8") + 'major: "1"\n', encoding="utf-8")
        with patch.object(gen_matrix, "ROOT", root):
            entries = gen_matrix.generate(None)["include"]
            assert [(entry["version"], entry["major"], entry["latest"]) for entry in entries] == [
                ("1.27.2", "1", True)
            ]
            # A cross-major bump must not keep publishing the stale `1` tag.
            (image / "melange.yaml").write_text(
                (image / "melange.yaml").read_text(encoding="utf-8").replace('"1.27.2"', '"2.0.0"'),
                encoding="utf-8",
            )
            try:
                gen_matrix.generate(None)
            except gen_matrix.MetadataError as error:
                assert str(error).endswith("major 1 must be the major component of the published version 2.0.0")
            else:
                raise AssertionError("a stale floating major tag was accepted")


def check_flavor_only_melange() -> None:
    # A directory whose only recipe is a flavor helper has no source version, so
    # its metadata channel stays authoritative.
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        image = root / "images/go/1.26"
        metadata = write_image(image, name="go", versions="1.26")
        (image / "fips.melange.yaml").write_text(
            'package:\n  name: go-fips-activation\n  version: "1.0.0"\n  epoch: 0\n', encoding="utf-8"
        )
        assert gen_matrix.parse_metadata(metadata).versions == ("1.26",)


def check_published_gap_selection() -> None:
    # `--published` rebuilds an identity the catalog does not carry yet, so a
    # version-authority change cannot wait for an unrelated image push.
    with TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        write_image(root / "images/trivy", name="trivy", versions="0.73.0", package_version="0.74.0")
        catalog = root / "catalog.json"
        catalog.write_text(json.dumps({"images": [{"name": "trivy", "version": "0.73.0"}]}), encoding="utf-8")
        with (
            patch.object(gen_matrix, "ROOT", root),
            patch.object(gen_matrix, "changed_paths", return_value=set()),
        ):
            assert gen_matrix.generate("base")["include"] == []
            entries = gen_matrix.generate("base", published_catalog=catalog)["include"]
            assert [(entry["name"], entry["tag_version"]) for entry in entries] == [("trivy", "0.74.0")]
            catalog.write_text(json.dumps({"images": [{"name": "trivy", "version": "0.74.0"}]}), encoding="utf-8")
            assert gen_matrix.generate("base", published_catalog=catalog)["include"] == []


def check_authority_drift() -> None:
    # Deriving the published version corrects exactly these images, whose merged
    # melange bumps left metadata behind. The last field is `enabled`, so only the
    # five enabled entries change a published tag; the quarantined two publish
    # nothing. Every other image keeps its current tag. Update this set
    # deliberately when one of these definitions is reconciled.
    expected = {
        ("images/gitea", "1.24.7", "1.27.2", False),
        ("images/grafana", "12.4", "13.2", False),
        ("images/karpenter", "1.11", "1.14", True),
        ("images/kube-bench", "0.11.2", "0.16.0", True),
        ("images/sealed-secrets", "0.38.4", "0.39.1", True),
        ("images/trivy", "0.73.0", "0.74.0", True),
        ("images/valkey", "9.0", "9.1", True),
    }
    declared = re.compile(r"^versions:\s*\[\s*([^,\]\s]+)\s*\]\s*$", re.MULTILINE)
    drifted = set()
    for directory in gen_matrix.image_directories():
        metadata = directory / "metadata.yaml"
        parsed = gen_matrix.parse_metadata(metadata)
        match = declared.search(metadata.read_text(encoding="utf-8"))
        # A patched image already derived its version from source.yaml before this
        # change, so only wolfi metadata can drift from a new authority here.
        if parsed.track == "wolfi" and match is not None and match.group(1) != parsed.versions[0]:
            drifted.add(
                (
                    directory.relative_to(gen_matrix.ROOT).as_posix(),
                    match.group(1),
                    parsed.versions[0],
                    parsed.enabled,
                )
            )
    assert drifted == expected, drifted


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
        static_copy = root / "images/static"
        copytree(static, static_copy)
        with patch.object(gen_matrix, "ROOT", root):
            fingerprint = gen_matrix.input_digest(static_copy, "plain")
            for ignored in (static_copy / "metadata.yaml", static_copy / "tests/test.sh"):
                ignored.write_bytes(ignored.read_bytes() + b"\n")
                assert fingerprint == gen_matrix.input_digest(static_copy, "plain")
            apko = static_copy / "apko.yaml"
            apko.write_bytes(apko.read_bytes() + b"\n")
            assert fingerprint != gen_matrix.input_digest(static_copy, "plain")
        assert fingerprint.startswith("sha256:") and len(fingerprint) == 71
        fingerprint = gen_matrix.input_digest(static, "plain")

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
    check_major_tag()
    check_flavor_only_melange()
    check_published_gap_selection()
    check_authority_drift()


if __name__ == "__main__":
    main()
