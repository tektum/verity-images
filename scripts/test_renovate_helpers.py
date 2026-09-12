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
            entry = {"depName": dep_name, "currentValue": groups["currentValue"]}
            if groups.get("versioning"):
                entry["versioning"] = groups["versioning"]
            found.append(entry)
    return found


def test_renovate_configuration() -> None:
    renovate = json.loads((ROOT / "renovate.json").read_text(encoding="utf-8"))
    managers = renovate["customManagers"]

    assert renovate["automerge"] is False
    assert renovate["platformAutomerge"] is False
    assert renovate["osvVulnerabilityAlerts"] is True
    # vulnerabilityAlerts.enabled defaults to True in Renovate already, but is
    # explicit because an OSV-generated rule uses force.enabled to override the
    # disabled ordinary update types. Scoping enabled=false to update types is
    # essential: UpdateTypesMatcher does not match during pre-lookup, so security
    # floors remain visible in the dependency dashboard and eligible for OSV.
    assert renovate["vulnerabilityAlerts"] == {"enabled": True}
    assert all(manager["customType"] == "regex" for manager in managers)
    assert len(managers) == 4
    assert [manager["managerFilePatterns"] for manager in managers] == [
        [r"/^\.github/workflows/[^/]+\.ya?ml$/"],
        [r"/^\.github/workflows/[^/]+\.ya?ml$/"],
        [r"/^packages/repository-state\.json$/"],
        [r"/^images/.+$/", r"/^packages/.+$/", r"/^patched/.+$/"],
    ]
    assert [manager.get("datasourceTemplate") for manager in managers] == [
        "docker",
        "docker",
        "github-releases",
        None,
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
            "matchFileNames": [
                "images/**",
                "packages/**",
                "patched/**",
                "!packages/repository-state.json",
            ],
            "matchUpdateTypes": [
                "major",
                "minor",
                "patch",
                "pin",
                "digest",
                "pinDigest",
                "lockFileMaintenance",
                "rollback",
                "replacement",
            ],
            "enabled": False,
            "automerge": True,
            "platformAutomerge": True,
            "labels": ["security-floor", "review-required"],
        },
    ]
    # packages/** would otherwise also match packages/repository-state.json,
    # silently disabling the apk-repo-state release manager's own
    # automerge=false/review-required rule above (Renovate's negative-match
    # array semantics: "!pattern" excludes it from this rule regardless of
    # the positive packages/** match).
    security_rule = renovate["packageRules"][2]
    assert "!packages/repository-state.json" in security_rule["matchFileNames"]

    # The single security-floor manager has no depNameTemplate/datasourceTemplate:
    # every dependency identity comes from the inline `# renovate: datasource=...
    # depName=...` comment itself, so a new floor in any file under images/,
    # packages/, or patched/ is picked up without ever touching this config again.
    floor_manager = managers[3]
    assert "depNameTemplate" not in floor_manager
    assert "datasourceTemplate" not in floor_manager

    # Prove the one regex actually extracts the expected dependency from every
    # annotation shape a recipe can use: a YAML `vars:` scalar, a Dockerfile
    # `ARG`, and a quoted value with a trailing comma and version qualifier
    # (embedded Python dict literal); that an optional `versioning=` override
    # is captured when present; and that unannotated version-looking text is
    # correctly ignored.
    #
    # The override matters concretely for crate deps: Renovate's default
    # "cargo" versioning treats a bare pin like the current rand floor,
    # 0.8.6, as an implicit `^0.8.6` range, so it silently reports
    # currentVersion 0.8.8 (the newest 0.8.x release) instead of 0.8.6 -- and
    # OSV vulnerability matching reads currentVersion before currentValue.
    # A still-vulnerable 0.8.6 floor would then look already patched. Every
    # crate annotation must add `versioning=semver` so currentVersion echoes
    # the literal pinned value.
    fixtures = [
        (
            "  grpc-floor: v1.83.2  # renovate: datasource=go depName=google.golang.org/grpc\n",
            [{"depName": "google.golang.org/grpc", "currentValue": "v1.83.2"}],
        ),
        (
            "ARG NPM_VERSION=12.0.2  # renovate: datasource=npm depName=npm\n",
            [{"depName": "npm", "currentValue": "12.0.2"}],
        ),
        (
            '      ("io.netty", "netty-all"): "4.1.136.Final",  '
            "# renovate: datasource=maven depName=io.netty:netty-all\n",
            [{"depName": "io.netty:netty-all", "currentValue": "4.1.136.Final"}],
        ),
        (
            "  rand-floor: 0.8.6  "
            "# renovate: datasource=crate depName=rand versioning=semver\n",
            [{"depName": "rand", "currentValue": "0.8.6", "versioning": "semver"}],
        ),
        (
            "  source-commit: 7d0aa7f2e30546fba7c8f1c0bae4d6704e3d8423\n"
            "  plain-version: v1.83.2\n",
            [],
        ),
        (
            # Regression: a trailing digit in an unrelated field name (here
            # the "0" in "sealed-secrets-0") followed by an unrelated,
            # non-trailing `# renovate:` comment on the *next* line must not
            # be paired up across the line break. This is real content --
            # images/sealed-secrets/melange.yaml has exactly this shape for
            # its own package.version tracking, unrelated to security
            # floors. A permissive `\\s*` separator here would misread
            # "sealed-secrets-0" as currentValue "0".
            "package:\n"
            "  name: sealed-secrets-0\n"
            "  # renovate: datasource=github-tags depName=bitnami/sealed-secrets"
            " versioning=semver-coerced\n"
            '  version: "0.39.1"\n',
            [],
        ),
    ]
    for text, expected in fixtures:
        assert _extract(floor_manager, text) == expected, text


