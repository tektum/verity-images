#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("go_remediation", ROOT / "scripts/go_remediation.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stream(*items: dict) -> str:
    values = [{"config": {"protocol_version": "v1.0.0", "scanner_name": "govulncheck", "scanner_version": "v1.7.0", "scan_level": "symbol", "scan_mode": "source"}}]
    values.extend(items)
    return "\n".join(json.dumps(value) for value in values) + "\n"


def osv(identifier: str, module: str, fixed: str | None) -> dict:
    events = [{"introduced": "0"}]
    if fixed:
        events.append({"fixed": fixed.removeprefix("v")})
    return {"osv": {"id": identifier, "affected": [{"package": {"name": module, "ecosystem": "Go"}, "ranges": [{"type": "SEMVER", "events": events}]}]}}


def finding(identifier: str, module: str, version: str, module_root: str = ".") -> dict:
    return {"finding": {"osv": identifier, "module_root": module_root, "trace": [{"module": module, "version": version, "package": module + "/pkg"}]}}


def spec(root: Path, raw: str, database_hash: str = "1" * 64) -> tuple[Path, Path]:
    capture = root / "input.json"
    capture.write_text(raw, encoding="utf-8")
    spec_path = root / "spec.json"
    spec_path.write_text(json.dumps({"capture": capture.name, "source": {"version": "1.2.3", "commit": "a" * 40}, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + database_hash}, "scan": {"moduleRoot": ".", "packages": ["."], "phase": "post-generation"}}), encoding="utf-8")
    return spec_path, root / "go-remediation.lock.json"

def write_lock(module, path: Path, lock: dict) -> None:
    capture = {"schemaVersion": 1, "tool": module.TOOL, "database": lock["database"], "osvs": [], "findings": []}
    capture_bytes = module.canonical(capture)
    lock["scan"]["captureSha256"] = module.digest(capture_bytes)
    lock["contentHash"] = module.lock_hash(lock)
    path.write_bytes(module.canonical(lock))
    path.parent.joinpath(lock["scan"]["capture"]).write_bytes(capture_bytes)


def test_prerelease_ordering(module) -> None:
    assert module.parse_version("v1.5.1-0.20240101120000-abcdef") < module.parse_version("v1.5.1")
    raw = stream(
        osv("GO-PRE", "example.com/dependency", "v1.5.1"),
        finding("GO-PRE", "example.com/dependency", "v1.5.1-0.20240101120000-abcdef"),
    )
    _, updates, nonfixable = module.derive(raw)
    assert updates[0]["fixedVersion"] == "v1.5.1"
    assert not nonfixable


