#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_scan_identity.py

import json
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final
from unittest.mock import patch

import gen_matrix
import scan_identity
import trim_sbom

# Immutable. The allowlist may only shrink, and this set is the superset it was frozen from. Never
# edit it again, not even to delete a name when an image leaves the allowlist: that image-local pull
# request deletes only its scripts/scan_identity_allowlist.d/ file. Never add a context here either:
# declare scan-identity or stamp the Go main module version instead. The test asserts the live
# entries are a subset of this set, and scripts/check_scan_identity_allowlist.py rejects a pull
# request that adds an entry file back.
FROZEN_BASELINE: Final = frozenset(
    f"images/{name}"
    for name in (
        "aws-node-termination-handler cassandra cert-manager-acmesolver cert-manager-cainjector "
        "cert-manager-controller cert-manager-startupapicheck cert-manager-webhook clickhouse cmake cmctl "
        "configmap-reload envoy external-secrets falcosidekick "
        "flux-cli/2.10 flux-cli/2.8 flux-cli/2.9 flux-helm-controller "
        "gradle haproxy haproxy-ingress jenkins kube-state-metrics mariadb/12.3 "
        "metallb-speaker metrics-server mysql/9.7 nodejs/22 postgres/17 "
        "source-controller tekton-controller trust-manager valkey victoria-metrics vmagent "
    ).split()
)
# Images with no CPE, GHSA or OSV record for their main software: nothing can be declared without
# inventing an identity. Immutable like FROZEN_BASELINE; adding an image here is a deliberate edit of this set.
FROZEN_NO_FEED: Final = frozenset(
    {"images/kubernetes-reflector", "images/opensearch-dashboards", "images/sonar-scanner-cli"}
)
LOCAL_FILES: Final = ["/usr", "/usr/bin", "/usr/bin/tool"]


def apk(name: str, files: list[str], origin: str | None = None) -> dict:
    return {
        "name": name,
        "version": "1-r0",
        "type": "apk",
        "metadata": {"originPackage": origin or name, "files": [{"path": path} for path in files]},
    }


def module(name: str, version: str, path: str = "/usr/bin/tool", *, main: bool = True) -> dict:
    return {
        "name": name,
        "version": version,
        "type": "go-module",
        "locations": [{"path": path}],
        "metadata": {"mainModule": name if main else ""},
    }


def crate(name: str, version: str, path: str = "/usr/bin/tool") -> dict:
    return {"name": name, "version": version, "type": "rust-crate", "locations": [{"path": path}]}


def sbom_fixture() -> dict:
    return {
        "name": "image",
        "packages": [{"name": "verity-tool", "SPDXID": "SPDXRef-apk", "versionInfo": "1.2.3-r0"}],
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relatedSpdxElement": "SPDXRef-Root", "relationshipType": "DESCRIBES"}
        ],
    }


class Image:
    """An image-local melange recipe with the Syft and SPDX output of its build."""

    def __init__(self, root: Path, artifacts: list[dict], *, identity: str = "", recipe: str = "melange.yaml"):
        self.root = root
        self.context = root / "images/tool"
        self.context.mkdir(parents=True)
        (self.context / "metadata.yaml").write_text(
            "name: tool\ntrack: wolfi\ndescription: Example.\nupstream: https://example.com/\nversions: [1.2]\n"
            f"enabled: true\n{identity}",
            encoding="utf-8",
        )
        self.recipe = self.context / recipe
        self.recipe.write_text("package:\n  name: verity-tool\n  version: 1.2.3\n  epoch: 0\n", encoding="utf-8")
        (self.context / "melange.yaml").touch()
        self.sbom = root / "sbom.spdx.json"
        self.sbom.write_text(json.dumps(sbom_fixture()), encoding="utf-8")
        self.syft = root / "syft.json"
        self.syft.write_text(json.dumps({"artifacts": [apk("verity-tool", LOCAL_FILES), *artifacts]}), encoding="utf-8")
        self.allowlist = root / "allowlist.d"
        self.allowlist.mkdir()

    def list_entry(self, follow_up: str, *, reason: str = "reason\n") -> None:
        name = "images/tool".replace("/", "__")
        (self.allowlist / name).write_text(f"{follow_up}\n{reason}", encoding="utf-8")

    def apply(self) -> str:
        # Contexts are repo-relative in production, so the temp dir's name must not leak into the entry name.
        original = scan_identity.ROOT
        scan_identity.ROOT = self.root.resolve()
        try:
            return scan_identity.apply(self.context, self.recipe, self.sbom, self.syft, self.allowlist)
        finally:
            scan_identity.ROOT = original

    def rejected(self) -> str:
        try:
            self.apply()
        except scan_identity.CoverageError as error:
            return str(error)
        raise AssertionError("an uncovered image was accepted")


