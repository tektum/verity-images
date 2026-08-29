#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUM_A = "h1:" + "A" * 43 + "="
SUM_B = "h1:" + "B" * 43 + "="


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


def finding(identifier: str, module: str, version: str, module_root: str | None = None) -> dict:
    value = {"osv": identifier, "trace": [{"module": module, "version": version, "package": module + "/pkg"}]}
    if module_root is not None:
        value["module_root"] = module_root
    return {"finding": value}


def make_spec(root: Path, raw: str, module_root: str = ".") -> tuple[Path, Path]:
    capture = root / "input.json"
    capture.write_text(raw, encoding="utf-8")
    spec_path = root / "spec.json"
    spec_path.write_text(json.dumps({"capture": capture.name, "source": {"version": "1.2.3", "commit": "a" * 40}, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": module_root, "packages": ["."], "phase": "post-generation"}}), encoding="utf-8")
    return spec_path, root / "go-remediation.lock.json"


def artifact(module: str = "example.com/dependency", version: str = "v1.2.3", module_sum: str | None = SUM_A, go_mod_sum: str = SUM_B) -> dict:
    return {"module": module, "version": version, "sum": module_sum, "goModSum": go_mod_sum}


def update(module_root: str = ".", old: str = "v1.0.0", fixed: str = "v1.2.3", artifacts: list[dict] | None = None) -> dict:
    return {"moduleRoot": module_root, "module": "example.com/dependency", "oldVersion": old, "fixedVersion": fixed, "artifacts": artifacts or [artifact(version=fixed)], "vulnerabilityIds": ["GO-1"]}


def lock_data(module, module_root: str = ".", updates: list[dict] | None = None) -> dict:
    return {"schemaVersion": module.SCHEMA_VERSION, "source": {"version": "1.0.0", "commit": "a" * 40}, "tool": module.TOOL, "database": {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}, "scan": {"moduleRoot": module_root, "packages": ["."], "phase": "source", "capture": "scan.json", "captureSha256": ""}, "updates": updates or [], "nonFixable": []}


def write_lock(module, path: Path, lock: dict) -> None:
    capture = {"schemaVersion": module.SCHEMA_VERSION, "tool": module.TOOL, "database": lock["database"], "osvs": [], "findings": []}
    capture_bytes = module.canonical(capture)
    lock["scan"]["captureSha256"] = module.digest(capture_bytes)
    lock["contentHash"] = module.lock_hash(lock)
    path.write_bytes(module.canonical(lock))
    path.parent.joinpath(lock["scan"]["capture"]).write_bytes(capture_bytes)


def assert_raises(error_type, message: str, action) -> None:
    try:
        action()
    except error_type as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected {error_type.__name__}: {message}")


def test_root_binding_and_deterministic_generation(module, root: Path) -> None:
    raw = stream(
        osv("GO-1", "example.com/dependency", "v1.2.3"),
        finding("GO-1", "example.com/dependency", "v1.0.0"),
        osv("GO-2", "example.com/other", None),
        finding("GO-2", "example.com/other", "v1.0.0"),
    )
    spec_path, lock_path = make_spec(root, raw, "server")
    original = module.resolve_module_artifacts
    module.resolve_module_artifacts = lambda name, version: [artifact(name, version)]
    try:
        first = module.generate(spec_path, lock_path)
        first_bytes = lock_path.read_bytes()
        module.generate(spec_path, lock_path)
    finally:
        module.resolve_module_artifacts = original
    assert lock_path.read_bytes() == first_bytes
    assert first["updates"] == [{"moduleRoot": "server", "module": "example.com/dependency", "oldVersion": "v1.0.0", "fixedVersion": "v1.2.3", "artifacts": [artifact()], "vulnerabilityIds": ["GO-1"]}]
    assert first["nonFixable"] == [{"moduleRoot": "server", "module": "example.com/other", "version": "v1.0.0", "status": "no-fix", "vulnerabilityIds": ["GO-2"]}]
    module.validate_lock(first, lock_path.with_suffix(".scan.json").read_bytes())


def test_finding_cannot_redirect_root(module) -> None:
    raw = stream(osv("GO-1", "example.com/dependency", "v1.2.3"), finding("GO-1", "example.com/dependency", "v1.0.0", "."))
    assert_raises(module.LockError, "invents module root", lambda: module.derive(raw, "server"))


def test_version_and_path_major(module) -> None:
    assert module.parse_version("v1.5.1-0.20240101120000-abcdef") < module.parse_version("v1.5.1")
    raw = stream(osv("GO-3", "example.com/dependency", "v2.0.0"), finding("GO-3", "example.com/dependency", "v1.0.0"))
    _, updates, nonfixable = module.derive(raw, "nested")
    assert updates == []
    assert nonfixable[0]["moduleRoot"] == "nested"
    assert nonfixable[0]["status"] == "no-compatible-fix"


def test_lock_artifact_shape_and_root_validation(module, root: Path) -> None:
    path = root / "lock.json"
    accepted = lock_data(module, "server", [update("server", artifacts=[artifact(module_sum=None)])])
    write_lock(module, path, accepted)
    module.validate_lock(accepted, path.parent.joinpath("scan.json").read_bytes())
    cases = (
        (("artifacts", 0, "sum"), "", "artifact checksum"),
        (("artifacts", 0, "goModSum"), None, "artifact checksum"),
        (("artifacts", 0, "module"), "example.com/other", "bind fixed module"),
        (("artifacts", 0, "version"), "v1.2.4", "bind fixed module"),
        (("moduleRoot",), ".", "trusted scan root"),
    )
    for keys, value, message in cases:
        candidate = json.loads(json.dumps(accepted))
        target = candidate["updates"][0]
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = value
        candidate["contentHash"] = module.lock_hash(candidate)
        assert_raises(module.LockError, message, lambda candidate=candidate: module.validate_lock(candidate))


def test_download_response_validation(module, root: Path) -> None:
    original = module.run_go
    base = {"Path": "example.com/dependency", "Version": "v1.2.3", "Sum": SUM_A, "GoModSum": SUM_B}
    cases = [
        ({**base, "Path": "example.com/other"}, "identity mismatch"),
        ({**base, "Version": "v1.2.4"}, "identity mismatch"),
        ({**base, "Sum": "h1:bad"}, "valid checksum identity"),
        ({**base, "GoModSum": "h1:bad"}, "valid checksum identity"),
        ([], "identity mismatch"),
    ]
    try:
        for response, message in cases:
            module.run_go = lambda *_args, response=response, **_kwargs: json.dumps(response)
            assert_raises(module.LockError, message, lambda: module.download_module("example.com/dependency", "v1.2.3", root))
        without_zip = dict(base)
        without_zip.pop("Sum")
        module.run_go = lambda *_args, **_kwargs: json.dumps(without_zip)
        assert module.download_module("example.com/dependency", "v1.2.3", root) == artifact(module_sum=None)
    finally:
        module.run_go = original


def add_proxy_module(proxy: Path, module: str, version: str, source: str, requirements: str = "") -> None:
    directory = proxy / module / "@v"
    directory.mkdir(parents=True, exist_ok=True)
    directory.joinpath(version + ".info").write_text(json.dumps({"Version": version, "Time": "2026-01-01T00:00:00Z"}), encoding="utf-8")
    go_mod = f"module {module}\ngo 1.25\n{requirements}"
    directory.joinpath(version + ".mod").write_text(go_mod, encoding="utf-8")
    with zipfile.ZipFile(directory / (version + ".zip"), "w") as archive:
        prefix = f"{module}@{version}/"
        for name, content in (("go.mod", go_mod), ("dependency.go", source)):
            entry = zipfile.ZipInfo(prefix + name)
            entry.date_time = (1980, 1, 1, 0, 0, 0)
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, content)


def set_go_environment(proxy: Path, cache: Path) -> dict[str, str]:
    previous = os.environ.copy()
    os.environ.update({"GOPROXY": proxy.resolve().as_uri(), "GOSUMDB": "off", "GOMODCACHE": str(cache), "GOTOOLCHAIN": "local"})
    return previous


def restore_environment(previous: dict[str, str]) -> None:
    os.environ.clear()
    os.environ.update(previous)


def prepare_proxy(proxy: Path) -> None:
    add_proxy_module(proxy, "example.com/transitive", "v0.5.0", "package transitive\nfunc Value() int { return 2 }\n")
    add_proxy_module(proxy, "example.com/dependency", "v1.0.0", "package dependency\nfunc Value() int { return 1 }\n")
    add_proxy_module(
        proxy,
        "example.com/dependency",
        "v1.2.3",
        'package dependency\nimport "example.com/transitive"\nfunc Value() int { return transitive.Value() }\n',
        "require example.com/transitive v0.5.0\n",
    )


def prepare_workspace(root: Path, proxy: Path) -> Path:
    project = root / "project"
    server = project / "server"
    server.mkdir(parents=True)
    server.joinpath("go.mod").write_text("module example.com/app\ngo 1.25\nrequire example.com/dependency v1.0.0\n", encoding="utf-8")
    server.joinpath("main.go").write_text('package main\nimport "example.com/dependency"\nfunc main() { dependency.Value() }\n', encoding="utf-8")
    project.joinpath("go.work").write_text("go 1.25\nuse ./server\n", encoding="utf-8")
    previous = set_go_environment(proxy, root / "setup-cache")
    try:
        subprocess.run(["go", "mod", "download", "example.com/dependency@v1.0.0"], cwd=server, check=True)
        subprocess.run(["go", "work", "vendor"], cwd=project, check=True)
    finally:
        restore_environment(previous)
    return project


def extract_pipeline(root: Path) -> Path:
    pipeline = ROOT.joinpath("pipelines/go/remediate.yaml").read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool\" <<'PYTHON'\n", 1)[1].split("      PYTHON\n", 1)[0]
    script = "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"
    path = root / "pipeline-apply.py"
    path.write_text(script, encoding="utf-8")
    return path


def generate_in_proxy(module, root: Path, project: Path, proxy: Path) -> tuple[Path, dict]:
    raw = stream(osv("GO-1", "example.com/dependency", "v1.2.3"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    spec_path, lock_path = make_spec(project, raw, "server")
    previous = set_go_environment(proxy, root / "generation-cache")
    try:
        lock = module.generate(spec_path, lock_path)
    finally:
        restore_environment(previous)
    return lock_path, lock


def test_clean_cache_offline_workspace_and_evidence(module, root: Path) -> None:
    proxy = root / "proxy"
    prepare_proxy(proxy)
    project = prepare_workspace(root, proxy)
    lock_path, lock = generate_in_proxy(module, root, project, proxy)
    artifacts = lock["updates"][0]["artifacts"]
    assert {(item["module"], item["version"]) for item in artifacts} == {
        ("example.com/dependency", "v1.2.3"),
        ("example.com/transitive", "v0.5.0"),
    }
    assert all(item["sum"].startswith("h1:") and item["goModSum"].startswith("h1:") for item in artifacts)

    source_project = root / "source-apply"
    pipeline_project = root / "pipeline-apply"
    shutil.copytree(project, source_project)
    shutil.copytree(project, pipeline_project)
    source_evidence = source_project / "evidence.json"
    pipeline_evidence = pipeline_project / "evidence.json"
    previous = set_go_environment(proxy, root / "clean-source-cache")
    try:
        module.apply(source_project / lock_path.name, source_project, source_evidence)
    finally:
        restore_environment(previous)
    previous = set_go_environment(proxy, root / "clean-pipeline-cache")
    try:
        subprocess.run(["python3", str(extract_pipeline(root)), str(pipeline_project / lock_path.name), str(pipeline_project), str(pipeline_evidence)], check=True)
    finally:
        restore_environment(previous)

    source = json.loads(source_evidence.read_text(encoding="utf-8"))
    pipeline = json.loads(pipeline_evidence.read_text(encoding="utf-8"))
    assert source == pipeline
    staged = {(item["moduleRoot"], item["module"], item["version"]) for item in source["staged"]}
    assert staged == {
        ("server", "example.com/dependency", "v1.2.3"),
        ("server", "example.com/transitive", "v0.5.0"),
    }
    assert source["selected"] == [{"moduleRoot": "server", "module": "example.com/dependency", "version": "v1.2.3"}]
    assert "v1.2.3" in source_project.joinpath("server/go.mod").read_text(encoding="utf-8")
    assert "example.com/dependency v1.2.3" in source_project.joinpath("vendor/modules.txt").read_text(encoding="utf-8")

    repeat_project = root / "repeat-apply"
    shutil.copytree(project, repeat_project)
    previous = set_go_environment(proxy, root / "clean-repeat-cache")
    try:
        module.apply(repeat_project / lock_path.name, repeat_project, repeat_project / "evidence.json")
    finally:
        restore_environment(previous)
    assert repeat_project.joinpath("evidence.json").read_bytes() == source_evidence.read_bytes()


def test_network_disabled_clean_cache_fails(module, root: Path) -> None:
    proxy = root / "proxy"
    prepare_proxy(proxy)
    project = prepare_workspace(root, proxy)
    lock_path, _ = generate_in_proxy(module, root, project, proxy)
    previous = os.environ.copy()
    os.environ.update({"GOPROXY": "off", "GOSUMDB": "off", "GOMODCACHE": str(root / "missing-cache")})
    try:
        assert_raises(subprocess.CalledProcessError, "returned non-zero", lambda: module.apply(lock_path, project, root / "evidence.json"))
    finally:
        restore_environment(previous)


def test_checksum_mismatch_and_newer_skip(module, root: Path) -> None:
    project = root / "project"
    project.mkdir()
    project.joinpath("go.mod").write_text("module example.com/app\ngo 1.25\nrequire example.com/dependency v1.0.0\n", encoding="utf-8")
    lock = lock_data(module, updates=[update()])
    path = project / "lock.json"
    write_lock(module, path, lock)
    original_run = module.run_go
    original_download = module.download_module
    module.run_go = lambda arguments, _cwd, output=False, workspace=None, online=False: "v1.0.0\n" if arguments[1:3] == ["list", "-m"] else ""
    module.download_module = lambda *_args: artifact(module_sum=SUM_B, go_mod_sum=SUM_A)
    try:
        assert_raises(module.LockError, "checksum mismatch", lambda: module.apply(path, project, root / "mismatch.json"))
    finally:
        module.run_go = original_run
        module.download_module = original_download

    calls: list[list[str]] = []

    def newer(arguments, _cwd, output=False, workspace=None, online=False):
        calls.append(arguments)
        if arguments[1:3] == ["list", "-m"] and "-mod=readonly" not in arguments:
            return "v1.3.0\n"
        if "-m" in arguments:
            return "example.com/dependency v1.3.0\n"
        return ""

    module.run_go = newer
    module.download_module = lambda *_args: (_ for _ in ()).throw(AssertionError("newer module was staged"))
    try:
        module.apply(path, project, root / "newer.json")
    finally:
        module.run_go = original_run
        module.download_module = original_download
    evidence = json.loads(root.joinpath("newer.json").read_text(encoding="utf-8"))
    assert evidence["staged"] == []
    assert evidence["selected"][0]["version"] == "v1.3.0"
    assert not any(arguments[1:3] == ["mod", "edit"] for arguments in calls)


def test_pipeline_malformed_inputs_report_value_error(module, root: Path) -> None:
    script = extract_pipeline(root)
    project = root / "project"
    project.mkdir()
    path = project / "lock.json"
    path.write_text("[]\n", encoding="utf-8")
    result = subprocess.run(["python3", str(script), str(path), str(project), str(root / "evidence.json")], text=True, capture_output=True)
    assert result.returncode != 0
    assert "ValueError: invalid remediation lock" in result.stderr
    assert "AttributeError" not in result.stderr and "TypeError" not in result.stderr

    valid = lock_data(module, updates=[update()])
    write_lock(module, path, valid)
    binary = root / "bin"
    binary.mkdir()
    fake_go = binary / "go"
    fake_go.write_text("#!/bin/sh\ncase \"$*\" in\n  'list -m -f {{.Version}} example.com/dependency') printf 'v1.0.0\\n' ;;\n  'mod download -json example.com/dependency@v1.2.3') printf '[]\\n' ;;\nesac\n", encoding="utf-8")
    fake_go.chmod(0o755)
    previous = os.environ.copy()
    os.environ["PATH"] = f"{binary}:{os.environ['PATH']}"
    try:
        result = subprocess.run(["python3", str(script), str(path), str(project), str(root / "evidence.json")], text=True, capture_output=True)
    finally:
        restore_environment(previous)
    assert result.returncode != 0
    assert "ValueError: downloaded module identity mismatch" in result.stderr
    assert "AttributeError" not in result.stderr


def test_capture_artifact_binding(module, root: Path) -> None:
    trusted = root / "trusted"
    spec_dir = trusted / "images/example"
    spec_dir.mkdir(parents=True)
    source = {"repository": "https://example.com/source.git", "version": "1.2.3", "commit": "a" * 40}
    database = {"source": "https://vuln.go.dev", "revision": "2026-08-28", "sha256": "sha256:" + "1" * 64}
    scan = {"moduleRoot": "server", "packages": ["."], "phase": "source"}
    spec_data = {"capture": "raw.jsonl", "source": source, "database": database, "scan": scan}
    spec_name = "images/example/go-remediation.spec.json"
    spec_dir.joinpath("go-remediation.spec.json").write_bytes(module.canonical(spec_data))
    artifact_dir = root / "artifact"
    raw = stream(osv("GO-1", "example.com/dependency", "v1.2.3"), finding("GO-1", "example.com/dependency", "v1.0.0")).encode()
    raw_path = artifact_dir / "raw/images/example/go-remediation.spec.jsonl"
    raw_path.parent.mkdir(parents=True)
    raw_path.write_bytes(raw)
    entry = {"spec": spec_name, "raw": raw_path.relative_to(artifact_dir).as_posix(), "rawSha256": module.digest(raw), "source": source, "database": database, "scan": scan}
    manifest = {"schemaVersion": module.SCHEMA_VERSION, "repository": "tektum/verity-images", "pr": 407, "run": 42, "base": "a" * 40, "head": "b" * 40, "tool": module.TOOL, "changedDirectories": ["images/example"], "specs": [spec_name], "captures": [entry]}

    def verify() -> list[dict]:
        artifact_dir.joinpath("manifest.json").write_bytes(module.canonical(manifest))
        return module.verify_capture_artifact(artifact_dir, trusted, "tektum/verity-images", "407", "42", "a" * 40, "b" * 40, [spec_name])

    assert verify() == [entry]
    for field, value in (("head", "c" * 40), ("base", "c" * 40), ("repository", "other/repo")):
        original = manifest[field]
        manifest[field] = value
        assert_raises(module.LockError, "identity mismatch", verify)
        manifest[field] = original
    entry["rawSha256"] = "sha256:" + "0" * 64
    assert_raises(module.LockError, "hash mismatch", verify)
    entry["rawSha256"] = module.digest(raw)
    manifest["captures"] = []
    assert_raises(module.LockError, "omits declared scan", verify)
    manifest["captures"] = [entry, dict(entry)]
    assert_raises(module.LockError, "unknown spec", verify)
    manifest["captures"] = [entry]
    entry["scan"] = {**scan, "moduleRoot": "."}
    assert_raises(module.LockError, "trusted spec", verify)


def test_selection_epoch_and_contracts(module, root: Path) -> None:
    specs = ["images/kubectl/1.34/go-remediation.spec.json", "images/kubectl/1.35/go-remediation.spec.json"]
    assert module.select_changed_specs(specs, ["images/kubectl/1.35/melange.yaml"]) == (["images/kubectl/1.35"], [specs[1]])
    assert module.select_changed_specs(specs, ["renovate.json"]) == ([], [])
    recipe = root / "melange.yaml"
    recipe.write_text('package:\n  version: "1.2.3"\n  epoch: 4\n', encoding="utf-8")
    old = root / "old.json"
    new = root / "new.json"
    old.write_text(json.dumps({"source": {"version": "1.2.3"}, "contentHash": "sha256:" + "1" * 64}), encoding="utf-8")
    new.write_text(json.dumps({"source": {"version": "1.2.3"}, "contentHash": "sha256:" + "2" * 64}), encoding="utf-8")
    assert module.bump_epoch(recipe, old, new)
    assert "epoch: 5" in recipe.read_text(encoding="utf-8")
    workflow = ROOT.joinpath(".github/workflows/renovate-go-remediation.yaml").read_text(encoding="utf-8")
    assert workflow.count("git/refs/heads/${BRANCH}") == 1
    assert "git/trees" in workflow and "git/commits" in workflow
    pipeline = ROOT.joinpath("pipelines/go/remediate.yaml").read_text(encoding="utf-8")
    assert 'environment.update(GOPROXY="off", GOSUMDB="off")' in pipeline
    assert '"staged": sorted(staged, key=canonical)' in pipeline
    assert '["go", "mod", "vendor"]' in pipeline
    assert '["go", "work", "vendor"]' in pipeline


def main() -> None:
    module = load()
    with tempfile.TemporaryDirectory() as temporary:
        test_root_binding_and_deterministic_generation(module, Path(temporary))
    test_finding_cannot_redirect_root(module)
    test_version_and_path_major(module)
    with tempfile.TemporaryDirectory() as temporary:
        test_lock_artifact_shape_and_root_validation(module, Path(temporary))
        test_download_response_validation(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_clean_cache_offline_workspace_and_evidence(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_network_disabled_clean_cache_fails(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_checksum_mismatch_and_newer_skip(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_pipeline_malformed_inputs_report_value_error(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_capture_artifact_binding(module, Path(temporary))
    with tempfile.TemporaryDirectory() as temporary:
        test_selection_epoch_and_contracts(module, Path(temporary))
    print("passed scripts/test_go_remediation.py")


if __name__ == "__main__":
    main()