def test_self_hosted_renovate() -> None:
    global_config = json.loads(
        (ROOT / ".github/renovate-global.json").read_text(encoding="utf-8")
    )
    assert global_config == {
        "$schema": "https://docs.renovatebot.com/renovate-global-schema.json",
        "platform": "github",
        "repositories": ["tektum/verity-images"],
        "configFileNames": [".github/renovate-apk.json"],
        "onboarding": False,
        "requireConfig": "required",
        "allowedCommands": [r"^scripts/renovate_refresh_apko_locks\.sh$"],
        "allowShellExecutorForPostUpgradeCommands": False,
    }

    apk = json.loads((ROOT / ".github/renovate-apk.json").read_text(encoding="utf-8"))
    assert apk["dependencyDashboard"] is False
    assert apk["branchPrefix"] == "renovate-apk/"
    assert apk["enabledManagers"] == ["custom.regex"]
    assert len(apk["customManagers"]) == 1
    apk_manager = apk["customManagers"][0]
    assert apk_manager["managerFilePatterns"] == [r"/^images\/.+\/apko\.yaml$/"]
    assert apk_manager["datasourceTemplate"] == "apk"
    assert apk_manager["registryUrlTemplate"] == "https://packages.wolfi.dev/os?arch=x86_64"
    assert _extract(
        apk_manager,
        "contents:\n  packages:\n    - mosquitto=2.0.22-r5\n    - mosquitto-clients=2.0.22-r5\n",
    ) == [
        {"depName": "mosquitto", "currentValue": "2.0.22-r5"},
        {"depName": "mosquitto-clients", "currentValue": "2.0.22-r5"},
    ]
    update_rule, major_brake = apk["packageRules"]
    assert update_rule["matchDatasources"] == ["apk"]
    assert update_rule["enabled"] is True
    assert update_rule["automerge"] is False
    assert update_rule["postUpgradeTasks"] == {
        "commands": ["scripts/renovate_refresh_apko_locks.sh"],
        "fileFilters": ["images/**/apko.lock.json"],
        "executionMode": "branch",
    }
    assert major_brake["matchUpdateTypes"] == ["major"]
    assert major_brake["enabled"] is False

    workflow = (ROOT / ".github/workflows/renovate.yaml").read_text(encoding="utf-8")
    assert '    - cron: "17 * * * *"' in workflow
    assert "  workflow_dispatch:" in workflow
    assert "  group: renovate\n  cancel-in-progress: false" in workflow
    assert "github.repository == 'tektum/verity-images'" in workflow
    assert "github.ref == 'refs/heads/main'" in workflow
    assert "persist-credentials: false" in workflow
    assert "scripts/install_renovate_apko.sh" in workflow
    assert "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1" in workflow
    assert "app-id: ${{ secrets.APP_ID }}" in workflow
    assert "private-key: ${{ secrets.APP_PEM }}" in workflow
    assert "RENOVATE_TOKEN: ${{ steps.squawk.outputs.token }}" in workflow
    assert "RENOVATE_CONFIG_FILE: .github/renovate-global.json" in workflow
    assert "github.token" not in workflow

    installer = (ROOT / "scripts/install_renovate_apko.sh").read_text(encoding="utf-8")
    assert "${APKO_VERSION:?APKO_VERSION is required}" in installer
    assert "${APKO_SHA256:?APKO_SHA256 is required}" in installer
    assert "sha256sum --check" in installer
    assert "sudo install" in installer
    assert "melange" not in installer and "grype" not in installer and "syft" not in installer


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        test_checksum_updater(Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_corepack_install(Path(temporary))
    test_renovate_configuration()
    test_self_hosted_renovate()
    print("passed scripts/test_renovate_helpers.py")


if __name__ == "__main__":
    main()