def check_blind_spot_fails_closed() -> None:
    with TemporaryDirectory() as directory:
        # Syft's view of a melange build: a renamed apk and nothing else.
        assert "cannot see this image's main software" in Image(Path(directory), []).rejected()
    for version in ("UNKNOWN", "(devel)", ""):
        with TemporaryDirectory() as directory:
            image = Image(Path(directory), [module("example.com/tool", version)])
            assert "cannot see" in image.rejected(), version
    with TemporaryDirectory() as directory:
        # A dependency module is not the main software.
        assert "cannot see" in Image(Path(directory), [module("example.com/dep", "v1.0.0", main=False)]).rejected()
    with TemporaryDirectory() as directory:
        # A versioned Go binary owned by a Wolfi apk, such as gosu, says nothing about the local package.
        artifacts = [apk("gosu", ["/usr/bin/gosu"]), module("github.com/tianon/gosu", "v0.0.0-2026", "/usr/bin/gosu")]
        assert "cannot see" in Image(Path(directory), artifacts).rejected()


def check_native_coverage() -> None:
    cases = {
        "versioned Go main module": [module("example.com/tool", "v1.2.3+dirty")],
        "pseudo-versioned Go main module": [module("example.com/tool", "v0.0.0-20260101000000-abcdef123456")],
        "Rust main crate": [crate("tool", "1.2.3"), crate("serde", "1.0.200")],
        "Go toolchain stdlib": [module("stdlib", "go1.2.3", main=False)],
    }
    for label, artifacts in cases.items():
        with TemporaryDirectory() as directory:
            image = Image(Path(directory), artifacts)
            assert "natively" in image.apply(), label
            assert json.loads(image.sbom.read_text(encoding="utf-8")) == sbom_fixture(), label
    for label, artifacts in {
        "Rust dependencies only": [crate("serde", "1.0.200")],
        "stdlib of another toolchain": [module("stdlib", "go1.26.10", main=False)],
    }.items():
        with TemporaryDirectory() as directory:
            assert "cannot see" in Image(Path(directory), artifacts).rejected(), label
    with TemporaryDirectory() as directory:
        # Subpackages share the main package as their apk origin.
        artifacts = [apk("verity-tool-compat", ["/usr/bin/compat"], origin="verity-tool"), module("example.com/c", "v1.0.0", "/usr/bin/compat")]
        assert "natively" in Image(Path(directory), artifacts).apply()


