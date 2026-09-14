#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

import gzip
import io
import subprocess
import tarfile
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
    metadata = (
        f"name: {name}\ntrack: {track}\ndescription: Example.\n"
        f"enabled: {'true' if enabled else 'false'}\n"
    )
    if track == "wolfi":
        metadata += f"upstream: https://example.test/{name}\nversions: [{version}]\n{flavor}"
        config = (
            "contents:\n"
            "  repositories:\n"
            f"    - {classify_monitor_remediation.WOLFI_REPOSITORY}\n"
            "  keyring:\n"
            f"    - {classify_monitor_remediation.WOLFI_KEY}\n"
            "  packages: []\n"
        )
        (directory / "apko.yaml").write_text(config, encoding="utf-8")
        (directory / "apko.lock.json").write_text("{}\n", encoding="utf-8")
        for item in flavors:
            if item != "plain":
                (directory / f"{item}.apko.yaml").write_text(config, encoding="utf-8")
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
            f"image: docker.io/example/{name}:{version}\n"
            f"digest: sha256:{'0' * 64}\n"
            "platforms: [linux/amd64, linux/arm64]\n",
            encoding="utf-8",
        )
    (directory / "metadata.yaml").write_text(metadata, encoding="utf-8")


def finding(
    name: str,
    version: str,
    package: str,
    installed: str,
    fixed: list[str],
    advisory: str,
    package_type: str = "apk",
) -> dict:
    return {
        "image": name,
        "version": version,
        "advisory": advisory,
        "package": {"name": package, "type": package_type, "installedVersion": installed},
        "fixedVersions": fixed,
    }


def gzip_tar(files: dict[str, bytes]) -> bytes:
    plain = io.BytesIO()
    with tarfile.open(fileobj=plain, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, contents in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(contents)
            member.mode = 0o644
            member.mtime = 0
            archive.addfile(member, io.BytesIO(contents))
    return gzip.compress(plain.getvalue(), mtime=0)


class SignedRepository:
    def __init__(self, root: Path, packages: dict[str, set[tuple[str, str]]]) -> None:
        private = root / "wolfi-signing.rsa"
        public = root / "wolfi-signing.rsa.pub"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", private, "-pubout", "-out", public],
            check=True,
            capture_output=True,
        )
        self.responses = {classify_monitor_remediation.WOLFI_KEY: public.read_bytes()}
        for architecture in classify_monitor_remediation.APK_ARCHITECTURES:
            records = "\n\n".join(
                f"C:Q1checksum\nP:{name}\nV:{version}\nA:{architecture}\nS:1"
                for name, version in sorted(packages.get(architecture, set()))
            )
            if not records:
                records = f"C:Q1checksum\nP:unrelated\nV:1-r0\nA:{architecture}\nS:1"
            index = gzip_tar({"APKINDEX": f"{records}\n".encode(), "DESCRIPTION": b""})
            signature = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", private],
                input=index,
                check=True,
                capture_output=True,
            ).stdout
            signature_archive = gzip_tar({".SIGN.RSA256.wolfi-signing.rsa.pub": signature})
            self.responses[
                f"{classify_monitor_remediation.WOLFI_REPOSITORY}/{architecture}/APKINDEX.tar.gz"
            ] = signature_archive + index
        self.calls: list[str] = []

    def fetch(self, url: str, limit: int) -> bytes:
        self.calls.append(url)
        data = self.responses[url]
        if len(data) > limit:
            raise AssertionError(f"fixture exceeds fetch limit for {url}")
        return data

    def query(self, requirements: set[tuple[str, str]]) -> dict[tuple[str, str], tuple[str, ...]]:
        return classify_monitor_remediation.query_wolfi_repository(requirements, fetch=self.fetch)


def classify(root: Path, findings: list[dict], repository_query=None) -> dict:
    if repository_query is None:
        def repository_query(_: set[tuple[str, str]]) -> dict[tuple[str, str], tuple[str, ...]]:
            raise AssertionError("unexpected repository query")
    with (
        patch.object(gen_matrix, "ROOT", root),
        patch.object(gen_apko_lock_targets, "ROOT", root),
        patch.object(classify_monitor_remediation, "ROOT", root),
    ):
        return classify_monitor_remediation.classify(
            {"schemaVersion": "verity-image-dashboard-report/v1", "findings": findings},
            repository_query,
        )


def test_available_on_both_architectures_and_deduplication() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/go/1", name="go", flavors=("plain", "fips"))
        image(root, "images/app", name="app", recipe=("app", "2.0", 0))
        image(root, "patched/base", name="base", track="patched")
        packages = {
            ("openssl", "1-r1"),
            ("zlib", "1-r1"),
            ("app", "2.0-r1"),
            ("dependency", "1-r1"),
        }
        repository = SignedRepository(root, {architecture: packages for architecture in classify_monitor_remediation.APK_ARCHITECTURES})
        plan = classify(root, [
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("go", "1-fips", "openssl", "1-r0", ["1-r1"], "CVE-two"),
            finding("go", "1", "zlib", "1-r0", ["1-r1"], "CVE-three"),
            finding("app", "2", "app", "2.0-r0", ["2.0-r1"], "CVE-four"),
            finding("app", "2", "dependency", "1-r0", ["1-r1"], "CVE-five"),
            finding("base", "1", "openssl", "1-r0", ["1-r1"], "CVE-six", "deb"),
        ], repository.query)
        assert repository.calls == [
            classify_monitor_remediation.WOLFI_KEY,
            f"{classify_monitor_remediation.WOLFI_REPOSITORY}/aarch64/APKINDEX.tar.gz",
            f"{classify_monitor_remediation.WOLFI_REPOSITORY}/x86_64/APKINDEX.tar.gz",
        ]
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


