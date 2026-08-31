#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "pipelines/go/remediate.yaml"


def extract_resolver(root: Path) -> Path:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool_dir/remediate.py\" <<'PYTHON'\n", 1)[1].split("      PYTHON\n", 1)[0]
    script = "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"
    path = root / "remediate.py"
    path.write_text(script, encoding="utf-8")
    return path


def load_resolver(root: Path):
    spec = importlib.util.spec_from_file_location("go_remediate", extract_resolver(root))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stream(*items: dict, version: str = "v1.7.0", scanner: str = "govulncheck", protocol: str = "v1.0.0") -> str:
    values = [{"config": {"protocol_version": protocol, "scanner_name": scanner, "scanner_version": version, "scan_level": "symbol", "scan_mode": "source"}}]
    values.extend(items)
    return "\n".join(json.dumps(value) for value in values) + "\n"


def osv(identifier: str, module: str, *fixes: str) -> dict:
    affected = []
    for fixed in fixes:
        affected.append({"package": {"name": module, "ecosystem": "Go"}, "ranges": [{"type": "SEMVER", "events": [{"introduced": "0"}, {"fixed": fixed.removeprefix("v")}]}]})
    return {"osv": {"id": identifier, "affected": affected}}


def finding(identifier: str, module: str, version: str) -> dict:
    return {"finding": {"osv": identifier, "trace": [{"module": module, "version": version, "package": module + "/pkg"}]}}


def assert_raises(error_type, message: str, action) -> None:
    try:
        action()
    except error_type as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected {error_type.__name__}: {message}")


def fake_scanner(root: Path, raw: str, status: int, expected: list[str] | None = None, stderr: str = "") -> Path:
    scanner = root / "govulncheck"
    scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import sys\n"
        f"assert sys.argv[1:] == {expected or ['-json', '.']!r}\n"
        f"sys.stdout.write({raw!r})\n"
        f"sys.stderr.write({stderr!r})\n"
        f"raise SystemExit({status})\n",
        encoding="utf-8",
    )
    scanner.chmod(0o755)
    return scanner