def check_declared_identity() -> None:
    declared = "scan-identity: [cpe:2.3:a:oracle:mysql, pkg:golang/example.com/tool, pkg:cargo/tool]\n"
    with TemporaryDirectory() as directory:
        image = Image(Path(directory), [], identity=declared)
        assert "scanning declared identity" in image.apply()
        sbom = json.loads(image.sbom.read_text(encoding="utf-8"))
        added = {package["name"]: package for package in sbom["packages"][1:]}
        assert len(sbom["packages"]) == 4
        assert [ref["referenceLocator"] for ref in added["mysql"]["externalRefs"]] == [
            "cpe:2.3:a:oracle:mysql:1.2.3:*:*:*:*:*:*:*",
            "pkg:generic/mysql@1.2.3",
        ]
        assert added["example.com/tool"]["versionInfo"] == "v1.2.3"
        assert added["example.com/tool"]["externalRefs"][0]["referenceLocator"] == "pkg:golang/example.com/tool@v1.2.3"
        assert added["tool"]["externalRefs"][0]["referenceLocator"] == "pkg:cargo/tool@1.2.3"
        assert all(package["versionInfo"] in {"1.2.3", "v1.2.3"} for package in added.values())
        assert len({package["SPDXID"] for package in sbom["packages"]}) == 4
        contained = [r["relatedSpdxElement"] for r in sbom["relationships"] if r["relationshipType"] == "CONTAINS"]
        assert contained == [package["SPDXID"] for package in added.values()]
    with TemporaryDirectory() as directory:
        # A flavor-only helper recipe packages glue, not the runtime: nothing to declare or check.
        image = Image(Path(directory), [], identity=declared, recipe="fips.melange.yaml")
        assert image.apply() == scan_identity.NOT_APPLICABLE
        assert json.loads(image.sbom.read_text(encoding="utf-8")) == sbom_fixture()
    with TemporaryDirectory() as directory:
        # vars.upstream-version owns the upstream version when the APK version syntax differs.
        image = Image(Path(directory), [], identity="scan-identity: [cpe:2.3:a:pingcap:tidb]\n")
        image.recipe.write_text(
            "package:\n  name: verity-tool\n  version: 9.0.0_beta1\nvars:\n  upstream-version: 26.3.12\n", encoding="utf-8"
        )
        image.apply()
        assert "cpe:2.3:a:pingcap:tidb:26.3.12:" in image.sbom.read_text(encoding="utf-8")


def check_allowlist() -> None:
    with TemporaryDirectory() as directory:
        image = Image(Path(directory), [])
        image.list_entry("identity")
        assert "ALLOWLISTED" in image.apply()
        assert json.loads(image.sbom.read_text(encoding="utf-8")) == sbom_fixture()
    with TemporaryDirectory() as directory:
        image = Image(Path(directory), [module("example.com/tool", "v1.2.3")])
        image.list_entry("go-version")
        assert "stale allowlist entry" in image.apply()
    for name, text in (
        ("images__a", "identity\n"),
        ("images__a", "identity\n\n"),
        ("images__a", "unknown\nreason\n"),
        ("images__a", ""),
        ("images__a", "reason only\n"),
        ("images__a__b", "identity reason\n"),
    ):
        with TemporaryDirectory() as directory:
            (Path(directory) / name).write_text(text, encoding="utf-8")
            try:
                scan_identity.read_allowlist(Path(directory))
            except scan_identity.CoverageError:
                continue
            raise AssertionError(f"malformed allowlist entry accepted: {name!r} {text!r}")
    with TemporaryDirectory() as directory:
        (Path(directory) / "images__a").mkdir()
        try:
            scan_identity.read_allowlist(Path(directory))
        except scan_identity.CoverageError:
            pass
        else:
            raise AssertionError("a directory was accepted as an allowlist entry")
    with TemporaryDirectory() as directory:
        (Path(directory) / "README.md").write_text("notes\n", encoding="utf-8")
        (Path(directory) / "images__elixir__1.17").write_text("identity\nreason\n", encoding="utf-8")
        assert scan_identity.read_allowlist(Path(directory)) == {"images__elixir__1.17": "identity"}
    with TemporaryDirectory() as directory:
        image = Image(Path(directory), [])
        image.list_entry("no-feed")
        assert "follow-up: no-feed" in image.apply()


