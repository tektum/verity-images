#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def pipeline_script(path: Path) -> str:
    return textwrap.dedent(path.read_text(encoding="utf-8").split("  - runs: |\n", 1)[1])






def load_checksum_updater():
    spec = importlib.util.spec_from_file_location(
        "update_release_asset_checksum", ROOT / "scripts/update_release_asset_checksum.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_checksum_updater(root: Path) -> None:
    updater = load_checksum_updater()
    recipe = root / "images/example/melange.yaml"
    recipe.parent.mkdir(parents=True)
    recipe.write_text(
        textwrap.dedent(
            """\
            package:
              version: "1.2.3"
            pipeline:
              - uses: fetch
                with:
                  uri: >-
                    https://github.com/example/project/releases/download/v${{package.version}}/project-${{package.version}}.tar.gz
                  expected-sha256: 0000000000000000000000000000000000000000000000000000000000000000
            """
        ),
        encoding="utf-8",
    )
    updater.ALLOWED_ASSETS = {"images/example/melange.yaml": ("example/project", "project-{version}.tar.gz")}
    payload = b"canonical release asset"

    class Response:
        def __init__(self, body: bytes) -> None:
            self.payload = body

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return None

        def read(self, _size: int) -> bytes:
            value, self.payload = self.payload, b""
            return value

    requested: list[str] = []

    def open_asset(url: str):
        requested.append(url)
        return Response(payload)

    checksum = updater.update(recipe, root, open_asset)
    assert checksum == hashlib.sha256(payload).hexdigest()
    assert requested == ["https://github.com/example/project/releases/download/v1.2.3/project-1.2.3.tar.gz"]
    updated = recipe.read_text(encoding="utf-8")
    assert f"expected-sha256: {checksum}" in updated
    assert "version: \"1.2.3\"" in updated

    source = updated.replace("github.com/example/project", "github.com/attacker/project")
    recipe.write_text(source, encoding="utf-8")
    try:
        updater.update(recipe, root, open_asset)
    except updater.ChecksumUpdateError:
        pass
    else:
        raise AssertionError("untrusted release URL was accepted")

    unsupported = root / "images/other/melange.yaml"
    unsupported.parent.mkdir(parents=True)
    unsupported.write_text(source, encoding="utf-8")
    try:
        updater.update(unsupported, root, open_asset)
    except updater.ChecksumUpdateError:
        pass
    else:
        raise AssertionError("unsupported recipe was accepted")


def test_corepack_install(root: Path) -> None:
    script = pipeline_script(ROOT / "pipelines/corepack/install.yaml").replace("${{inputs.directory}}", str(root / "ui"))
    ui = root / "ui"
    binaries = root / "corepack-bin"
    ui.mkdir()
    binaries.mkdir()
    log = root / "corepack.log"
    os.symlink(shutil.which("node") or "/usr/bin/node", binaries / "node")
    for command in ("corepack", "npm", "pnpm", "yarn"):
        executable(binaries / command, f"#!/bin/sh\nprintf '{command} %s\\n' \"$*\" >>\"$COREPACK_LOG\"\n")
    environment = os.environ | {"PATH": f"{binaries}:{os.environ['PATH']}", "COREPACK_LOG": str(log)}
    expected = {
        "npm@11.0.0": "corepack npm ci",
        "pnpm@10.0.0": "corepack pnpm install --frozen-lockfile",
        "yarn@1.22.22": "corepack yarn install --frozen-lockfile",
        "yarn@4.9.2": "corepack yarn install --immutable",
    }
    for declaration, install in expected.items():
        ui.joinpath("package.json").write_text(json.dumps({"packageManager": declaration}), encoding="utf-8")
        log.write_text("", encoding="utf-8")
        subprocess.run(["sh", "-eu", "-c", script], check=True, env=environment)
        calls = log.read_text(encoding="utf-8")
        assert f"corepack prepare {declaration} --activate" in calls
        assert install in calls
    for declaration in (None, "bun@1.2.0", "yarn@latest", "yarn"):
        ui.joinpath("package.json").write_text(json.dumps({"packageManager": declaration}), encoding="utf-8")
        result = subprocess.run(["sh", "-eu", "-c", script], env=environment, capture_output=True, text=True)
        assert result.returncode != 0, declaration


def test_renovate_configuration() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    managers = renovate["customManagers"]
    assert all(
        "go/bump" not in match
        for manager in managers
        for match in manager.get("matchStrings", [])
    )
    assert any(manager.get("datasourceTemplate") == "crate" and "--precise" in manager["matchStrings"][0] for manager in managers)
    source_manager = next(
        manager for manager in managers if manager.get("datasourceTemplate") == "git-tags" and "package\\.version" in manager["matchStrings"][0]
    )
    assert source_manager["managerFilePatterns"] == [r"/^images/.+/melange\.yaml$/"]

    image_rule = next(
        rule
        for rule in renovate["packageRules"]
        if rule.get("matchFileNames") == ["images/**/melange.yaml"] and "groupName" in rule
    )
    assert image_rule == {
        "matchFileNames": ["images/**/melange.yaml"],
        "groupName": "image {{packageFileDir}}",
        "groupSlug": "{{packageFileDir}}",
        "separateMajorMinor": False,
    }
    assert "matchUpdateTypes" not in image_rule
    assert all("postUpgradeTasks" not in rule for rule in renovate["packageRules"])

    go_get_manager = next(
        manager for manager in managers if "argo-workflows|gitlab-runner" in manager["managerFilePatterns"][0]
    )
    assert go_get_manager["matchStringsStrategy"] == "recursive"
    assert go_get_manager["matchStrings"][0].startswith(r"go get [\\]\n")
    assert "|velero)" in go_get_manager["managerFilePatterns"][0]
    grpc_floor_manager = next(
        manager
        for manager in managers
        if manager.get("depNameTemplate") == "google.golang.org/grpc"
    )
    grpc_floor_pattern = r'''google\.golang\.org/grpc@\$\{\{vars\.grpc-floor\}\}[\s\S]*?grpc-floor:\s*["']?(?<currentValue>v[^\s"']+)["']?'''
    assert grpc_floor_manager == {
        "customType": "regex",
        "managerFilePatterns": [r"/^images/(?:restic|velero)/melange\.yaml$/"],
        "matchStrings": [grpc_floor_pattern],
        "depNameTemplate": "google.golang.org/grpc",
        "datasourceTemplate": "go",
        "versioningTemplate": "semver",
    }
    floor_pattern = grpc_floor_manager["matchStrings"][0].replace(
        "(?<currentValue>", "(?P<currentValue>"
    )
    for declaration in (
        "grpc-floor: v1.83.2",
        'grpc-floor: "v1.83.2"',
        "grpc-floor: 'v1.83.2'",
    ):
        declaration = "go get google.golang.org/grpc@${{vars.grpc-floor}}\n" + declaration
        floor_match = re.search(floor_pattern, declaration)
        assert floor_match is not None
        assert floor_match.group("currentValue") == "v1.83.2"

    velero_recipe = (ROOT / "images/velero/melange.yaml").read_text(encoding="utf-8")
    assert re.search(floor_pattern, velero_recipe) is not None


def test_renovate_image_groups() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    image_rule = next(
        rule
        for rule in renovate["packageRules"]
        if rule.get("matchFileNames") == ["images/**/melange.yaml"] and "groupName" in rule
    )
    group_template = image_rule["groupName"]

    def group(path: str) -> str:
        package_file_dir = path.rsplit("/", 1)[0]
        return group_template.replace("{{packageFileDir}}", package_file_dir)

    source = group("images/alpha/melange.yaml")
    override = group("images/alpha/melange.yaml")
    sibling = group("images/beta/melange.yaml")
    nested = group("images/nested/1.0/melange.yaml")
    assert source == override
    assert source != sibling
    assert nested not in {source, sibling}
    assert nested.endswith("images/nested/1.0")


def test_renovate_major_brake() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    rules = renovate["packageRules"]
    assert renovate["automerge"] is True
    brake_index = next(
        index
        for index, rule in enumerate(rules)
        if rule.get("matchFileNames") == ["images/**/melange.yaml"]
        and rule.get("matchUpdateTypes") == ["major"]
    )
    brake = rules[brake_index]
    assert brake["automerge"] is False
    assert "review-required" in brake["addLabels"]
    # Source-image major updates remain reviewable instead of disappearing.
    assert "matchDatasources" not in brake
    assert "matchPackageNames" not in brake
    assert "enabled" not in brake
    go_override_brake = next(
        rule
        for rule in rules
        if rule.get("matchManagers") == ["custom.regex"]
        and rule.get("matchDatasources") == ["go"]
    )
    assert go_override_brake == {
        "description": (
            "A Go module major upgrade changes its import path and requires source migration. "
            "Do not rewrite explicit build overrides across module majors."
        ),
        "matchManagers": ["custom.regex"],
        "matchDatasources": ["go"],
        "matchUpdateTypes": ["major"],
        "enabled": False,
    }
    assert rules.index(go_override_brake) > brake_index
    assert all(
        rule.get("automerge") is not True
        for rule in rules[brake_index + 1 :]
        if rule.get("matchFileNames") in (None, ["images/**/melange.yaml"])
    )


def test_renovate_nested_stream_brake() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    rules = renovate["packageRules"]
    brake = next(
        rule
        for rule in rules
        if rule.get("matchFileNames") == ["images/*/*/melange.yaml"]
    )
    assert brake == {
        "description": (
            "A nested image directory owns a version stream. Keep patch updates automatic, "
            "but require human review before changing its minor or major stream."
        ),
        "matchFileNames": ["images/*/*/melange.yaml"],
        "matchUpdateTypes": ["minor", "major"],
        "automerge": False,
        "addLabels": ["image-stream-update", "review-required"],
    }
    major_brake = next(
        rule
        for rule in rules
        if rule.get("matchFileNames") == ["images/**/melange.yaml"]
        and rule.get("matchUpdateTypes") == ["major"]
    )
    nested_major_labels = set(brake["addLabels"]) | set(major_brake["addLabels"])
    assert nested_major_labels == {
        "image-major-update",
        "image-stream-update",
        "review-required",
    }
    cargo_brake = next(
        rule
        for rule in rules
        if rule.get("matchFileNames") == ["images/deno/melange.yaml"]
    )
    assert cargo_brake == {
        "description": (
            "Image-local Cargo remediation pins may advance within their current patch line, "
            "but dependency-stream changes require build review."
        ),
        "matchFileNames": ["images/deno/melange.yaml"],
        "matchManagers": ["custom.regex"],
        "matchDatasources": ["crate"],
        "matchUpdateTypes": ["minor", "major"],
        "enabled": False,
    }
    assert all("allowedVersions" not in rule for rule in rules)


def test_checksum_workflow() -> None:
    workflow = (ROOT / ".github/workflows/renovate-checksum.yaml").read_text(encoding="utf-8")
    assert "workflow_run:" in workflow
    assert "github.event.workflow_run.actor.login == 'renovate[bot]'" in workflow
    assert "github.event.workflow_run.head_repository.full_name == github.repository" in workflow
    assert "ref: ${{ github.event.workflow_run.head_sha }}" not in workflow
    assert "python3 scripts/update_release_asset_checksum.py \"$recipe\"" in workflow
    assert 'python3 scripts/update_go_release_checksums.py "$recipe"' in workflow
    assert '[[ -n "$PR_NUMBER" ]]' in workflow
    assert r"grep -E '^(images/traefik|images/go/[^/]+)/melange\.yaml$'" in workflow
    assert "    permissions:\n      contents: write\n      pull-requests: read\n" in workflow
    assert "repos/${REPOSITORY}/contents/${recipe}?ref=${HEAD_SHA}" in workflow
    assert "repos/${REPOSITORY}/contents/${recipe}" in workflow
    assert "contents: write" in workflow


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        test_checksum_updater(Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_corepack_install(Path(temporary))
    test_renovate_configuration()
    test_renovate_image_groups()
    test_renovate_major_brake()
    test_renovate_nested_stream_brake()
    test_checksum_workflow()
    print("passed scripts/test_renovate_helpers.py")


if __name__ == "__main__":
    main()