def test_missing_one_and_both_architectures_block_context() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/go/1", name="go", flavors=("plain", "fips"))
        repository = SignedRepository(root, {"x86_64": {("openssl", "1-r1")}})
        plan = classify(root, [
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("go", "1-fips", "zlib", "1-r0", ["1-r1"], "CVE-two"),
        ], repository.query)
        assert plan["exact"] == [] and plan["apko"] == [] and plan["localPackageRevisions"] == []
        assert plan["blocked"] == [
            {
                "stream": "go@1",
                "advisory": "CVE-one",
                "package": "openssl",
                "reason": "fixed Wolfi package version is not published for every required architecture",
                "requiredFixedVersion": "1-r1",
                "missingArchitectures": ["aarch64"],
            },
            {
                "stream": "go@1-fips",
                "advisory": "CVE-two",
                "package": "zlib",
                "reason": "fixed Wolfi package version is not published for every required architecture",
                "requiredFixedVersion": "1-r1",
                "missingArchitectures": ["aarch64", "x86_64"],
            },
        ]


def test_repository_failure_blocks_wolfi_but_preserves_patched() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/go", name="go")
        image(root, "patched/base", name="base", track="patched")
        repository = SignedRepository(root, {"x86_64": {("openssl", "1-r1")}})
        repository.responses[
            f"{classify_monitor_remediation.WOLFI_REPOSITORY}/aarch64/APKINDEX.tar.gz"
        ] = b"malformed"
        plan = classify(root, [
            finding("go", "1", "openssl", "1-r0", ["1-r1"], "CVE-one"),
            finding("base", "1", "openssl", "1-r0", ["1-r1"], "CVE-two", "deb"),
        ], repository.query)
        assert plan["exact"] == [
            {"stream": "base@1", "context": "patched/base", "flavor": "plain", "kind": "patched"}
        ]
        assert plan["apko"] == [] and plan["localPackageRevisions"] == []
        assert plan["blocked"] == [{
            "stream": "go@1",
            "advisory": "CVE-one",
            "package": "openssl",
            "reason": "Wolfi repository availability check failed",
            "requiredFixedVersion": "1-r1",
            "missingArchitectures": ["aarch64", "x86_64"],
        }]


def test_non_apk_wolfi_findings_do_not_query_or_dispatch() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/go", name="go")
        image(root, "patched/base", name="base", track="patched")
        plan = classify(root, [
            finding("go", "1", "openssl", "1", ["2"], "CVE-one", "deb"),
            finding("base", "1", "openssl", "1", ["2"], "CVE-two", "deb"),
        ])
        assert plan["exact"] == [
            {"stream": "base@1", "context": "patched/base", "flavor": "plain", "kind": "patched"}
        ]
        assert plan["apko"] == [] and plan["localPackageRevisions"] == []
        assert plan["blocked"] == [{
            "stream": "go@1",
            "advisory": "CVE-one",
            "package": "openssl",
            "reason": "unsupported package type for Wolfi remediation",
        }]


def test_fail_closed_contexts_and_epochs() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        image(root, "images/disabled", name="disabled", enabled=False)
        image(root, "images/one", name="ambiguous")
        image(root, "images/two", name="ambiguous")
        image(root, "images/local", name="local", recipe=("local", "1.0", 2))
        packages = {("local", "1.1-r0"), ("local", "1.0-r2")}
        repository = SignedRepository(root, {architecture: packages for architecture in classify_monitor_remediation.APK_ARCHITECTURES})
        plan = classify(root, [
            finding("disabled", "1", "openssl", "1-r0", ["1-r1"], "CVE-disabled"),
            finding("ambiguous", "1", "openssl", "1-r0", ["1-r1"], "CVE-ambiguous"),
            finding("absent", "1", "openssl", "1-r0", ["1-r1"], "CVE-unknown"),
            finding("local", "1", "local", "1.0-r2", ["1.1-r0"], "CVE-version"),
            finding("local", "1", "local", "1.0-r2", ["1.0-r2"], "CVE-epoch"),
        ], repository.query)
        assert plan["exact"] == [] and plan["apko"] == [] and plan["localPackageRevisions"] == []
        assert {(item["stream"], item["reason"]) for item in plan["blocked"]} == {
            ("disabled@1", "disabled image stream"),
            ("ambiguous@1", "ambiguous image stream"),
            ("absent@1", "unknown image stream"),
            ("local@1", "unsafe local package revision for local"),
        }


def main() -> None:
    test_available_on_both_architectures_and_deduplication()
    test_missing_one_and_both_architectures_block_context()
    test_repository_failure_blocks_wolfi_but_preserves_patched()
    test_non_apk_wolfi_findings_do_not_query_or_dispatch()
    test_fail_closed_contexts_and_epochs()
    print("passed scripts/test_classify_monitor_remediation.py")


if __name__ == "__main__":
    main()