def check_metadata_validation() -> None:
    def parse(identity: str, *, recipe: bool = True) -> gen_matrix.Metadata:
        with TemporaryDirectory() as directory:
            image = Path(directory) / "images/tool"
            image.mkdir(parents=True)
            (image / "metadata.yaml").write_text(
                "name: tool\ntrack: wolfi\ndescription: Example.\nupstream: https://example.com/\n"
                f"versions: [wolfi]\nenabled: true\n{identity}",
                encoding="utf-8",
            )
            if recipe:
                (image / "melange.yaml").write_text("package:\n  name: tool\n  version: 1.0.0\n", encoding="utf-8")
            return gen_matrix.parse_metadata(image / "metadata.yaml")

    assert parse("").scan_identity == ()
    assert parse("scan-identity: [cpe:2.3:a:elixir-lang:elixir]\n").scan_identity == ("cpe:2.3:a:elixir-lang:elixir",)
    assert parse("scan-identity: [pkg:golang/github.com/coredns/coredns, cpe:2.3:a:nodejs:node.js]\n").scan_identity == (
        "pkg:golang/github.com/coredns/coredns",
        "cpe:2.3:a:nodejs:node.js",
    )
    assert parse("scan-identity: [cpe:2.3:a:erlang:erlang/otp]\n").scan_identity == ("cpe:2.3:a:erlang:erlang/otp",)
    for identity in (
        "scan-identity: []\n",
        "scan-identity: [cpe:2.3:a:oracle:mysql, cpe:2.3:a:oracle:mysql]\n",
        "scan-identity: [cpe:2.3:a:oracle:mysql:9.7.4]\n",
        "scan-identity: [cpe:2.3:a:oracle]\n",
        "scan-identity: [cpe:2.3:o:oracle:mysql]\n",
        "scan-identity: [cpe:2.3:a:*:mysql]\n",
        "scan-identity: [pkg:golang/example.com/tool@v1.0.0]\n",
        "scan-identity: [pkg:golang]\n",
        "scan-identity: [mysql]\n",
        "scan-identity: oracle:mysql\n",
        "scan-identity: [cpe:2.3:a:erlang:erlang/]\n",
        "scan-identity: [cpe:2.3:a:erlang:/otp]\n",
        "scan-identity: [cpe:2.3:a:erlang/otp:otp]\n",
    ):
        try:
            parse(identity)
        except gen_matrix.MetadataError as error:
            assert "scan-identity must be a unique list" in str(error), identity
        else:
            raise AssertionError(f"invalid scan-identity accepted: {identity!r}")
    try:
        parse("scan-identity: [cpe:2.3:a:oracle:mysql]\n", recipe=False)
    except gen_matrix.MetadataError as error:
        assert "requires an image-local melange.yaml" in str(error)
    else:
        raise AssertionError("scan-identity without a recipe was accepted")


def check_underscore_heavy_paths() -> None:
    for prefix, suffix in (("_", "_"), ("tmp_x__y", "__"), ("__", "")):
        with TemporaryDirectory(prefix=prefix, suffix=suffix) as directory:
            image = Image(Path(directory), [])
            image.list_entry("no-feed")
            assert "ALLOWLISTED" in image.apply(), (prefix, suffix)
    for context in ("images/a_", "images/_a", "images/a__b", "images/_/_x/1.2"):
        with TemporaryDirectory() as directory:
            (Path(directory) / scan_identity.entry_name(context)).write_text("identity\nreason\n", encoding="utf-8")
            assert scan_identity.read_allowlist(Path(directory)) == {scan_identity.entry_name(context): "identity"}


def check_repository_allowlist() -> None:
    names = scan_identity.read_allowlist(scan_identity.ALLOWLIST)
    real = [p.parent.relative_to(gen_matrix.ROOT).as_posix() for p in gen_matrix.ROOT.glob("images/**/metadata.yaml")]
    by_name = {scan_identity.entry_name(context): context for context in real}
    assert len(by_name) == len(real), "two image contexts share one allowlist entry name"
    unknown = sorted(set(names) - set(by_name))
    assert not unknown, f"allowlist entries naming no image context: {unknown}"
    listed = {by_name[name]: kind for name, kind in names.items()}
    frozen = {context for context, follow_up in listed.items() if follow_up != "no-feed"}
    assert frozen <= FROZEN_BASELINE, f"allowlist grew: {sorted(frozen - FROZEN_BASELINE)}"
    no_feed = {context for context, follow_up in listed.items() if follow_up == "no-feed"}
    assert no_feed <= FROZEN_NO_FEED, f"no-feed grew, edit FROZEN_NO_FEED deliberately: {sorted(no_feed - FROZEN_NO_FEED)}"
    assert (scan_identity.ALLOWLIST / "README.md").is_file(), "the allowlist directory marker was deleted"
    for context in listed:
        directory = gen_matrix.ROOT / context
        metadata = gen_matrix.parse_metadata(directory / "metadata.yaml")
        assert (directory / "melange.yaml").is_file(), f"{context}: allowlisted without an image-local recipe"
        assert metadata.enabled, f"{context}: allowlisted while disabled"
        assert not metadata.scan_identity, f"{context}: declares scan-identity, delete its allowlist entry"