def test_generation(module, root: Path) -> None:
    raw = stream(osv("GO-1", "example.com/dependency", "v1.2.3"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    spec_path, lock_path = spec(root, raw)
    first = module.generate(spec_path, lock_path)
    first_bytes = lock_path.read_bytes()
    module.generate(spec_path, lock_path)
    assert lock_path.read_bytes() == first_bytes
    assert first["updates"] == [{"moduleRoot": ".", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}]
    module.validate_lock(first, lock_path.with_suffix(".scan.json").read_bytes())
    lock_path.with_suffix(".scan.json").write_text("{}\n", encoding="utf-8")
    try:
        module.validate_lock(first, lock_path.with_suffix(".scan.json").read_bytes())
    except module.LockError as error:
        assert "captured scan hash mismatch" in str(error)
    else:
        raise AssertionError("stale capture was accepted")


def test_malformed_and_no_fix(module, root: Path) -> None:
    spec_path, lock_path = spec(root, "not json\n")
    try:
        module.generate(spec_path, lock_path)
    except module.LockError as error:
        assert "malformed" in str(error)
    else:
        raise AssertionError("malformed scan was accepted")
    raw = stream(osv("GO-2", "example.com/dependency", None), finding("GO-2", "example.com/dependency", "v1.0.0"))
    spec_path, lock_path = spec(root, raw)
    lock = module.generate(spec_path, lock_path)
    assert lock["updates"] == []
    assert lock["nonFixable"][0]["status"] == "no-fix"


def test_path_major(module, root: Path) -> None:
    raw = stream(osv("GO-3", "example.com/dependency", "v2.0.0"), finding("GO-3", "example.com/dependency", "v1.0.0"))
    spec_path, lock_path = spec(root, raw)
    lock = module.generate(spec_path, lock_path)
    assert lock["updates"] == []
    assert lock["nonFixable"][0]["status"] == "no-compatible-fix"


def executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def test_offline_apply(module, root: Path) -> None:
    project = root / "project"
    project.mkdir()
    project.joinpath("go.mod").write_text("module example.com/app\ngo 1.25\nrequire example.com/dependency v1.0.0\n", encoding="utf-8")
    lock = {"schemaVersion": 1, "source": {"version": "1.0.0", "commit": "a" * 40}, "tool": module.TOOL, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": ".", "packages": ["."], "phase": "source", "capture": "go-remediation.scan.json", "captureSha256": "sha256:" + "2" * 64}, "updates": [{"moduleRoot": ".", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}], "nonFixable": []}
    lock_path = project / "go-remediation.lock.json"
    write_lock(module, lock_path, lock)
    binaries = root / "bin"
    binaries.mkdir()
    log = root / "go.log"
    executable(binaries / "go", "#!/bin/sh\nset -eu\nprintf '%s|%s|%s|%s\\n' \"${GOPROXY:-}\" \"${GOSUMDB:-}\" \"${GOWORK:-}\" \"$*\" >>\"$GO_LOG\"\ncase \"$*\" in\n  'list -m -f {{.Version}} example.com/dependency') sed -n 's/.*example.com\\/dependency \\(v[^ ]*\\).*/\\1/p' go.mod ;;\n  'mod edit -require=example.com/dependency@v1.2.3') sed -i 's/v1.0.0/v1.2.3/' go.mod ;;\n  'list -mod=readonly -m -f {{.Path}} {{.Version}} all') printf 'example.com/dependency v1.2.3\\n' ;;\nesac\n")
    previous = os.environ.copy()
    os.environ.update({"PATH": f"{binaries}:{os.environ['PATH']}", "GO_LOG": str(log)})
    try:
        evidence = root / "evidence.json"
        module.apply(lock_path, project, evidence)
    finally:
        os.environ.clear()
        os.environ.update(previous)
    assert evidence.is_file()
    calls = log.read_text(encoding="utf-8")
    assert all(line.startswith("off|off|off|") for line in calls.splitlines())
    assert "v1.2.3" in project.joinpath("go.mod").read_text(encoding="utf-8")


def test_workspace_vendor_apply(module, root: Path) -> None:
    project = root / "workspace"
    child = project / "child"
    child.mkdir(parents=True)
    child.joinpath("go.mod").write_text(
        "module example.com/child\ngo 1.25\nrequire example.com/dependency v1.0.0\n",
        encoding="utf-8",
    )
    project.joinpath("go.work").write_text("go 1.25\nuse ./child\n", encoding="utf-8")
    project.joinpath("vendor").mkdir()
    lock = {
        "schemaVersion": 1,
        "source": {"version": "1.0.0", "commit": "a" * 40},
        "tool": module.TOOL,
        "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64},
        "scan": {"moduleRoot": "child", "packages": ["."], "phase": "post-generation", "capture": "scan.json", "captureSha256": "sha256:" + "2" * 64},
        "updates": [{"moduleRoot": "child", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}],
        "nonFixable": [],
    }
    lock_path = project / "lock.json"
    write_lock(module, lock_path, lock)
    calls = []
    original = module.run_go
    module.run_go = lambda arguments, cwd, output=False, workspace=None: (
        calls.append((arguments, cwd, workspace))
        or ("v1.0.0\n" if arguments[1:3] == ["list", "-m"] else "example.com/dependency v1.2.3\n" if "-m" in arguments else "")
    )
    try:
        module.apply(lock_path, project, root / "workspace-evidence.json")
    finally:
        module.run_go = original
    assert (["go", "work", "sync"], project.resolve(), project.resolve() / "go.work") in calls
    assert (["go", "list", "-mod=vendor", "."], child.resolve(), project.resolve() / "go.work") in calls


def test_apply_rejects_escape_and_preserves_newer(module, root: Path) -> None:
    project = root / "project"
    project.mkdir()
    outside = root / "outside"
    outside.mkdir()
    project.joinpath("escape").symlink_to(outside, target_is_directory=True)
    lock = {"schemaVersion": 1, "source": {"version": "1.0.0", "commit": "a" * 40}, "tool": module.TOOL, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": "escape", "packages": ["."], "phase": "source", "capture": "scan.json", "captureSha256": ""}, "updates": [], "nonFixable": []}
    path = project / "lock.json"
    write_lock(module, path, lock)
    try:
        module.apply(path, project, root / "evidence.json")
    except module.LockError as error:
        assert "escapes workspace" in str(error)
    else:
        raise AssertionError("symlinked module root escaped workspace")

    lock["scan"]["moduleRoot"] = "."
    lock["updates"] = [{"moduleRoot": ".", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}]
    write_lock(module, path, lock)
    calls = []
    original = module.run_go
    module.run_go = lambda arguments, cwd, output=False, workspace=None: (
        calls.append(arguments)
        or ("v1.3.0\n" if arguments[1:3] == ["list", "-m"] else "example.com/dependency v1.3.0\n" if "-m" in arguments else "")
    )
    try:
        module.apply(path, project, root / "evidence.json")
    finally:
        module.run_go = original
    assert not any(arguments[1:3] == ["mod", "edit"] for arguments in calls)


def test_selected_versions_are_per_root(module, root: Path) -> None:
    project = root / "project"
    for name in ("a", "b"):
        project.joinpath(name).mkdir(parents=True)
    lock = {"schemaVersion": 1, "source": {"version": "1.0.0", "commit": "a" * 40}, "tool": module.TOOL, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": "a", "packages": ["."], "phase": "source", "capture": "scan.json", "captureSha256": ""}, "updates": [{"moduleRoot": "a", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}, {"moduleRoot": "b", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}], "nonFixable": []}
    path = project / "lock.json"
    write_lock(module, path, lock)
    original = module.run_go
    def fake(arguments, cwd, output=False, workspace=None):
        if arguments[1:3] == ["list", "-m"]:
            return "v1.0.0\n"
        if "-m" in arguments:
            return f"example.com/dependency {'v1.0.0' if cwd.name == 'a' else 'v1.2.3'}\n"
        return ""
    module.run_go = fake
    try:
        try:
            module.apply(path, project, root / "evidence.json")
        except module.LockError as error:
            assert "in a" in str(error)
        else:
            raise AssertionError("per-root selected-version mismatch was hidden")
    finally:
        module.run_go = original


def test_pipeline_and_workflow_contracts(module, root: Path) -> None:
    pipeline = ROOT.joinpath("pipelines/go/remediate.yaml").read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool\" <<'PYTHON'\n", 1)[1].split("      PYTHON\n", 1)[0]
    script = "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"
    assert "capture provenance mismatch" in script
    assert "module root escapes workspace" in script
    assert 'GOWORK=str(workspace) if workspace else "off"' in script
    assert "selected.update(((name, path), selected_version)" in script
    assert "version(current) >= version(update[\"fixedVersion\"])" in script

    workflow = ROOT.joinpath(".github/workflows/renovate-go-remediation.yaml").read_text(encoding="utf-8")
    assert workflow.count("git/refs/heads/${BRANCH}") == 1
    assert "git/trees" in workflow and "git/commits" in workflow

    project = root / "pipeline"
    project.mkdir()
    project.joinpath("go.mod").write_text(
        "module example.com/app\ngo 1.25\nrequire example.com/dependency v1.3.0\n",
        encoding="utf-8",
    )
    lock = {"schemaVersion": 1, "source": {"version": "1.0.0", "commit": "a" * 40}, "tool": module.TOOL, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": ".", "packages": ["."], "phase": "source", "capture": "scan.json", "captureSha256": ""}, "updates": [{"moduleRoot": ".", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "vulnerabilityIds": ["GO-1"]}], "nonFixable": []}
    lock_path = project / "lock.json"
    write_lock(module, lock_path, lock)
    tool = project / "apply.py"
    tool.write_text(script, encoding="utf-8")
    binaries = root / "pipeline-bin"
    binaries.mkdir()
    log = root / "pipeline-go.log"
    executable(binaries / "go", "#!/bin/sh\nset -eu\nprintf '%s|%s|%s|%s\\n' \"${GOPROXY:-}\" \"${GOSUMDB:-}\" \"${GOWORK:-}\" \"$*\" >>\"$GO_LOG\"\ncase \"$*\" in\n  'list -m -f {{.Version}} example.com/dependency') printf 'v1.3.0\\n' ;;\n  'list -mod=readonly -m -f {{.Path}} {{.Version}} all') printf 'example.com/dependency v1.3.0\\n' ;;\nesac\n")
    previous = os.environ.copy()
    os.environ.update({"PATH": f"{binaries}:{os.environ['PATH']}", "GO_LOG": str(log)})
    try:
        result = module.subprocess.run(
            ["python3", str(tool), str(lock_path), str(project), str(project / "evidence.json")],
            check=True,
        )
        assert result.returncode == 0
    finally:
        os.environ.clear()
        os.environ.update(previous)
    calls = log.read_text(encoding="utf-8")
    assert "mod edit" not in calls
    assert all(line.startswith("off|off|off|") for line in calls.splitlines())


def test_epoch(module, root: Path) -> None:
    recipe = root / "melange.yaml"
    recipe.write_text('package:\n  version: "1.2.3"\n  epoch: 4\n', encoding="utf-8")
    old = root / "old.json"
    new = root / "new.json"
    old.write_text(json.dumps({"source": {"version": "1.2.3"}, "contentHash": "sha256:" + "1" * 64}), encoding="utf-8")
    new.write_text(json.dumps({"source": {"version": "1.2.3"}, "contentHash": "sha256:" + "2" * 64}), encoding="utf-8")
    assert module.bump_epoch(recipe, old, new)
    assert "epoch: 5" in recipe.read_text(encoding="utf-8")
    new.write_text(json.dumps({"source": {"version": "1.2.4"}, "contentHash": "sha256:" + "3" * 64}), encoding="utf-8")
    assert not module.bump_epoch(recipe, old, new)


def main() -> None:
    module = load()
    with tempfile.TemporaryDirectory() as temporary:
        test_prerelease_ordering(module)
        test_generation(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_malformed_and_no_fix(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_path_major(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_offline_apply(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_workspace_vendor_apply(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_apply_rejects_escape_and_preserves_newer(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_selected_versions_are_per_root(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_pipeline_and_workflow_contracts(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_epoch(module, Path(temporary))
    print("passed scripts/test_go_remediation.py")


if __name__ == "__main__":
    main()
