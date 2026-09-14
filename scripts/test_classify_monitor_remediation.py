#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import classify_monitor_remediation
import gen_apko_lock_targets
import gen_matrix


def image(
    root: Path,
    context: str,
    *,
    name: str,
    version: str = "1",
    track: str = "wolfi",
    enabled: bool = True,
    flavors: tuple[str, ...] = ("plain",),
    recipe: tuple[str, str, int] | None = None,
) -> None:
    directory = root / context
    (directory / "tests").mkdir(parents=True)
    (directory / "tests/test.sh").write_text("#!/bin/sh\n", encoding="utf-8")
    flavor = "" if flavors == ("plain",) else f"flavors: [{', '.join(flavors)}]\n"
    metadata = f"name: {name}\ntrack: {track}\ndescription: Example.\nenabled: {'true' if enabled else 'false'}\n"
    if track == "wolfi":
        metadata += f"upstream: https://example.test/{name}\nversions: [{version}]\n{flavor}"
        (directory / "apko.yaml").write_text("contents: {}\n", encoding="utf-8")
        (directory / "apko.lock.json").write_text("{}\n", encoding="utf-8")
        for item in flavors:
            if item != "plain":
                (directory / f"{item}.apko.yaml").write_text("contents: {}\n", encoding="utf-8")
                (directory / f"{item}.apko.lock.json").write_text("{}\n", encoding="utf-8")
        if recipe is not None:
            package, package_version, epoch = recipe
            (directory / "melange.yaml").write_text(
                f"package:\n  name: {package}\n  version: {package_version}\n  epoch: {epoch}\n",
                encoding="utf-8",
            )
    else:
        metadata += flavor
        (directory / "source.yaml").write_text(
            f"image: docker.io/example/{name}:{version}\ndigest: sha256:{'0' * 64}\nplatforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
    (directory / "metadata.yaml").write_text(metadata, encoding="utf-8")


def finding(name: str, version: str, package: str, installed: str, fixed: list[str], advisory: str) -> dict:
    return {
        "image": name,
        "version": version,
        "advisory": advisory,
        "package": {"name": package, "type": "apk", "installedVersion": installed},
        "fixedVersions": fixed,
    }


def classify(root: Path, findings: list[dict]) -> dict:
    with (
        patch.object(gen_matrix, "ROOT", root),
        patch.object(gen_apko_lock_targets, "ROOT", root),
        patch.object(classify_monitor_remediation, "ROOT", root),
    ):
        return classify_monitor_remediation.classify(
            {"schemaVersion": "verity-image-dashboard-report/v1", "findings": findings}
        )


def test_routes_and_deduplication() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/go/1", name="go", flavors=("plain", "fips"))
        image(root, "images/app", name="app", recipe=("app", "2.0", 0))
        image(root, "patched/base", name="base", track="patched")
        plan = classify(root, [
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("go", "1-fips", "openssl", "1-r0", ["1-r1"], "CVE-two"),
            finding("go", "1", "zlib", "1-r0", ["1-r1"], "CVE-three"),
            finding("app", "2", "app", "2.0-r0", ["2.0-r1"], "CVE-four"),
            finding("app", "2", "dependency", "1-r0", ["1-r1"], "CVE-five"),
            finding("base", "1", "openssl", "1-r0", ["1-r1"], "CVE-six"),
        ])
        assert plan["apko"] == [{"context": "images/go/1", "streams": ["go@1", "go@1-fips"]}]
        assert plan["exact"] == [
            {"stream": "app@2", "context": "images/app", "flavor": "plain", "kind": "recipe"},
            {"stream": "base@1", "context": "patched/base", "flavor": "plain", "kind": "patched"},
        ]
        assert plan["localPackageRevisions"] == [{
            "context": "images/app", "recipe": "images/app/melange.yaml", "package": "app",
            "version": "2.0", "fromEpoch": 0, "toEpoch": 1, "streams": ["app@2"],
        }]
        assert plan["blocked"] == []


def test_fail_closed_contexts_and_epochs() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/disabled", name="disabled", enabled=False)
        image(root, "images/one", name="ambiguous")
        image(root, "images/two", name="ambiguous")
        image(root, "images/local", name="local", recipe=("local", "1.0", 2))
        plan = classify(root, [
            finding("disabled", "1", "openssl", "1-r0", ["1-r1"], "CVE-disabled"),
            finding("ambiguous", "1", "openssl", "1-r0", ["1-r1"], "CVE-ambiguous"),
            finding("absent", "1", "openssl", "1-r0", ["1-r1"], "CVE-unknown"),
            finding("local", "1", "local", "1.0-r2", ["1.1-r0"], "CVE-version"),
            finding("local", "1", "local", "1.0-r2", ["1.0-r2"], "CVE-epoch"),
        ])
        assert plan["exact"] == [] and plan["apko"] == [] and plan["localPackageRevisions"] == []
        assert {(item["stream"], item["reason"]) for item in plan["blocked"]} == {
            ("disabled@1", "disabled image stream"),
            ("ambiguous@1", "ambiguous image stream"),
            ("absent@1", "unknown image stream"),
            ("local@1", "unsafe local package revision for local"),
        }


def main() -> None:
    test_routes_and_deduplication()
    test_fail_closed_contexts_and_epochs()
    print("passed scripts/test_classify_monitor_remediation.py")


if __name__ == "__main__":
    main()