APKO_DECLARED: Final = "scan-identity: [cpe:2.3:a:example:tool, pkg:pypi/tool]\nscan-package: tool\n"


def apko_lock(**packages: str) -> str:
    entries = [
        {"name": name, "version": version, "architecture": architecture}
        for name, version in packages.items()
        for architecture in ("x86_64", "aarch64")
    ]
    return json.dumps({"version": "v1", "contents": {"packages": entries}}, indent=2) + "\n"


def apk_package(name: str, version: str) -> dict:
    """An installed apk as Syft writes it to SPDX, with the CPE it guesses from the apk name."""
    return {
        "name": name,
        "SPDXID": f"SPDXRef-Package-apk-{name}",
        "versionInfo": version,
        "externalRefs": [
            {"referenceCategory": "SECURITY", "referenceType": "cpe23Type",
             "referenceLocator": f"cpe:2.3:a:{name}:{name}:{version}:*:*:*:*:*:*:*"},
            {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
             "referenceLocator": f"pkg:apk/wolfi/{name}@{version}?arch=x86_64&distro=wolfi-20230201"},
        ],
    }


class ApkoImage:
    """A pure APKO image, and the dist/ layout scripts/build_candidate.sh leaves for its x86_64 build."""

    def __init__(self, root: Path, *, declared: str = APKO_DECLARED, locked: str = "1.2.3-r4", shipped: str = ""):
        self.root = root
        self.context = root / "images/tool"
        self.context.mkdir(parents=True)
        self.metadata = self.context / "metadata.yaml"
        self.metadata.write_text(
            "name: tool\ntrack: wolfi\ndescription: Example.\nupstream: https://example.com/\nversions: [1]\n"
            f"enabled: true\n{declared}",
            encoding="utf-8",
        )
        (self.context / "apko.yaml").write_text("contents:\n  packages:\n    - tool\n", encoding="utf-8")
        lock = apko_lock(tool=locked, glibc="2.42-r6")
        (self.context / "apko.lock.json").write_text(lock, encoding="utf-8")
        build = root / "dist/tool"
        (build / "sbom").mkdir(parents=True)
        (build / "apko.lock.json").write_text(lock, encoding="utf-8")
        self.sbom = build / "sbom/sbom-amd64.spdx.json"
        document = sbom_fixture()
        document["packages"] = [apk_package("tool", shipped or locked), apk_package("glibc", "2.42-r6")]
        self.sbom.write_text(json.dumps(document), encoding="utf-8")

    def apply(self) -> str | None:
        original = scan_identity.ROOT
        scan_identity.ROOT = self.root.resolve()
        try:
            return scan_identity.apply_apko(self.sbom, [self.context])
        finally:
            scan_identity.ROOT = original

    def locators(self) -> dict[str, list[str]]:
        packages = json.loads(self.sbom.read_text(encoding="utf-8"))["packages"]
        return {p["SPDXID"]: [r["referenceLocator"] for r in p["externalRefs"]] for p in packages}


