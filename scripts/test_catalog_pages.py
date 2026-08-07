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
RUNBOOK: Final = ROOT / "docs/APK_REPOSITORY_STATE.md"
SIGNING_RUNBOOK: Final = ROOT / "docs/APK_REPOSITORY_SIGNING.md"
SIZE_CHECKER: Final = ROOT / "scripts/check_pages_size.py"
PAGES_LIMIT: Final = 900 * 1024 * 1024


def archive(root: Path, output: Path, name: str = "apk") -> None:
    subprocess.run(
        ["tar", "--zstd", "--sort=name", "-C", str(root), "-cf", str(output), name],
        check=True,
    )


def fixture(root: Path, state: dict[str, object]) -> Path:
    members = validate_repository_state.archive_paths(state)
    directories = {member for member in members if any(other.startswith(f"{member}/") for other in members)}
    for member in members:
        target = root / member
        if member in directories:
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
    assert "python3 scripts/check_pages_size.py pages" in workflow
    assert workflow.index("python3 scripts/check_pages_size.py pages") < workflow.index(
        "actions/upload-pages-artifact@"
    )


def rejects_oversized_pages_tree() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pages = Path(temporary)
        accepted = subprocess.run(
            ["python3", str(SIZE_CHECKER), str(pages)], capture_output=True, check=False
        )
        if accepted.returncode:
            raise AssertionError("Pages size checker rejected an empty tree")
        with (pages / "oversized").open("wb") as oversized:
            oversized.truncate(PAGES_LIMIT + 1)
        rejected = subprocess.run(
            ["python3", str(SIZE_CHECKER), str(pages)], capture_output=True, check=False
        )
        if not rejected.returncode:
            raise AssertionError("Pages size checker accepted a tree larger than 900 MiB")


def runbook_rejects_source_mismatch_under_optimization() -> None:
    snippet = RUNBOOK.read_text(encoding="utf-8").split("<<'PY'\n", maxsplit=1)[1].split(
        "\nPY\n", maxsplit=1
    )[0]
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state = root / "state.json"
        release = root / "release.json"
        state.write_text('{"release":{"targetCommit":"old"}}', encoding="utf-8")
        release.write_text("{}", encoding="utf-8")
        result = subprocess.run(
            ["python3", "-O", "-c", snippet, "archive", str(state), str(release), str(root / "pages"), "new"],
            capture_output=True,
            text=True,
            check=False,
            env={"PYTHONPATH": str(ROOT / "scripts")},
        )
        if result.returncode == 0 or "recovery check failed: source commit" not in result.stderr:
            raise AssertionError("optimized runbook did not fail closed on a source mismatch")


def runbooks_keep_key_recovery_safe() -> None:
    state_runbook = RUNBOOK.read_text(encoding="utf-8")
    assert "scripts/devbox.sh run -- check-jsonschema --schemafile \"$work/state.schema.json\"" in state_runbook
    signing_runbook = SIGNING_RUNBOOK.read_text(encoding="utf-8").split(
        "## Rotation and revocation\n", maxsplit=1
    )[1]
    steps = (
        "Pause publication",
        "encrypted backup",
        "Merge PR 1",
        "excluding both state-contract files",
        "Replace the protected environment secret",
        "run the protected smoke",
        "Publish and verify a new immutable release",
        "Merge PR 2 that updates both state-contract files",
        "Wait for Pages and downstream consumers",
        "Resume publication",
        "revoke the old key later",
    )
    positions = [signing_runbook.index(step) for step in steps]
    assert positions == sorted(positions)


def main() -> None:
    state = validate_repository_state.read_state(STATE)
    rejects_unsafe_archive(state)
    rejects_link_or_wrong_root(state)
    stages_only_expected_files(state)
    rejects_existing_staged_architecture(state)
    reports_live_lookup_timeout(state)
    workflow_modes()
    rejects_oversized_pages_tree()
    runbook_rejects_source_mismatch_under_optimization()
    runbooks_keep_key_recovery_safe()


if __name__ == "__main__":
    main()