def test_scan_contract(module, root: Path) -> None:
    valid_findings = stream(osv("GO-1", "example.com/dependency", "v1.2.0"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    assert module.scan(fake_scanner(root, valid_findings, 3), root, ["."])
    assert module.scan(fake_scanner(root, stream(), 0), root, ["."])
    assert_raises(module.RemediationError, "unexpected govulncheck exit status 1", lambda: module.scan(fake_scanner(root, valid_findings, 1, stderr="scanner failed\n"), root, ["."]))
    assert_raises(module.RemediationError, "unexpected govulncheck exit status 1", lambda: module.scan(fake_scanner(root, "", 1, stderr="scanner failed\n"), root, ["."]))
    assert_raises(module.RemediationError, "contains no findings", lambda: module.scan(fake_scanner(root, stream(), 3), root, ["."]))
    for raw in ("", "not-json\n", '{"config":', '{"config": {"protocol_version": "v1.0.0"}}\n{"finding":'):
        assert_raises(module.RemediationError, "govulncheck", lambda raw=raw: module.scan(fake_scanner(root, raw, 3), root, ["."]))
    for raw in (stream(scanner="other"), stream(protocol="v2.0.0"), stream(version="v1.8.0")):
        assert_raises(module.RemediationError, "govulncheck", lambda raw=raw: module.scan(fake_scanner(root, raw, 0), root, ["."]))


def test_fix_selection(module) -> None:
    dependency = "example.com/dependency"
    messages = module.parse_stream(stream(
        osv("GO-1", dependency, "v1.2.0", "v1.4.0"),
        finding("GO-1", dependency, "v1.0.0"),
        osv("GO-2", dependency, "v1.3.0"),
        finding("GO-2", dependency, "v1.0.0"),
    ))
    updates, unresolved, detected, fixable = module.derive_fixes(messages, {dependency: "v1.0.0"})
    assert updates == {dependency: "v1.3.0"}
    assert unresolved == []
    assert detected == {("GO-1", dependency), ("GO-2", dependency)}
    assert fixable == detected

    incompatible = "example.com/dependency/v2"
    updates, unresolved, _, fixable = module.derive_fixes(
        module.parse_stream(stream(osv("GO-3", incompatible, "v3.0.0"), finding("GO-3", incompatible, "v2.0.0"))),
        {incompatible: "v2.0.0"},
    )
    assert updates == {} and fixable == set()
    assert unresolved == [("GO-3", incompatible, "v2.0.0", "no-compatible-fix")]

    updates, unresolved, _, fixable = module.derive_fixes(
        module.parse_stream(stream(osv("GO-4", dependency, "v1.2.0"), finding("GO-4", dependency, "v1.3.0"))),
        {dependency: "v1.3.0"},
    )
    assert updates == {} and fixable == set()
    assert unresolved == [("GO-4", dependency, "v1.3.0", "no-fix")]


def add_proxy_module(
    proxy: Path,
    module: str,
    version: str,
    requirements: dict[str, str] | None = None,
) -> None:
    directory = proxy / module / "@v"
    directory.mkdir(parents=True, exist_ok=True)
    mod = f"module {module}\n\ngo 1.25\n"
    if requirements:
        required = "".join(f"\t{name} {required_version}\n" for name, required_version in sorted(requirements.items()))
        mod += f"\nrequire (\n{required})\n"
    directory.joinpath(f"{version}.mod").write_text(mod, encoding="utf-8")
    directory.joinpath(f"{version}.info").write_text(json.dumps({"Version": version, "Time": "2026-01-01T00:00:00Z"}), encoding="utf-8")
    prefix = f"{module}@{version}/"
    with zipfile.ZipFile(directory / f"{version}.zip", "w") as archive:
        archive.writestr(prefix + "go.mod", mod)
        archive.writestr(prefix + "dependency.go", "package dependency\nfunc Value() int { return 1 }\n")


def prepare_project(root: Path, workspace: bool, vendor: bool) -> tuple[Path, Path, dict[str, str]]:
    proxy = root / "proxy"
    for version in ("v1.0.0", "v1.2.0", "v1.3.0"):
        add_proxy_module(proxy, "example.com/dependency", version)
    workspace_root = root / "checkout"
    module_root = workspace_root / "server" if workspace else workspace_root
    module_root.mkdir(parents=True)
    module_root.joinpath("go.mod").write_text("module example.com/app\n\ngo 1.25\n\nrequire example.com/dependency v1.0.0\n", encoding="utf-8")
    module_root.joinpath("main.go").write_text('package main\nimport "example.com/dependency"\nfunc main() { _ = dependency.Value() }\n', encoding="utf-8")
    environment = dict(os.environ, GOPROXY=proxy.resolve().as_uri(), GOSUMDB="off", GOMODCACHE=str(root / "cache"), GOTOOLCHAIN="local", GOWORK="off")
    subprocess.run(["go", "mod", "tidy"], cwd=module_root, env=environment, check=True, capture_output=True)
    if workspace:
        replacement = workspace_root / "replacement"
        replacement.mkdir()
        replacement.joinpath("go.mod").write_text("module example.com/dependency\n\ngo 1.25\n", encoding="utf-8")
        replacement.joinpath("dependency.go").write_text("package dependency\nfunc Value() int { return 1 }\n", encoding="utf-8")
        workspace_root.joinpath("go.work").write_text(
            "go 1.25\n\nuse ./server\n\nreplace example.com/dependency => ./replacement\n",
            encoding="utf-8",
        )
        workspace_environment = dict(environment, GOWORK=str(workspace_root / "go.work"))
        subprocess.run(["go", "work", "sync"], cwd=workspace_root, env=workspace_environment, check=True, capture_output=True)
        if vendor:
            subprocess.run(["go", "work", "vendor"], cwd=workspace_root, env=workspace_environment, check=True, capture_output=True)
    elif vendor:
        subprocess.run(["go", "mod", "vendor"], cwd=module_root, env=environment, check=True, capture_output=True)
    return workspace_root, module_root, environment


def sequence_scanner(
    root: Path,
    outputs: list[tuple[str, int]],
    package: str = ".",
    expected_gowork: str = "off",
) -> Path:
    scanner = root / "scanner"
    paths = []
    statuses = []
    for index, (raw, status) in enumerate(outputs):
        path = root / f"scan-{index}.jsonl"
        path.write_text(raw, encoding="utf-8")
        paths.append(str(path))
        statuses.append(status)
    state = root / "scan-state"
    scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import os, pathlib, sys\n"
        f"assert sys.argv[1:] == {['-json', package]!r}\n"
        f"assert os.environ.get('GOWORK') == {expected_gowork!r}\n"
        f"state = pathlib.Path({str(state)!r})\n"
        "index = int(state.read_text() or '0') if state.exists() else 0\n"
        "state.write_text(str(index + 1))\n"
        f"paths = {paths!r}\n"
        f"statuses = {statuses!r}\n"
        "index = min(index, len(paths) - 1)\n"
        "sys.stdout.write(pathlib.Path(paths[index]).read_text())\n"
        "raise SystemExit(statuses[index])\n",
        encoding="utf-8",
    )
    scanner.chmod(0o755)
    return scanner


def run_resolver(module, root: Path, workspace: bool = False, vendor: bool = False, after: str | None = None, package: str = ".") -> tuple[Path, Path, str]:
    workspace_root, module_root, environment = prepare_project(root, workspace, vendor)
    vulnerable = stream(osv("GO-1", "example.com/dependency", "v1.2.0"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    expected_gowork = str(workspace_root / "go.work") if workspace else "off"
    scanner = sequence_scanner(
        root,
        [(vulnerable, 3), (after if after is not None else stream(), 0 if after is None else 3)],
        package,
        expected_gowork,
    )
    real_go = shutil.which("go")
    assert real_go
    binary_dir = root / "bin"
    binary_dir.mkdir()
    log = root / "go.log"
    wrapper = binary_dir / "go"
    wrapper.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GO_LOG\"\nexec \"$REAL_GO\" \"$@\"\n", encoding="utf-8")
    wrapper.chmod(0o755)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment, PATH=f"{binary_dir}:{os.environ['PATH']}", REAL_GO=real_go, GO_LOG=str(log))
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), package]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    return workspace_root, module_root, output.getvalue()