def check_apko_identity() -> None:
    with TemporaryDirectory() as directory:
        image = ApkoImage(Path(directory))
        assert image.apply() == (
            "images/tool: scanning declared identity cpe:2.3:a:example:tool, pkg:pypi/tool at 1.2.3 (tool 1.2.3-r4)"
        )
        locators = image.locators()
        assert locators["SPDXRef-Package-scan-identity-0"] == [
            "cpe:2.3:a:example:tool:1.2.3:*:*:*:*:*:*:*",
            "pkg:generic/tool@1.2.3",
        ]
        assert locators["SPDXRef-Package-scan-identity-1"] == ["pkg:pypi/tool@1.2.3"]
        # The apk Syft found stays; the declaration only adds the upstream identity next to it.
        assert "pkg:apk/wolfi/tool@1.2.3-r4?arch=x86_64&distro=wolfi-20230201" in locators["SPDXRef-Package-apk-tool"]
        injected = image.sbom.read_bytes()
        image.apply()
        assert image.sbom.read_bytes() == injected, "a second pass injected the identity twice"
    with TemporaryDirectory() as directory:
        # The fixture of an old, known-vulnerable build: the identity follows the locked version, so a
        # Grype scan matches the declared CPE at 3.0.6 (see the CONTRIBUTING.md confirmation step).
        image = ApkoImage(Path(directory), declared="scan-identity: [cpe:2.3:a:proxysql:proxysql]\nscan-package: tool\n",
                          locked="3.0.6-r0")
        image.apply()
        assert image.locators()["SPDXRef-Package-scan-identity-0"][0] == "cpe:2.3:a:proxysql:proxysql:3.0.6:*:*:*:*:*:*:*"
    with TemporaryDirectory() as directory:
        # NVD's erlang/otp: the CPE escapes the slash, the purl percent-encodes it.
        image = ApkoImage(Path(directory), declared="scan-identity: [cpe:2.3:a:erlang:erlang/otp]\nscan-package: tool\n",
                          locked="28.5.0.8-r0")
        image.apply()
        assert image.locators()["SPDXRef-Package-scan-identity-0"] == [
            "cpe:2.3:a:erlang:erlang\\/otp:28.5.0.8:*:*:*:*:*:*:*",
            "pkg:generic/erlang%2Fotp@28.5.0.8",
        ]
    with TemporaryDirectory() as directory:
        # A git snapshot is versioned as the release it was cut after.
        image = ApkoImage(Path(directory), locked="3.12.16_git20261030-r0")
        assert "at 3.12.16 (tool 3.12.16_git20261030-r0)" in str(image.apply())
    with TemporaryDirectory() as directory:
        # Wolfi package names may be capitalized (R).
        image = ApkoImage(Path(directory))
        for path in (image.metadata, image.context / "apko.lock.json", image.sbom.parent.parent / "apko.lock.json", image.sbom):
            path.write_text(path.read_text(encoding="utf-8").replace('"tool"', '"R"').replace("scan-package: tool", "scan-package: R")
                            .replace("pkg:apk/wolfi/tool@", "pkg:apk/wolfi/R@"), encoding="utf-8")
        assert gen_matrix.parse_metadata(image.metadata).scan_package == "R"
        assert "at 1.2.3 (R 1.2.3-r4)" in str(image.apply())
    with TemporaryDirectory() as directory:
        # Without the declaration the SBOM is the one Syft wrote, byte for byte.
        image = ApkoImage(Path(directory), declared="")
        before = image.sbom.read_bytes()
        assert image.apply() is None
        assert image.sbom.read_bytes() == before
    with TemporaryDirectory() as directory:
        # Another build (a melange image locks at build time) leaves a lock no opted-in image commits.
        image = ApkoImage(Path(directory))
        (image.sbom.parent.parent / "apko.lock.json").write_text(apko_lock(tool="1.2.3-r5"), encoding="utf-8")
        before = image.sbom.read_bytes()
        assert image.apply() is None
        assert image.sbom.read_bytes() == before
        (image.sbom.parent.parent / "apko.lock.json").unlink()
        assert image.apply() is None
    with TemporaryDirectory() as directory:
        # The lock alone does not name the image: another build name with the same lock is not this image.
        image = ApkoImage(Path(directory))
        (image.root / "dist/tool").rename(image.root / "dist/other")
        image.sbom = image.root / "dist/other/sbom/sbom-amd64.spdx.json"
        before = image.sbom.read_bytes()
        assert image.apply() is None
        assert image.sbom.read_bytes() == before
    with TemporaryDirectory() as directory:
        # An undeclared image built under the same name from a byte-identical lock never inherits the
        # declaration: the build is ambiguous and fails closed.
        image = ApkoImage(Path(directory))
        twin = image.root / "images/tool-twin"
        twin.mkdir()
        for name in ("apko.yaml", "apko.lock.json"):
            (twin / name).write_bytes((image.context / name).read_bytes())
        (twin / "metadata.yaml").write_text(
            image.metadata.read_text(encoding="utf-8").replace(APKO_DECLARED, ""), encoding="utf-8"
        )
        original = scan_identity.ROOT
        scan_identity.ROOT = image.root.resolve()
        try:
            scan_identity.apply_apko(image.sbom, [image.context, twin])
        except scan_identity.CoverageError as error:
            assert "do not declare the same scan identity" in str(error), error
        else:
            raise AssertionError("an undeclared twin received the declaration")
        finally:
            scan_identity.ROOT = original
    with TemporaryDirectory() as directory:
        # A disabled twin is never built, so it neither blocks nor shares the enabled image's declaration.
        image = ApkoImage(Path(directory))
        twin = image.root / "images/tool-twin"
        twin.mkdir()
        for name in ("apko.yaml", "apko.lock.json"):
            (twin / name).write_bytes((image.context / name).read_bytes())
        (twin / "metadata.yaml").write_text(
            image.metadata.read_text(encoding="utf-8")
            .replace(APKO_DECLARED, "")
            .replace("enabled: true", "enabled: false"),
            encoding="utf-8",
        )
        original = scan_identity.ROOT
        scan_identity.ROOT = image.root.resolve()
        try:
            assert "at 1.2.3 (tool 1.2.3-r4)" in str(scan_identity.apply_apko(image.sbom, [image.context, twin]))
            assert scan_identity.apply_apko(image.sbom, [twin]) is None
        finally:
            scan_identity.ROOT = original
    with TemporaryDirectory() as directory:
        # A flavor with its own APKO config builds as NAME-FLAVOR from its own lock.
        image = ApkoImage(Path(directory))
        image.metadata.write_text(image.metadata.read_text(encoding="utf-8") + "flavors: [plain, fips]\n", encoding="utf-8")
        (image.context / "fips.apko.yaml").write_text("contents:\n  packages:\n    - tool\n", encoding="utf-8")
        fips_lock = apko_lock(tool="1.2.4-r0", glibc="2.42-r6")
        (image.context / "fips.apko.lock.json").write_text(fips_lock, encoding="utf-8")
        build = image.root / "dist/tool-fips"
        (build / "sbom").mkdir(parents=True)
        (build / "apko.lock.json").write_text(fips_lock, encoding="utf-8")
        document = sbom_fixture()
        document["packages"] = [apk_package("tool", "1.2.4-r0")]
        image.sbom = build / "sbom/sbom-amd64.spdx.json"
        image.sbom.write_text(json.dumps(document), encoding="utf-8")
        assert "at 1.2.4 (tool 1.2.4-r0)" in str(image.apply())
    for shipped, message in (("1.2.3-r5", "does not lock"), ("", "expected one version")):
        with TemporaryDirectory() as directory:
            image = ApkoImage(Path(directory), shipped=shipped)
            if not shipped:
                document = json.loads(image.sbom.read_text(encoding="utf-8"))
                document["packages"] = document["packages"][1:]
                image.sbom.write_text(json.dumps(document), encoding="utf-8")
            try:
                image.apply()
            except scan_identity.CoverageError as error:
                assert message in str(error), error
            else:
                raise AssertionError(f"a drifted scan-package was accepted: {shipped!r}")


