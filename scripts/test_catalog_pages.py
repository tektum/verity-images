#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_catalog_pages.py

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path
from typing import Final

import validate_repository_state


ROOT: Final = Path(__file__).resolve().parents[1]
WORKFLOW: Final = ROOT / ".github/workflows/catalog.yaml"
STATE: Final = ROOT / "packages/repository-state.json"


def archive(root: Path, output: Path, name: str = "apk") -> None:
    subprocess.run(
        ["tar", "--zstd", "--sort=name", "-C", str(root), "-cf", str(output), name],
        check=True,
    )


def fixture(root: Path, state: dict[str, object]) -> Path:
    for member in validate_repository_state.archive_paths(state):
        target = root / member
        if member == "apk" or member.endswith(tuple(validate_repository_state.ARCHITECTURES)):
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(member, encoding="utf-8")
    output = root / "repository.tar.zst"
    archive(root, output)
    return output


def rejects_unsafe_archive(state: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        archive_path = fixture(root, state)
        validate_repository_state.validate_archive_members(state, archive_path)
        (root / "apk" / "unexpected").write_text("bad", encoding="utf-8")
        archive(root, archive_path)
        try:
            validate_repository_state.validate_archive_members(state, archive_path)
        except validate_repository_state.StateError:
            return
    raise AssertionError("unsafe archive was accepted")


def rejects_link_or_wrong_root(state: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        archive_path = fixture(root, state)
        package_state = next(
            package
            for package in validate_repository_state.entries(state["packages"], "packages")
            if package["architecture"] == "x86_64"
        )
        package = root / "apk" / validate_repository_state.text(
            package_state["path"], "package.path"
        )
        package.unlink()
        package.symlink_to("../../outside")
        archive(root, archive_path)
        try:
            validate_repository_state.validate_archive_members(state, archive_path)
        except validate_repository_state.StateError:
            pass
        else:
            raise AssertionError("archive link was accepted")
        package.unlink()
        package.write_text("package", encoding="utf-8")
        (root / "apk").rename(root / "other")
        archive(root, archive_path, "other")
        try:
            validate_repository_state.validate_archive_members(state, archive_path)
        except validate_repository_state.StateError:
            return
    raise AssertionError("unexpected archive root was accepted")


def stages_only_expected_files(state: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        archive_path = fixture(root, state)
        pages = root / "pages"
        validate_repository_state.stage_archive(state, archive_path, pages)
        assert (pages / "apk" / "manifest.json").read_text(encoding="utf-8") == "apk/manifest.json"
        assert (pages / "apk" / "verity-apk-2026.rsa.pub").read_bytes() == (
            ROOT / "packages/keys/verity-apk-2026.rsa.pub"
        ).read_bytes()
        assert not (pages / "apk" / "unexpected").exists()


def rejects_existing_staged_architecture(state: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        archive_path = fixture(root, state)
        pages = root / "pages"
        validate_repository_state.stage_archive(state, archive_path, pages)
        try:
            validate_repository_state.stage_archive(state, archive_path, pages)
        except validate_repository_state.StateError:
            return
    raise AssertionError("existing staged architecture was not rejected as StateError")


def reports_live_lookup_timeout(state: dict[str, object]) -> None:
    original_run = validate_repository_state.subprocess.run

    def timeout(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(["gh", "api"], 1)

    validate_repository_state.subprocess.run = timeout
    try:
        validate_repository_state.validate_live(state)
    except validate_repository_state.StateError:
        return
    finally:
        validate_repository_state.subprocess.run = original_run
    raise AssertionError("live lookup timeout was not reported as StateError")


def workflow_modes() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert "  push:\n    branches: [main]\n    paths:\n" in workflow
    assert "github.event_name == 'push'" in workflow
    assert "      - packages/repository-state.json\n" in workflow
    assert "      - packages/repository-state.pin.json\n" in workflow
    assert "        options: [images, packages, combined]\n" in workflow
    assert "      - name: Select publication mode\n" in workflow
    assert "mode=images" in workflow
    assert "mode=packages" in workflow
    assert "steps.mode.outputs.value != 'packages'" in workflow
    assert "steps.mode.outputs.value == 'packages'" in workflow
    assert "Package-only publication requires the current catalog" in workflow
    assert "No changed images in build run" in workflow
    assert "mkdir pages" in workflow
    assert "cp catalog.json pages/catalog.json" in workflow
    assert "cp docs/catalog.schema.json pages/catalog.schema.json" in workflow
    assert workflow.count("actions/upload-pages-artifact@") == 1
    assert workflow.count("actions/deploy-pages@") == 1
    assert "releases/assets/${asset_id}" in workflow
    assert "validate_repository_state.py --live" in workflow
    assert "validate_repository_state.py --archive repository.tar.zst --pages pages" in workflow


def main() -> None:
    state = validate_repository_state.read_state(STATE)
    rejects_unsafe_archive(state)
    rejects_link_or_wrong_root(state)
    stages_only_expected_files(state)
    rejects_existing_staged_architecture(state)
    reports_live_lookup_timeout(state)
    workflow_modes()


if __name__ == "__main__":
    main()