def test_reconciliation_modes(module, root: Path) -> None:
    for name, workspace, vendor, expected_mode in (
        ("plain", False, False, "readonly"),
        ("module-vendor", False, True, "vendor"),
        ("workspace-vendor", True, True, "vendor"),
    ):
        case = root / name
        case.mkdir()
        workspace_root, module_root, output = run_resolver(module, case, workspace, vendor)
        assert "example.com/dependency v1.2.0" in module_root.joinpath("go.mod").read_text(encoding="utf-8")
        commands = case.joinpath("go.log").read_text(encoding="utf-8").splitlines()
        assert commands.count("get example.com/dependency@v1.2.0") == 1
        assert all(" -u" not in f" {command}" for command in commands)
        assert "mod tidy" in commands
        assert any(command.startswith(f"build -mod={expected_mode} -o ") and command.endswith(" .") for command in commands)
        if workspace:
            assert "work sync" in commands
            assert workspace_root.joinpath("vendor/modules.txt").is_file()
        elif vendor:
            assert "mod vendor" in commands
            assert module_root.joinpath("vendor/modules.txt").is_file()
        assert "go remediation: applying example.com/dependency@v1.2.0" in output


def test_no_compatible_fix_continues(module, root: Path) -> None:
    workspace_root, module_root, environment = prepare_project(root, False, False)
    incompatible = "example.com/dependency/v2"
    raw = stream(osv("GO-2", incompatible, "v3.0.0"), finding("GO-2", incompatible, "v2.0.0"))
    scanner = sequence_scanner(root, [(raw, 3), (raw, 3)])
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "."]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    assert "no-compatible-fix" in output.getvalue()


def test_package_graph_and_post_scan_failures(module, root: Path) -> None:
    graph = root / "graph"
    graph.mkdir()
    workspace_root, module_root, environment = prepare_project(graph, False, False)
    scanner = sequence_scanner(graph, [(stream(), 0)], package="./missing")
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "./missing"]
    try:
        assert_raises(module.RemediationError, "command failed", module.main)
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)

    persistent = root / "persistent"
    persistent.mkdir()
    vulnerable = stream(osv("GO-1", "example.com/dependency", "v1.2.0"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    assert_raises(module.RemediationError, "remain after remediation", lambda: run_resolver(module, persistent, after=vulnerable))

    unavailable = root / "unavailable"
    unavailable.mkdir()
    workspace_root, module_root, environment = prepare_project(unavailable, False, False)
    missing_fix = stream(osv("GO-2", "example.com/dependency", "v1.9.9"), finding("GO-2", "example.com/dependency", "v1.0.0"))
    scanner = sequence_scanner(unavailable, [(missing_fix, 3)])
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "."]
    try:
        assert_raises(module.RemediationError, "command failed", module.main)
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)


