from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path
from unittest.mock import patch

import compose_apk_inputs
from apk_test_fixtures import unsigned_package
from test_apk_repository import payload, repository, sign


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLE = ROOT / ".github/scripts/assemble-apk-repository.sh"
FINGERPRINT = "764c84bdcf9ca8530146da9976d4cac4b37ba961ad258d589e9a11fb05206698"
ARCHITECTURES = ("aarch64", "x86_64")
A = "openssl-fips-provider"
B = "openssl-fips-provider-extra"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def attested(name: str, architecture: str, bundle: Path) -> dict[str, str | int]:
    return {
        "type": "attested-build",
        "sourceCommit": "1" * 40,
        "buildWorkflowId": 1,
        "buildRunId": 2,
        "buildArtifactId": 3,
        "buildArtifactSha256": "sha256:" + "4" * 64,
        "unsignedSha256": "5" * 64,
        "signingWorkflowId": 6,
        "signingRunId": 7,
        "bundlePath": f"bundles/{name}/{architecture}.json",
        "bundleSha256": digest(bundle),
    }


def base_snapshot(root: Path, schema_version: int = 2) -> tuple[Path, Path]:
    base = root / "base"
    repository(base)
    if schema_version == 1:
        for architecture in ARCHITECTURES:
            (base / architecture / f"{B}-3.1.2-r3.apk").unlink()
    packages: list[dict[str, str | int | dict[str, str | int]]] = []
    for architecture in ARCHITECTURES:
        for name in ((A, B) if schema_version == 2 else (A,)):
            package = base / architecture / f"{name}-3.1.2-r3.apk"
            entry: dict[str, str | int | dict[str, str | int]] = {
                "architecture": architecture,
                "name": name,
                "version": "3.1.2-r3",
                "epoch": 3,
                "path": package.relative_to(base).as_posix(),
                "sha256": digest(package),
            }
            if schema_version == 2:
                bundle = base / "bundles" / name / f"{architecture}.json"
                bundle.parent.mkdir(parents=True, exist_ok=True)
                bundle.write_text(json.dumps({"name": name, "architecture": architecture}), encoding="utf-8")
                entry["origin"] = attested(name, architecture, bundle)
            packages.append(entry)
    packages.sort(key=lambda entry: (str(entry["name"]), str(entry["architecture"])))
    manifest_packages = copy.deepcopy(packages)
    if schema_version == 1:
        manifest_packages = [
            {key: entry[key] for key in ("architecture", "path", "sha256")}
            for entry in packages
        ]
    manifest = {
        **({"schemaVersion": 2} if schema_version == 2 else {}),
        "architectures": list(ARCHITECTURES),
        "fingerprint": FINGERPRINT,
        "packages": manifest_packages,
    }
    manifest_path = base / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
    state = {
        "schemaVersion": schema_version,
        "repository": "tektum/verity-images",
        "release": {"id": 1, "tag": "apk-repo-v0002", "targetCommit": "1" * 40, "immutable": True},
        "asset": {"id": 2, "name": "verity-apk-repository.tar.zst", "sha256": "sha256:" + "2" * 64},
        "archive": {
            "root": "apk",
            "sha256": "sha256:" + "2" * 64,
            "manifestSha256": digest(manifest_path),
            "manifest": manifest,
        },
        "key": {"path": "packages/keys/verity-apk-2026.rsa.pub", "fingerprint": FINGERPRINT},
        "packages": packages,
    }
    state_path = root / "state.json"
    state_path.write_text(json.dumps(state), encoding="utf-8")
    return state_path, base


def replacement(root: Path, key: Path) -> Path:
    packages = []
    for architecture in ARCHITECTURES:
        package = root / "replacement" / architecture / f"{A}-3.1.2-r3.apk"
        package.parent.mkdir(parents=True, exist_ok=True)
        package.write_bytes(unsigned_package(architecture, payload(architecture), extra="pkgdesc = replacement\n"))
        with (root / "signing.log").open("a", encoding="utf-8") as signing_log:
            signing_log.write(f"sign {package}\n")
        sign(package, key)
        bundle = root / "replacement" / "bundles" / A / f"{architecture}.json"
        bundle.parent.mkdir(parents=True, exist_ok=True)
        bundle.write_text(json.dumps({"signed": package.name, "architecture": architecture}), encoding="utf-8")
        packages.append(
            {
                "architecture": architecture,
                "name": A,
                "version": "3.1.2-r3",
                "epoch": 3,
                "path": f"{architecture}/{package.name}",
                "sha256": digest(package),
                "sourceFile": str(package),
                "bundleFile": str(bundle),
                "origin": attested(A, architecture, bundle),
            }
        )
    metadata = root / "replacement.json"
    metadata.write_text(
        json.dumps({"schemaVersion": 1, "releaseTag": "apk-repo-v0003", "replacement": {"name": A, "packages": packages}}),
        encoding="utf-8",
    )
    return metadata