def check_apko_metadata_validation() -> None:
    def rejected(declared: str, *, locked: str = "1.2.3-r4", extra: dict[str, str] | None = None) -> str:
        with TemporaryDirectory() as directory:
            image = ApkoImage(Path(directory), declared=declared, locked=locked)
            for name, contents in (extra or {}).items():
                (image.context / name).write_text(contents, encoding="utf-8")
            try:
                gen_matrix.parse_metadata(image.metadata)
            except gen_matrix.MetadataError as error:
                return str(error)
            raise AssertionError(f"invalid pure APKO declaration accepted: {declared!r}")

    with TemporaryDirectory() as directory:
        metadata = gen_matrix.parse_metadata(ApkoImage(Path(directory)).metadata)
        assert (metadata.scan_identity, metadata.scan_package) == (("cpe:2.3:a:example:tool", "pkg:pypi/tool"), "tool")
    with TemporaryDirectory() as directory:
        assert gen_matrix.parse_metadata(ApkoImage(Path(directory), declared="").metadata).scan_package == ""
    assert "requires scan-package" in rejected("scan-identity: [cpe:2.3:a:example:tool]\n")
    assert "is not installed by apko.lock.json" in rejected(APKO_DECLARED.replace("scan-package: tool", "scan-package: other"))
    assert "only valid with scan-identity" in rejected("scan-package: tool\n")
    assert "only N-rN and N_gitDATE-rN" in rejected(APKO_DECLARED, locked="9.9_p1-r0")
    assert "is not installed by fips.apko.lock.json" in rejected(APKO_DECLARED, extra={"fips.apko.lock.json": apko_lock(glibc="2.42-r6")})
    one_arch = json.dumps({"contents": {"packages": [
        {"name": "tool", "architecture": "x86_64", "version": "1.2.3-r4"},
        {"name": "glibc", "architecture": "x86_64", "version": "2.42-r6"},
        {"name": "glibc", "architecture": "aarch64", "version": "2.42-r6"},
    ]}})
    assert "is not installed by fips.apko.lock.json for aarch64" in rejected(APKO_DECLARED, extra={"fips.apko.lock.json": one_arch})
    melange = {"melange.yaml": "package:\n  name: tool\n  version: 1.2.3\n"}
    assert "melange.yaml versions the identity" in rejected(APKO_DECLARED, extra=melange)
    assert "requires an image-local melange.yaml" in rejected(APKO_DECLARED, extra={"fips.melange.yaml": "package:\n"})