def test_interdependent_fixes(module, root: Path) -> None:
    proxy = root / "proxy"
    for version in ("v1.0.0", "v1.2.0", "v1.3.0"):
        add_proxy_module(proxy, "example.com/low", version)
    add_proxy_module(proxy, "example.com/high", "v1.0.0")
    add_proxy_module(proxy, "example.com/high", "v1.2.0", {"example.com/low": "v1.3.0"})
    workspace_root = root / "checkout"
    workspace_root.mkdir()
    workspace_root.joinpath("go.mod").write_text(
        "module example.com/app\n\ngo 1.25\n\nrequire (\n\texample.com/high v1.0.0\n\texample.com/low v1.0.0\n)\n",
        encoding="utf-8",
    )
    workspace_root.joinpath("main.go").write_text(
        'package main\nimport high "example.com/high"\nimport low "example.com/low"\nfunc main() { _, _ = high.Value(), low.Value() }\n',
        encoding="utf-8",
    )
    environment = dict(os.environ, GOPROXY=proxy.resolve().as_uri(), GOSUMDB="off", GOMODCACHE=str(root / "cache"), GOTOOLCHAIN="local", GOWORK="off")
    subprocess.run(["go", "mod", "tidy"], cwd=workspace_root, env=environment, check=True, capture_output=True)
    vulnerable = stream(
        osv("GO-HIGH", "example.com/high", "v1.2.0"),
        finding("GO-HIGH", "example.com/high", "v1.0.0"),
        osv("GO-LOW", "example.com/low", "v1.2.0"),
        finding("GO-LOW", "example.com/low", "v1.0.0"),
    )
    scanner = sequence_scanner(root, [(vulnerable, 3), (stream(), 0)], package="./...")
    real_go = shutil.which("go")
    assert real_go
    binary_dir = root / "bin"
    binary_dir.mkdir()
    log = root / "go.log"
    wrapper = binary_dir / "go"
    wrapper.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GO_LOG\"\nexec \"$REAL_GO\" \"$@\"\n", encoding="utf-8")
    wrapper.chmod(0o755)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment, PATH=f"{binary_dir}:{os.environ['PATH']}", REAL_GO=real_go, GO_LOG=str(log))
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(workspace_root), "./..."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    go_mod = workspace_root.joinpath("go.mod").read_text(encoding="utf-8")
    assert "example.com/high v1.2.0" in go_mod
    assert "example.com/low v1.3.0" in go_mod
    commands = log.read_text(encoding="utf-8").splitlines()
    assert "get example.com/high@v1.2.0" in commands
    assert "get example.com/low@v1.2.0" not in commands


def invoke_main(module, root: Path) -> None:
    previous_argv = sys.argv
    sys.argv = ["remediate.py", str(root / "scanner"), str(root), str(root), "."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv


def test_outer_pass_limit(module, root: Path) -> None:
    limit = module.MAX_REMEDIATION_PASSES
    selected = {f"example.com/dependency{index}": "v1.0.0" for index in range(limit + 1)}
    scans = 0

    def scan(*_args, **_kwargs):
        nonlocal scans
        result = scans
        scans += 1
        return result

    def derive_fixes(index, _selected):
        dependency = f"example.com/dependency{index}"
        identity = (f"GO-{index}", dependency)
        return {dependency: "v1.1.0"}, [], {identity}, {identity}

    def run_go(arguments, _root, capture=False, workspace=None):
        assert not capture and workspace is None
        dependency, version = arguments[2].rsplit("@", 1)
        selected[dependency] = version
        return ""

    module.scan = scan
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.derive_fixes = derive_fixes
    module.run_go = run_go
    module.reconcile = lambda *_args, **_kwargs: None
    assert_raises(
        module.RemediationError,
        f"go remediation pass limit reached after {limit} passes",
        lambda: invoke_main(module, root),
    )
    assert scans == limit + 1


def test_outer_no_progress(module, root: Path) -> None:
    dependency = "example.com/dependency"
    selected = {dependency: "v1.0.0"}
    identity = ("GO-1", dependency)
    module.scan = lambda *_args, **_kwargs: object()
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.derive_fixes = lambda *_args, **_kwargs: ({dependency: "v1.2.0"}, [], {identity}, {identity})
    module.run_go = lambda *_args, **_kwargs: ""
    module.reconcile = lambda *_args, **_kwargs: None
    assert_raises(
        module.RemediationError,
        "go remediation pass made no module graph progress",
        lambda: invoke_main(module, root),
    )


def test_apply_loop_rechecks_current_versions(module, root: Path) -> None:
    dependency = "example.com/dependency"
    calls = 0

    def selected_modules(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return {dependency: "v1.0.0" if calls == 1 else "v1.2.0"}

    identity = ("GO-1", dependency)
    module.scan = lambda *_args, **_kwargs: object()
    module.selected_modules = selected_modules
    module.derive_fixes = lambda *_args, **_kwargs: ({dependency: "v1.2.0"}, [], {identity}, {identity})
    module.run_go = lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("stale request applied"))
    module.reconcile = lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("empty apply loop reconciled"))
    assert_raises(
        module.RemediationError,
        "go remediation apply loop selected no updates",
        lambda: invoke_main(module, root),
    )


