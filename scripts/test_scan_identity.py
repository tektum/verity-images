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

import gen_matrix
import scan_identity

# The allowlist may only shrink. Never add a context here: declare scan-identity or stamp
# the Go main module version instead. Delete a line once its image leaves the allowlist.
FROZEN_BASELINE: Final = frozenset(
    f"images/{name}"
    for name in (
        "argo-events aws-node-termination-handler cassandra cert-manager-acmesolver cert-manager-cainjector "
        "cert-manager-controller cert-manager-startupapicheck cert-manager-webhook clickhouse cmake cmctl "
        "configmap-reload coredns elixir/1.17 elixir/1.19 envoy external-secrets falcoctl falcosidekick "
        "fluent-bit flux-cli/2.10 flux-cli/2.8 flux-cli/2.9 flux-helm-controller "
        "gradle haproxy haproxy-ingress jenkins kube-state-metrics kubernetes-reflector mariadb/12.3 "
        "metallb-speaker metrics-server mysql/9.7 nodejs/22 perl/5.42 pgbouncer postgres/17 sonar-scanner-cli "
        "source-controller tekton-controller trust-manager valkey victoria-metrics vmagent zookeeper"
    ).split()
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
        self.allowlist = root / "allowlist.txt"
        self.allowlist.write_text("", encoding="utf-8")

    def apply(self) -> str:
        return scan_identity.apply(self.context, self.recipe, self.sbom, self.syft, self.allowlist)

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
        key = image.context.as_posix()
        image.allowlist.write_text(f"# note\n\n{key} identity\n", encoding="utf-8")
        assert "ALLOWLISTED" in image.apply()
        assert json.loads(image.sbom.read_text(encoding="utf-8")) == sbom_fixture()
    with TemporaryDirectory() as directory:
        image = Image(Path(directory), [module("example.com/tool", "v1.2.3")])
        image.allowlist.write_text(f"{image.context.as_posix()} go-version\n", encoding="utf-8")
        assert "stale allowlist entry" in image.apply()
    for text in ("images/a\n", "images/a unknown\n", "images/a identity\nimages/a go-version\n", "a b c\n"):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "list.txt"
            path.write_text(text, encoding="utf-8")
            try:
                scan_identity.read_allowlist(path)
            except scan_identity.CoverageError:
                continue
            raise AssertionError(f"malformed allowlist accepted: {text!r}")


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


def check_repository_allowlist() -> None:
    listed = scan_identity.read_allowlist(scan_identity.ALLOWLIST)
    assert set(listed) <= FROZEN_BASELINE, f"allowlist grew: {sorted(set(listed) - FROZEN_BASELINE)}"
    for context in listed:
        directory = gen_matrix.ROOT / context
        metadata = gen_matrix.parse_metadata(directory / "metadata.yaml")
        assert (directory / "melange.yaml").is_file(), f"{context}: allowlisted without an image-local recipe"
        assert metadata.enabled, f"{context}: allowlisted while disabled"
        assert not metadata.scan_identity, f"{context}: declares scan-identity, delete its allowlist entry"


def main() -> None:
    check_blind_spot_fails_closed()
    check_native_coverage()
    check_declared_identity()
    check_allowlist()
    check_metadata_validation()
    check_repository_allowlist()
    print("passed scripts/test_scan_identity.py")


if __name__ == "__main__":
    main()