def check_apko_pipeline_contract() -> None:
    """apply_apko finds the build's lock next to its SBOM, before the gate scans and attests that SBOM."""
    build = (gen_matrix.ROOT / "scripts/build_candidate.sh").read_text(encoding="utf-8")
    assert 'output="dist/${build_name}"' in build
    assert 'cp "$lockfile" "${output}/apko.lock.json"' in build
    assert 'lockfile="${context}/apko.lock.json"' in build
    assert 'lockfile="${context}/${flavor}.apko.lock.json"' in build
    assert '"spdx-json=${output}/sbom/sbom-${arch}.spdx.json"' in build
    action = (gen_matrix.ROOT / ".github/actions/publish-image/action.yaml").read_text(encoding="utf-8")
    trim = action.index("python3 scripts/trim_sbom.py")
    assert '"${SBOM_DIRECTORY}/sbom-amd64.spdx.json"' in action[trim:]
    assert trim < action.index('grype "sbom:${SBOM}"'), "the gate scans the SBOM before the identity is injected"
    workflow = (gen_matrix.ROOT / ".github/workflows/build.yaml").read_text(encoding="utf-8")
    assert "sbom-directory: dist/${{ matrix.build_name }}/sbom" in workflow
    with TemporaryDirectory() as directory:
        # trim_sbom.py is the caller in production: it injects, then size-checks the same file.
        image = ApkoImage(Path(directory))
        with patch.object(gen_matrix, "ROOT", image.root), patch.object(scan_identity, "ROOT", image.root):
            assert trim_sbom.main([str(image.sbom)]) == 0
        assert "SPDXRef-Package-scan-identity-0" in image.locators()


def main() -> None:
    check_blind_spot_fails_closed()
    check_native_coverage()
    check_declared_identity()
    check_allowlist()
    check_metadata_validation()
    check_underscore_heavy_paths()
    check_repository_allowlist()
    check_apko_identity()
    check_apko_metadata_validation()
    check_apko_pipeline_contract()
    print("passed scripts/test_scan_identity.py")


if __name__ == "__main__":
    main()