def test_newly_exposed_fixes_converge(module, root: Path) -> None:
    proxy = root / "proxy"
    for version in ("v1.0.0", "v1.1.0", "v1.2.0"):
        add_proxy_module(proxy, "example.com/core", version)
    add_proxy_module(proxy, "example.com/exporter", "v1.0.0", {"example.com/core": "v1.0.0"})
    add_proxy_module(proxy, "example.com/exporter", "v1.2.0", {"example.com/core": "v1.1.0"})
    workspace_root = root / "checkout"
    workspace_root.mkdir()
    workspace_root.joinpath("go.mod").write_text(
        "module example.com/app\n\ngo 1.25\n\nrequire (\n\texample.com/core v1.0.0\n\texample.com/exporter v1.0.0\n)\n",
        encoding="utf-8",
    )
    workspace_root.joinpath("main.go").write_text(
        'package main\nimport core "example.com/core"\nimport exporter "example.com/exporter"\nfunc main() { _, _ = core.Value(), exporter.Value() }\n',
        encoding="utf-8",
    )
    environment = dict(os.environ, GOPROXY=proxy.resolve().as_uri(), GOSUMDB="off", GOMODCACHE=str(root / "cache"), GOTOOLCHAIN="local", GOWORK="off")
    subprocess.run(["go", "mod", "tidy"], cwd=workspace_root, env=environment, check=True, capture_output=True)
    exporter_vulnerable = stream(
        osv("GO-EXPORTER", "example.com/exporter", "v1.2.0"),
        finding("GO-EXPORTER", "example.com/exporter", "v1.0.0"),
    )
    core_vulnerable = stream(
        osv("GO-CORE", "example.com/core", "v1.2.0"),
        finding("GO-CORE", "example.com/core", "v1.1.0"),
    )
    scanner = sequence_scanner(root, [(exporter_vulnerable, 3), (core_vulnerable, 3), (stream(), 0)], package="./...")
    real_go = shutil.which("go")
    assert real_go
    binary_dir = root / "bin"
    binary_dir.mkdir()
    log = root / "go.log"
    wrapper = binary_dir / "go"
    wrapper.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GO_LOG\"\nexec \"$REAL_GO\" \"$@\"\n", encoding="utf-8")
    wrapper.chmod(0o755)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment, PATH=f"{binary_dir}:{os.environ['PATH']}", REAL_GO=real_go, GO_LOG=str(log))
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(workspace_root), "./..."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    go_mod = workspace_root.joinpath("go.mod").read_text(encoding="utf-8")
    assert "example.com/exporter v1.2.0" in go_mod
    assert "example.com/core v1.2.0" in go_mod
    commands = log.read_text(encoding="utf-8").splitlines()
    assert "get example.com/exporter@v1.2.0" in commands
    assert "get example.com/core@v1.2.0" in commands
    assert root.joinpath("scan-state").read_text(encoding="utf-8") == "3"


def test_package_inputs(module, root: Path) -> None:
    glob = root / "glob"
    glob.mkdir()
    _, _, _ = run_resolver(module, glob, package="./...")
    commands = glob.joinpath("go.log").read_text(encoding="utf-8").splitlines()
    assert "list -deps -mod=readonly ./..." in commands
    assert any(command.startswith("build -mod=readonly -o ") and command.endswith(" ./...") for command in commands)

    option = root / "option"
    option.mkdir()
    workspace_root, module_root, environment = prepare_project(option, False, False)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(option / "missing-scanner"), str(workspace_root), str(module_root), "-test"]
    try:
        assert_raises(module.RemediationError, "invalid Go package patterns", module.main)
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)


def test_pipeline_contract() -> None:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    assert pipeline.count("go install golang.org/x/vuln/cmd/govulncheck@v1.7.0") == 1
    assert "@latest" not in pipeline and "go run golang.org/x/vuln" not in pipeline
    assert "go-remediation-evidence" not in pipeline and "lockContentHash" not in pipeline
    assert "default: ./..." in pipeline and "github.com/gorilla/websocket" not in pipeline
    assert "set -f" in pipeline and 'package.startswith("-")' in pipeline
    assert "- uses: go/remediate" in ROOT.joinpath("images/etcd/melange.yaml").read_text(encoding="utf-8")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_scan_contract(module, root)
        test_fix_selection(module)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_reconciliation_modes(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_no_compatible_fix_continues(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_package_graph_and_post_scan_failures(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_package_inputs(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_outer_pass_limit(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_outer_no_progress(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_apply_loop_rechecks_current_versions(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_interdependent_fixes(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_newly_exposed_fixes_converge(module, root)
    test_pipeline_contract()
    print("passed scripts/test_go_remediation.py")


if __name__ == "__main__":
    main()
