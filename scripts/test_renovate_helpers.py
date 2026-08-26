#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
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


def test_go_reconciliation(root: Path) -> None:
    script = pipeline_script(ROOT / "pipelines/go/bump.yaml")
    module = root / "go-module"
    binaries = root / "go-bin"
    module.mkdir()
    binaries.mkdir()
    log = root / "go.log"
    executable(
        binaries / "go",
        """#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$GO_LOG"
case "$*" in
  'env GOVERSION') printf 'go1.26.7\n' ;;
  'work edit -json') printf '{"Use":[\n{"DiskPath":"one"},\n{"DiskPath":"two"}\n]}\n' ;;
esac
""",
    )
    executable(binaries / "omnibump", "#!/bin/sh\nprintf 'omnibump %s\\n' \"$*\" >>\"$GO_LOG\"\n")
    replacements = {
        "${{inputs.modroot}}": str(module),
        "${{inputs.go-version}}": "",
        "${{inputs.deps}}": "example.com/dependency@v1.2.3",
        "${{inputs.replaces}}": "",
        "${{inputs.tidy}}": "true",
        "${{inputs.show-diff}}": "false",
        "${{inputs.tidy-compat}}": "1.25",
        "${{inputs.work}}": "false",
    }
    rendered = script
    for source, target in replacements.items():
        rendered = rendered.replace(source, target)
    environment = os.environ | {"PATH": f"{binaries}:{os.environ['PATH']}", "GO_LOG": str(log)}

    module.joinpath("go.mod").write_text("module example.com/root\n", encoding="utf-8")
    module.joinpath("go.sum").write_text("sum\n", encoding="utf-8")
    module.joinpath("vendor").mkdir()
    subprocess.run(["sh", "-eu", "-c", rendered], check=True, env=environment)
    calls = log.read_text(encoding="utf-8")
    assert "-C . mod tidy -compat=1.25" in calls
    assert "mod vendor" in calls

    log.write_text("", encoding="utf-8")
    untidy = rendered.replace("--tidy=true", "--tidy=false").replace('[ "true" = true ]', '[ "false" = true ]')
    subprocess.run(["sh", "-eu", "-c", untidy], check=True, env=environment)
    calls = log.read_text(encoding="utf-8")
    assert "mod tidy" not in calls
    assert "mod vendor" in calls

    log.write_text("", encoding="utf-8")
    module.joinpath("go.mod").unlink()
    module.joinpath("vendor").rmdir()
    for child in ("one", "two"):
        module.joinpath(child).mkdir()
        module.joinpath(child, "go.mod").write_text(f"module example.com/{child}\n", encoding="utf-8")
    module.joinpath("go.work").write_text("go 1.26\nuse ./one\nuse ./two\n", encoding="utf-8")
    module.joinpath("vendor").mkdir()
    subprocess.run(["sh", "-eu", "-c", rendered], check=True, env=environment)
    calls = log.read_text(encoding="utf-8")
    assert "work sync" in calls
    assert "-C one mod tidy -compat=1.25" in calls
    assert "-C two mod tidy -compat=1.25" in calls
    assert "work vendor" in calls


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
    recipe = root / "images/traefik/melange.yaml"
    recipe.parent.mkdir(parents=True)
    recipe.write_text((ROOT / "images/traefik/melange.yaml").read_text(encoding="utf-8"), encoding="utf-8")
    updater.ALLOWED_ASSETS = {"images/traefik/melange.yaml": ("traefik/traefik", "traefik-v{version}.src.tar.gz")}
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
    assert requested == ["https://github.com/traefik/traefik/releases/download/v3.7.10/traefik-v3.7.10.src.tar.gz"]
    assert f"expected-sha256: {checksum}" in recipe.read_text(encoding="utf-8")

    source = recipe.read_text(encoding="utf-8").replace("github.com/traefik/traefik", "github.com/attacker/traefik")
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
        "npm@11.0.0": "npm ci",
        "pnpm@10.0.0": "pnpm install --frozen-lockfile",
        "yarn@1.22.22": "yarn install --frozen-lockfile",
        "yarn@4.9.2": "yarn install --immutable",
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
    assert any(manager.get("datasourceTemplate") == "go" and "go/bump" in manager["matchStrings"][0] for manager in managers)
    assert any(manager.get("datasourceTemplate") == "crate" and "--precise" in manager["matchStrings"][0] for manager in managers)
    traefik_rule = next(
        rule for rule in renovate["packageRules"] if rule.get("matchFileNames") == ["images/traefik/melange.yaml"]
    )
    assert traefik_rule["postUpgradeTasks"]["commands"] == [
        "python3 scripts/update_release_asset_checksum.py images/traefik/melange.yaml"
    ]
    assert "matchUpdateTypes" not in traefik_rule
    deno = (ROOT / "images/deno/melange.yaml").read_text(encoding="utf-8")
    assert "cargo update -p rand@0.9 --precise" in deno
    assert "cargo update -p quinn-proto@0.11 --precise" in deno
    go_get_manager = next(
        manager for manager in managers if "argo-workflows|gitlab-runner" in manager["managerFilePatterns"][0]
    )
    assert go_get_manager["matchStrings"][0].startswith(r"go get [\\]\n")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        test_go_reconciliation(root)
    with tempfile.TemporaryDirectory() as temporary:
        test_checksum_updater(Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_corepack_install(Path(temporary))
    test_renovate_configuration()
    print("passed scripts/test_renovate_helpers.py")


if __name__ == "__main__":
    main()
