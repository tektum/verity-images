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


def _render_template(template: str, groups: dict[str, str]) -> str:
    rendered = template
    for key, value in groups.items():
        rendered = rendered.replace("{{" + key + "}}", value)
    return rendered


def _extract(manager: dict, text: str) -> list[dict[str, str]]:
    found = []
    for raw_pattern in manager["matchStrings"]:
        pattern = raw_pattern.replace("(?<", "(?P<")
        for match in re.finditer(pattern, text):
            groups = match.groupdict()
            dep_name = groups.get("depName")
            if dep_name is None:
                dep_name = _render_template(manager["depNameTemplate"], groups)
            found.append({"depName": dep_name, "currentValue": groups["currentValue"]})
    return found


def test_renovate_configuration() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    managers = renovate["customManagers"]

    assert renovate["automerge"] is False
    assert renovate["platformAutomerge"] is False
    assert renovate["osvVulnerabilityAlerts"] is True
    assert all(manager["customType"] == "regex" for manager in managers)
    assert len(managers) == 12
    assert [manager["managerFilePatterns"] for manager in managers[:3]] == [
        [r"/^\.github/workflows/[^/]+\.ya?ml$/"],
        [r"/^\.github/workflows/[^/]+\.ya?ml$/"],
        [r"/^packages/repository-state\.json$/"],
    ]
    assert [manager["datasourceTemplate"] for manager in managers] == [
        "docker",
        "docker",
        "github-releases",
        "go",
        "go",
        "go",
        "go",
        "npm",
        "npm",
        "crate",
        "crate",
        "maven",
    ]

    assert renovate["packageRules"] == [
        {
            "matchFileNames": [".github/workflows/*.yaml"],
            "automerge": True,
            "platformAutomerge": True,
        },
        {
            "matchFileNames": ["packages/repository-state.json"],
            "automerge": False,
            "labels": ["apk-repository-state", "review-required"],
        },
        {
            "matchDatasources": ["go", "crate", "maven", "npm"],
            "enabled": False,
            "labels": ["security-floor", "review-required"],
        },
    ]

    # Every security-floor manager targets a vulnerability-monitored input
    # under images/, packages/, or patched/, and the disable rule scopes
    # exactly the four new datasources so existing docker/github-releases
    # automerge behavior stays untouched.
    security_managers = managers[3:]
    assert all(
        any(root in pattern for root in ("images/", "packages/", "patched/"))
        for manager in security_managers
        for pattern in manager["managerFilePatterns"]
    )
    assert {manager["datasourceTemplate"] for manager in security_managers} == {
        "go",
        "npm",
        "crate",
        "maven",
    }

    # Prove each regex actually extracts the expected dependency from the
    # real repository file it targets, so a typo fails loudly instead of
    # the manager silently never matching anything.
    expectations = [
        (3, "images/restic/melange.yaml", [{"depName": "google.golang.org/grpc", "currentValue": "v1.83.2"}]),
        (3, "packages/verity-restic-0.18/melange.yaml", [{"depName": "google.golang.org/grpc", "currentValue": "v1.83.2"}]),
        (3, "images/velero/melange.yaml", [{"depName": "google.golang.org/grpc", "currentValue": "v1.83.2"}]),
        (4, "packages/gosu/melange.yaml", [{"depName": "golang.org/x/sys", "currentValue": "v0.44.0"}]),
        (5, "patched/eck-operator/post-patch.Dockerfile", [{"depName": "github.com/google/cel-go", "currentValue": "v0.29.0"}]),
        (6, "patched/eck-operator/post-patch.Dockerfile", [{"depName": "google.golang.org/grpc", "currentValue": "v1.83.1"}]),
        (7, "patched/node-22-slim/post-patch.Dockerfile", [{"depName": "npm", "currentValue": "12.0.2"}]),
        (
            8,
            "patched/node-22-slim/post-patch.Dockerfile",
            [
                {"depName": "ip-address", "currentValue": "10.3.1"},
                {"depName": "undici", "currentValue": "6.28.0"},
            ],
        ),
        (
            9,
            "images/bat/melange.yaml",
            [
                {"depName": "plist", "currentValue": "1.10.0"},
                {"depName": "git2", "currentValue": "0.21.0"},
            ],
        ),
        (
            10,
            "images/deno/melange.yaml",
            [
                {"depName": "rand", "currentValue": "0.8.6"},
                {"depName": "quinn-proto", "currentValue": "0.11.17"},
            ],
        ),
        (10, "images/vector/melange.yaml", [{"depName": "tonic", "currentValue": "0.12.3"}]),
        (
            11,
            "images/cassandra/melange.yaml",
            [
                {"depName": "at.yawk.lz4:lz4-java", "currentValue": "1.11.1"},
                {"depName": "ch.qos.logback:logback-classic", "currentValue": "1.5.34"},
                {"depName": "ch.qos.logback:logback-core", "currentValue": "1.5.34"},
                {"depName": "com.fasterxml.jackson.core:jackson-annotations", "currentValue": "2.21"},
                {"depName": "com.fasterxml.jackson.core:jackson-core", "currentValue": "2.21.5"},
                {"depName": "com.fasterxml.jackson.core:jackson-databind", "currentValue": "2.21.5"},
                {"depName": "io.netty:netty-all", "currentValue": "4.1.136.Final"},
                {"depName": "io.netty:netty-transport-native-epoll", "currentValue": "4.1.136.Final"},
            ],
        ),
    ]
    for index, relative_path, expected in expectations:
        text = (ROOT / relative_path).read_text(encoding="utf-8")
        assert _extract(managers[index], text) == expected, relative_path




def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        test_checksum_updater(Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_corepack_install(Path(temporary))
    test_renovate_configuration()
    print("passed scripts/test_renovate_helpers.py")


if __name__ == "__main__":
    main()