def compose(root: Path, schema_version: int = 2) -> tuple[Path, Path, Path]:
    state, base = base_snapshot(root, schema_version)
    metadata = replacement(root, base / "fixture.rsa") if schema_version == 2 else root / "migration.json"
    if schema_version == 1:
        metadata.write_text(json.dumps({"schemaVersion": 1, "releaseTag": "apk-repo-v0003", "replacement": None}), encoding="utf-8")
    output = root / "composed"
    compose_apk_inputs.compose(state, base, metadata, output)
    return base, output, metadata


def happy_paths() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, output, _ = compose(root)
        final = json.loads((output / "metadata.json").read_text(encoding="utf-8"))
        assert {(entry["name"], entry["architecture"]) for entry in final["packages"]} == {
            (name, architecture) for name in (A, B) for architecture in ARCHITECTURES
        }
        for architecture in ARCHITECTURES:
            reused = f"{architecture}/{B}-3.1.2-r3.apk"
            assert (base / reused).read_bytes() == (output / reused).read_bytes()
            bundle = f"bundles/{B}/{architecture}.json"
            assert (base / bundle).read_bytes() == (output / bundle).read_bytes()
        comparisons = json.loads((output / "reuse-comparisons.json").read_text(encoding="utf-8"))["members"]
        assert len(comparisons) == 4 and all(entry["byteIdentical"] for entry in comparisons)
        signing_commands = (root / "signing.log").read_text().splitlines()
        assert len(signing_commands) == 2 and all(command.startswith("sign ") and A in command and B not in command for command in signing_commands)

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        base, output, _ = compose(root, 1)
        assert not list(output.glob("bundles/**/*.json"))
        for architecture in ARCHITECTURES:
            path = f"{architecture}/{A}-3.1.2-r3.apk"
            assert (base / path).read_bytes() == (output / path).read_bytes()
        assert all(entry["origin"]["type"] == "legacy-snapshot" for entry in json.loads((output / "metadata.json").read_text())["packages"])


def failure_paths() -> None:
    mutations = (
        lambda value: value["replacement"]["packages"].pop(),
        lambda value: value.update({"replacement": None}),
        lambda value: value.update({"releaseTag": "apk-repo-v0004"}),
    )
    for mutate in mutations:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state, base = base_snapshot(root)
            metadata = replacement(root, base / "fixture.rsa")
            value = json.loads(metadata.read_text())
            mutate(value)
            metadata.write_text(json.dumps(value))
            try:
                compose_apk_inputs.compose(state, base, metadata, root / "output")
            except compose_apk_inputs.ComposeError:
                assert not (root / "output").exists()
            else:
                raise AssertionError("invalid composition was accepted")

def undeclared_base_package_fails() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, base = base_snapshot(root)
        metadata = replacement(root, base / "fixture.rsa")
        (base / "x86_64" / "undeclared-C.apk").write_bytes(b"C")
        try:
            compose_apk_inputs.compose(state, base, metadata, root / "output")
        except compose_apk_inputs.ComposeError as error:
            assert str(error) == "base package set mismatch"
        else:
            raise AssertionError("undeclared base package was accepted")


def missing_base_provenance_fails() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, base = base_snapshot(root)
        metadata = replacement(root, base / "fixture.rsa")
        (base / "bundles" / B / "aarch64.json").unlink()
        try:
            compose_apk_inputs.compose(state, base, metadata, root / "output")
        except compose_apk_inputs.ComposeError as error:
            assert str(error) == "base provenance set mismatch"
        else:
            raise AssertionError("missing base provenance was accepted")


def mutation_after_copy_fails() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, base = base_snapshot(root)
        metadata = replacement(root, base / "fixture.rsa")
        original = shutil.copyfile

        def mutating_copy(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> str | os.PathLike[str]:
            result = original(source, target)
            source_path = Path(source)
            if source_path.name == f"{B}-3.1.2-r3.apk" and source_path.parent.name == "x86_64":
                source_path.write_bytes(source_path.read_bytes() + b"changed")
            return result

        with patch.object(compose_apk_inputs.shutil, "copyfile", side_effect=mutating_copy):
            try:
                compose_apk_inputs.compose(state, base, metadata, root / "output")
            except compose_apk_inputs.ComposeError:
                assert not (root / "output").exists()
            else:
                raise AssertionError("base mutation after copy was accepted")


def interruption_after_publication_cleans_output() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state, base = base_snapshot(root)
        metadata = replacement(root, base / "fixture.rsa")
        output = root / "output"
        original_rename = Path.rename

        def rename_then_interrupt(source: Path, target: str | os.PathLike[str]) -> Path:
            original_rename(source, target)
            raise compose_apk_inputs.ComposeError("interrupted after publication")

        with patch.object(Path, "rename", autospec=True, side_effect=rename_then_interrupt):
            try:
                compose_apk_inputs.compose(state, base, metadata, output)
            except compose_apk_inputs.ComposeError as error:
                assert str(error) == "interrupted after publication"
            else:
                raise AssertionError("publication interruption was accepted")
        assert not output.exists()
        assert not list(root.glob(".output.*"))
        compose_apk_inputs.compose(state, base, metadata, output)
        assert output.is_dir()


def main() -> None:
    happy_paths()
    failure_paths()
    undeclared_base_package_fails()
    missing_base_provenance_fails()
    mutation_after_copy_fails()
    interruption_after_publication_cleans_output()


if __name__ == "__main__":
    main()
