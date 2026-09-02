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


def stream(
    *items: dict,
    version: str = "v1.7.0",
    scanner: str = "govulncheck",
    protocol: str = "v1.0.0",
    scan_level: str = "symbol",
    scan_mode: str = "source",
) -> str:
    values = [{"config": {"protocol_version": protocol, "scanner_name": scanner, "scanner_version": version, "scan_level": scan_level, "scan_mode": scan_mode}}]
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

def osv_scan(identifier: str, module: str, version: str, *fixes: str) -> str:
    vulnerability = osv(identifier, module, *fixes)["osv"]
    return json.dumps({
        "results": [{
            "packages": [{
                "package": {"name": module, "version": version.removeprefix("v"), "ecosystem": "Go"},
                "vulnerabilities": [vulnerability],
            }],
        }],
    })


def fake_module_scanner(root: Path, raw: str, status: int, stderr: str = "") -> Path:
    scanner = root / "osv-scanner"
    scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import sys\n"
        "args = sys.argv[1:]\n"
        "assert args[:5] == ['scan', 'source', '--format=json', '--all-vulns', '--lockfile']\n"
        "assert args[5].endswith('/go.mod')\n"
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
    for raw in (
        stream(scanner="other"),
        stream(protocol="v2.0.0"),
        stream(version="v1.8.0"),
        stream(scan_level="module"),
        stream(scan_mode="binary"),
    ):
        assert_raises(module.RemediationError, "govulncheck", lambda raw=raw: module.scan(fake_scanner(root, raw, 0), root, ["."]))


def test_module_scan_contract(module, root: Path) -> None:
    dependency = "google.golang.org/grpc"
    raw = osv_scan("GHSA-vp52-pcj8-j9qc", dependency, "v1.82.1", "v1.83.1")
    messages = module.scan_modules(root, fake_module_scanner(root, raw, 1))
    updates, unresolved, detected, fixable = module.derive_fixes([{"config": {}}, *messages], {dependency: "v1.82.1"})
    assert updates == {dependency: "v1.83.1"}
    assert unresolved == []
    assert detected == {("GHSA-vp52-pcj8-j9qc", dependency)}
    assert fixable == detected
    assert module.scan_modules(root, fake_module_scanner(root, '{"results": []}', 0)) == []
    assert_raises(
        module.RemediationError,
        "unexpected OSV-Scanner exit status 2",
        lambda: module.scan_modules(root, fake_module_scanner(root, "", 2, "scanner failed\n")),
    )
    for raw in ("", "not-json", '{"results": {}}'):
        assert_raises(
            module.RemediationError,
            "OSV-Scanner",
            lambda raw=raw: module.scan_modules(root, fake_module_scanner(root, raw, 1)),
        )
    previous_limit = module.MAX_OUTPUT_BYTES
    module.MAX_OUTPUT_BYTES = 32
    try:
        assert_raises(
            module.RemediationError,
            "OSV-Scanner stdout exceeds 32 MiB",
            lambda: module.scan_modules(root, fake_module_scanner(root, "x" * 33, 1)),
        )
    finally:
        module.MAX_OUTPUT_BYTES = previous_limit

    assert module.version_key("v19.03.0") == module.version_key("v19.3.0")


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

    legacy = "example.com/legacy"
    updates, unresolved, detected, fixable = module.derive_fixes(
        module.parse_stream(stream(osv("GO-LEGACY", legacy, "v28.0.0"), finding("GO-LEGACY", legacy, "v27.0.0+incompatible"))),
        {legacy: "v27.0.0+incompatible"},
    )
    assert updates == {legacy: "v28.0.0"}
    assert unresolved == []
    assert detected == {("GO-LEGACY", legacy)} and fixable == detected

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
    source: str = "package dependency\nfunc Value() int { return 1 }\n",
    files: dict[str, str] | None = None,
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
        for path, content in (files or {"dependency.go": source}).items():
            archive.writestr(prefix + path, content)


def prepare_project(
    root: Path,
    workspace: bool,
    vendor: bool,
    dependency_source: str = "package dependency\nfunc Value() int { return 1 }\n",
) -> tuple[Path, Path, dict[str, str]]:
    proxy = root / "proxy"
    for version in ("v1.0.0", "v1.2.0", "v1.3.0"):
        add_proxy_module(proxy, "example.com/dependency", version, source=dependency_source)
    workspace_root = root / "checkout"
    module_root = workspace_root / "server" if workspace else workspace_root
    module_root.mkdir(parents=True)
    module_root.joinpath("go.mod").write_text("module example.com/app\n\ngo 1.25\n\ntoolchain go1.25.0\n\nrequire example.com/dependency v1.0.0\n", encoding="utf-8")
    module_root.joinpath("main.go").write_text('package main\nimport "example.com/dependency"\nfunc main() { var value int = dependency.Value(); _ = value }\n', encoding="utf-8")
    environment = dict(os.environ, GOPROXY=proxy.resolve().as_uri(), GOSUMDB="off", GOMODCACHE=str(root / "cache"), GOTOOLCHAIN="local", GOWORK="off")
    subprocess.run(["go", "mod", "tidy"], cwd=module_root, env=environment, check=True, capture_output=True)
    if workspace:
        replacement = workspace_root / "replacement"
        replacement.mkdir()
        replacement.joinpath("go.mod").write_text("module example.com/dependency\n\ngo 1.25\n", encoding="utf-8")
        replacement.joinpath("dependency.go").write_text("package dependency\nfunc Value() int { return 1 }\n", encoding="utf-8")
        workspace_root.joinpath("go.work").write_text(
            "go 1.25\n\ntoolchain go1.25.0\n\nuse ./server\n\nreplace example.com/dependency => ./replacement\n",
            encoding="utf-8",
        )
        workspace_environment = dict(environment, GOWORK=str(workspace_root / "go.work"))
        subprocess.run(["go", "work", "sync"], cwd=workspace_root, env=workspace_environment, check=True, capture_output=True)
        if vendor:
            subprocess.run(["go", "work", "vendor"], cwd=workspace_root, env=workspace_environment, check=True, capture_output=True)
    elif vendor:
        subprocess.run(["go", "mod", "vendor"], cwd=module_root, env=environment, check=True, capture_output=True)
    subprocess.run(
        ["go", "mod", "edit", "-toolchain=go1.25.0"],
        cwd=module_root,
        env=environment,
        check=True,
        capture_output=True,
    )
    if workspace:
        subprocess.run(
            ["go", "work", "edit", "-toolchain=go1.25.0"],
            cwd=workspace_root,
            env=dict(environment, GOWORK=str(workspace_root / "go.work")),
            check=True,
            capture_output=True,
        )
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
    fake_module_scanner(root, '{"results": []}', 0)
    return scanner


def install_command_wrappers(root: Path) -> tuple[Path, Path, str]:
    real_go = shutil.which("go")
    assert real_go
    binary_dir = root / "bin"
    binary_dir.mkdir()
    go_log = root / "go.log"
    go_wrapper = binary_dir / "go"
    go_wrapper.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GO_LOG\"\nexec \"$REAL_GO\" \"$@\"\n", encoding="utf-8")
    go_wrapper.chmod(0o755)
    omnibump = binary_dir / "omnibump"
    omnibump.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, subprocess, sys\n"
        "args = sys.argv[1:]\n"
        "assert args[args.index('--language') + 1] == 'go'\n"
        "assert os.environ.get('GOTOOLCHAIN') == 'local'\n"
        "if args[0] == 'analyze':\n"
        "    packages = args[args.index('--packages') + 1].split()\n"
        "    updates = [{'Name': item.rsplit('@', 1)[0], 'Version': item.rsplit('@', 1)[1]} for item in packages]\n"
        "    updates.extend(json.loads(os.environ.get('OMNIBUMP_COUPDATES', '[]')))\n"
        "    print(json.dumps({'analysis': {}, 'strategy': {'DirectUpdates': updates}}))\n"
        "    raise SystemExit(0)\n"
        "with open(os.environ['OMNIBUMP_LOG'], 'a', encoding='utf-8') as log:\n"
        "    log.write(json.dumps(args) + '\\n')\n"
        "assert '--tidy=false' in args\n"
        "if error := os.environ.get('OMNIBUMP_ERROR'):\n"
        "    print(error, file=sys.stderr)\n"
        "    raise SystemExit(42)\n"
        "print('omnibump: transitive co-update analysis complete', file=sys.stderr)\n"
        "directory = args[args.index('--dir') + 1]\n"
        "completed = subprocess.run([os.environ['REAL_GO'], 'mod', 'edit', '-go=1.24', '-toolchain=none'], cwd=directory, env=os.environ, check=False)\n"
        "if completed.returncode:\n"
        "    raise SystemExit(completed.returncode)\n"
        "gowork = os.environ.get('GOWORK')\n"
        "if gowork and gowork != 'off':\n"
        "    completed = subprocess.run([os.environ['REAL_GO'], 'work', 'edit', '-go=1.24', '-toolchain=none'], cwd=os.path.dirname(gowork), env=os.environ, check=False)\n"
        "    if completed.returncode:\n"
        "        raise SystemExit(completed.returncode)\n"
        "packages = args[args.index('--packages') + 1].split()\n"
        "for package in packages:\n"
        "    completed = subprocess.run([os.environ['REAL_GO'], 'mod', 'edit', '-require=' + package], cwd=directory, env=os.environ, check=False)\n"
        "    if completed.returncode:\n"
        "        raise SystemExit(completed.returncode)\n",
        encoding="utf-8",
    )
    omnibump.chmod(0o755)
    module_scanner = binary_dir / "osv-scanner"
    module_scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys\n"
        "args = sys.argv[1:]\n"
        "assert args[:5] == ['scan', 'source', '--format=json', '--all-vulns', '--lockfile']\n"
        "assert args[5].endswith('/go.mod')\n"
        "print(json.dumps({'results': []}))\n",
        encoding="utf-8",
    )
    module_scanner.chmod(0o755)
    return binary_dir, go_log, real_go


def omnibump_commands(root: Path) -> list[list[str]]:
    return [json.loads(line) for line in root.joinpath("omnibump.log").read_text(encoding="utf-8").splitlines()]


def run_resolver(
    module,
    root: Path,
    workspace: bool = False,
    vendor: bool = False,
    after: str | None = None,
    package: str = ".",
    omnibump_error: str | None = None,
    root_workspace: bool = False,
    vendor_patches: str = "",
) -> tuple[Path, Path, str]:
    workspace_root, module_root, environment = prepare_project(root, workspace, vendor)
    if root_workspace:
        assert not workspace
        workspace_root.joinpath("go.work").write_text("go 1.25\n\ntoolchain go1.25.0\n\nuse .\n", encoding="utf-8")
        environment["GOWORK"] = str(workspace_root / "go.work")
        subprocess.run(["go", "work", "sync"], cwd=workspace_root, env=environment, check=True, capture_output=True)
        if vendor:
            subprocess.run(["go", "work", "vendor"], cwd=workspace_root, env=environment, check=True, capture_output=True)
    vulnerable = stream(osv("GO-1", "example.com/dependency", "v1.2.0"), finding("GO-1", "example.com/dependency", "v1.0.0"))
    expected_gowork = str(workspace_root / "go.work") if workspace or root_workspace else "off"
    scanner = sequence_scanner(
        root,
        [(vulnerable, 3), (after if after is not None else stream(), 0 if after is None else 3)],
        package,
        expected_gowork,
    )
    binary_dir, _, real_go = install_command_wrappers(root)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(root / "go.log"),
        OMNIBUMP_LOG=str(root / "omnibump.log"),
    )
    if omnibump_error is not None:
        os.environ["OMNIBUMP_ERROR"] = omnibump_error
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), vendor_patches, package]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
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
        go_mod = module_root.joinpath("go.mod").read_text(encoding="utf-8")
        assert "example.com/dependency v1.2.0" in go_mod
        assert "\ngo 1.25\n" in go_mod
        commands = case.joinpath("go.log").read_text(encoding="utf-8").splitlines()
        assert not any(command.startswith("get ") for command in commands)
        assert omnibump_commands(case) == [[
            "--language", "go", "--dir", str(module_root),
            "--packages", "example.com/dependency@v1.2.0", "--tidy=false",
        ]]
        assert "omnibump: transitive co-update analysis complete" in output
        assert any(command.startswith(f"build -mod={expected_mode} -o ") and command.endswith(" .") for command in commands)
        if workspace:
            assert "work sync" in commands
            assert workspace_root.joinpath("vendor/modules.txt").is_file()
        else:
            assert "list -deps -mod=mod ." in commands
            if vendor:
                assert "mod vendor" in commands
                assert module_root.joinpath("vendor/modules.txt").is_file()
        assert "go remediation: applying example.com/dependency@v1.2.0" in output


def test_requested_updates_populate_sums(module, root: Path) -> None:
    _, module_root, _ = run_resolver(module, root)
    assert "example.com/dependency v1.2.0" in module_root.joinpath("go.mod").read_text(encoding="utf-8")
    assert omnibump_commands(root) == [[
        "--language", "go", "--dir", str(module_root),
        "--packages", "example.com/dependency@v1.2.0", "--tidy=false",
    ]]
    commands = root.joinpath("go.log").read_text(encoding="utf-8").splitlines()
    download = "mod download example.com/dependency@v1.2.0"
    assert download in commands
    assert commands.index(download) < commands.index("list -deps -mod=mod .")
    assert commands.index("list -deps -mod=mod .") < commands.index("list -deps -mod=readonly .")
    assert "example.com/dependency v1.2.0/go.mod" in module_root.joinpath("go.sum").read_text(encoding="utf-8")


def test_package_scoped_reconciliation_ignores_broken_tests(module, root: Path) -> None:
    root.joinpath("go.mod").write_text("module example.com/app\n\ngo 1.25\n", encoding="utf-8")
    root.joinpath("main.go").write_text("package main\nfunc main() {}\n", encoding="utf-8")
    root.joinpath("main_test.go").write_text(
        'package main\nimport _ "example.com/removed/package"\n',
        encoding="utf-8",
    )
    environment = dict(os.environ, GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOWORK="off")
    failed = subprocess.run(
        ["go", "mod", "tidy"], cwd=root, env=environment, check=False, capture_output=True
    )
    assert failed.returncode != 0
    previous_environ = os.environ.copy()
    os.environ.update(environment)
    try:
        module.reconcile(root, root, ["."], None, [])
    finally:
        os.environ.clear()
        os.environ.update(previous_environ)


def test_requested_update_preserves_split_pattern_types(module, root: Path) -> None:
    proxy = root / "proxy"
    runtime = "example.com/family/runtime"
    component = "example.com/family/component"
    patterns = "example.com/patterns"
    for version in ("v1.0.0", "v1.2.0"):
        add_proxy_module(proxy, runtime, version)
    add_proxy_module(
        proxy,
        patterns,
        "v1.0.0",
        files={"gitignore/pattern.go": "package gitignore\ntype Pattern struct{}\n"},
    )
    add_proxy_module(
        proxy,
        component,
        "v0.1.0",
        {patterns: "v1.0.0"},
        files={
            "sourceignore/source.go": (
                'package sourceignore\nimport "example.com/patterns/gitignore"\n'
                "func Accept(_ []gitignore.Pattern) {}\n"
            )
        },
    )
    add_proxy_module(
        proxy,
        component,
        "v0.2.0",
        files={
            "sourceignore/source.go": (
                "package sourceignore\ntype Pattern struct{}\nfunc Accept(_ []Pattern) {}\n"
            )
        },
    )
    project = root / "checkout"
    project.mkdir()
    project.joinpath("go.mod").write_text(
        "module example.com/app\n\ngo 1.25\n\nrequire (\n"
        f"\t{runtime} v1.0.0\n\t{component} v0.1.0\n\t{patterns} v1.0.0\n)\n",
        encoding="utf-8",
    )
    project.joinpath("main.go").write_text(
        "package main\n"
        f'import runtime "{runtime}"\n'
        f'import "{component}/sourceignore"\n'
        f'import "{patterns}/gitignore"\n'
        "func main() { sourceignore.Accept([]gitignore.Pattern{}); _ = runtime.Value() }\n",
        encoding="utf-8",
    )
    environment = dict(
        os.environ,
        GOPROXY=proxy.resolve().as_uri(),
        GOSUMDB="off",
        GOMODCACHE=str(root / "cache"),
        GOTOOLCHAIN="local",
        GOWORK="off",
    )
    subprocess.run(["go", "mod", "tidy"], cwd=project, env=environment, check=True, capture_output=True)
    vulnerable = stream(osv("GO-1", runtime, "v1.2.0"), finding("GO-1", runtime, "v1.0.0"))
    scanner = sequence_scanner(root, [(vulnerable, 3), (stream(), 0)])
    binary_dir, _, real_go = install_command_wrappers(root)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(root / "go.log"),
        OMNIBUMP_LOG=str(root / "omnibump.log"),
        OMNIBUMP_COUPDATES=json.dumps([{
            "Name": component,
            "Version": "v0.2.0",
            "Metadata": {
                "required_by": "transitive dependency check",
                "reason": f"{runtime}@v1.2.0 requires {component}@v0.2.0 but project has v0.1.0",
            },
        }]),
    )
    sys.argv = ["remediate.py", str(scanner), str(project), str(project), "", "."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    go_mod = project.joinpath("go.mod").read_text(encoding="utf-8")
    assert f"{runtime} v1.2.0" in go_mod
    assert f"{component} v0.1.0" in go_mod
    assert omnibump_commands(root)[0][5] == f"{runtime}@v1.2.0"


def test_workspace_transitive_candidate_uses_module_root(module, root: Path) -> None:
    dependency = "example.com/transitive"
    workspace_root, module_root, environment = prepare_project(root, True, False)
    module_root.joinpath("go.mod").write_text(
        "module example.com/app\n\ngo 1.25 // module policy\n\ntoolchain go1.25.0 // pinned\n",
        encoding="utf-8",
    )
    sibling = workspace_root / "sibling"
    sibling.mkdir()
    sibling.joinpath("go.mod").write_text(
        "module example.com/sibling\n\ngo 1.25\n\nrequire example.com/transitive v1.0.0\n",
        encoding="utf-8",
    )
    sibling.joinpath("main.go").write_text("package main\nfunc main() {}\n", encoding="utf-8")
    work_path = workspace_root / "go.work"
    work_content = work_path.read_text(encoding="utf-8").replace(
        "go 1.25", "go 1.25 // workspace policy", 1
    ).replace("toolchain go1.25.0", "toolchain go1.25.0 // pinned", 1)
    work_path.write_text(
        work_content.replace("use ./server", "use (\n\t./server\n\t./sibling\n)"),
        encoding="utf-8",
    )
    original_module_directives = tuple(
        line for line in module_root.joinpath("go.mod").read_text(encoding="utf-8").splitlines()
        if line.startswith(("go ", "toolchain "))
    )
    original_workspace_directives = tuple(
        line for line in work_path.read_text(encoding="utf-8").splitlines()
        if line.startswith(("go ", "toolchain "))
    )
    vulnerable = module.parse_stream(stream(
        osv("GO-TRANSITIVE", dependency, "v1.2.0"),
        finding("GO-TRANSITIVE", dependency, "v1.0.0"),
    ))
    scans = iter((vulnerable, module.parse_stream(stream())))
    module.scan = lambda *_args, **_kwargs: next(scans)

    def selected_modules(*_args, **_kwargs):
        go_mod = module_root.joinpath("go.mod").read_text(encoding="utf-8")
        version = "v1.2.0" if "example.com/transitive v1.2.0" in go_mod else "v1.0.0"
        return {dependency: version}

    module.selected_modules = selected_modules
    module.reconcile = lambda *_args, **_kwargs: None
    binary_dir, _, real_go = install_command_wrappers(root)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(root / "go.log"),
        OMNIBUMP_LOG=str(root / "omnibump.log"),
    )
    sys.argv = ["remediate.py", str(root / "scanner"), str(workspace_root), str(module_root), "", "."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    assert "example.com/transitive v1.2.0" in module_root.joinpath("go.mod").read_text(encoding="utf-8")
    assert omnibump_commands(root)[0][3] == str(module_root)
    assert "example.com/transitive v1.0.0" in sibling.joinpath("go.mod").read_text(encoding="utf-8")
    go_mod = module_root.joinpath("go.mod").read_text(encoding="utf-8")
    go_work = workspace_root.joinpath("go.work").read_text(encoding="utf-8")
    assert tuple(line for line in go_mod.splitlines() if line.startswith(("go ", "toolchain "))) == original_module_directives
    assert tuple(line for line in go_work.splitlines() if line.startswith(("go ", "toolchain "))) == original_workspace_directives


def test_workspace_root_module_supported(module, root: Path) -> None:
    workspace_root, module_root, _ = run_resolver(module, root, vendor=True, root_workspace=True)
    assert workspace_root == module_root
    commands = root.joinpath("go.log").read_text(encoding="utf-8").splitlines()
    assert "work sync" in commands
    assert "work vendor" in commands
    assert "mod vendor" not in commands
    assert any(command.startswith("build -mod=vendor -o ") for command in commands)


def test_workspace_escape_rejected(module, root: Path) -> None:
    root.joinpath("go.mod").write_text("module example.com/app\n\ngo 1.25\n", encoding="utf-8")
    workspace = root / "workspace"
    workspace.mkdir()
    previous_argv = sys.argv
    sys.argv = ["remediate.py", str(root / "scanner"), str(workspace), str(root), "", "."]
    try:
        assert_raises(module.RemediationError, "module root escapes workspace", module.main)
    finally:
        sys.argv = previous_argv




def test_build_failure_targets_package_preserving_consumer(module, root: Path) -> None:
    error = module.CommandError(
        ["go", "build", "-mod=readonly", "."],
        1,
        "",
        "# example.com/client/applyconfiguration\n"
        "cannot use example.com/schema/v4.Type as example.com/schema/v6.Type\n",
    )
    selected = {
        "example.com/client": "v1.0.0",
        "example.com/schema/v4": "v4.0.0",
        "example.com/schema/v6": "v6.0.0",
        "example.com/unrelated": "v1.0.0",
    }
    module.available_upgrades = lambda *_args: ["v1.1.0", "v1.2.0"]
    module.candidate_contains_packages = (
        lambda _root, dependency, version, packages: dependency == "example.com/client"
        and version == "v1.2.0"
        and packages == ["example.com/client/applyconfiguration"]
    )
    assert module.build_failure_updates(error, root, selected) == [("example.com/client", "v1.2.0")]


def test_build_failure_reconciliation_is_bounded_and_targeted(module, root: Path) -> None:
    dependency = "example.com/client"
    selected = {dependency: "v1.0.0", "example.com/unrelated": "v1.0.0"}
    attempts = 0
    applied = []
    required_sums = []

    def reconcile(*args, **_kwargs):
        nonlocal attempts
        attempts += 1
        required_sums.append(args[-1])
        if attempts == 1:
            raise module.CommandError(
                ["go", "build", "-mod=readonly", "."],
                1,
                "",
                "# example.com/client/applyconfiguration\ntype mismatch\n",
            )

    def apply_updates(_root, requested, _workspace, action="applying"):
        applied.append((requested, action))
        selected[dependency] = requested[0][1]

    module.reconcile = reconcile
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.build_failure_updates = lambda *_args, **_kwargs: [(dependency, "v1.2.0")]
    module.apply_updates = apply_updates
    assert module.reconcile_with_compatibility(root, root, ["."], None, [], 0) == 1
    assert attempts == 2
    assert applied == [([(dependency, "v1.2.0")], "repairing compatibility")]
    assert required_sums == [(), [(dependency, "v1.2.0")]]


def test_disjoint_vulnerability_ranges_continue_to_fixed_point(module, root: Path) -> None:
    dependency = "example.com/runtime"
    record = {
        "osv": {
            "id": "GO-RANGES",
            "affected": [{
                "package": {"name": dependency, "ecosystem": "Go"},
                "ranges": [{
                    "type": "SEMVER",
                    "events": [
                        {"introduced": "0"},
                        {"fixed": "1.2.0"},
                        {"introduced": "1.3.0"},
                        {"fixed": "1.4.0"},
                    ],
                }],
            }],
        }
    }
    vulnerable = module.parse_stream(stream(record, finding("GO-RANGES", dependency, "v1.0.0")))
    scans = iter((vulnerable, vulnerable, module.parse_stream(stream())))
    selected = {dependency: "v1.0.0"}
    commands = []
    module.scan = lambda *_args, **_kwargs: next(scans)
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.reconcile = lambda *_args, **_kwargs: None

    def run_go(arguments, *_args, **_kwargs):
        commands.append(arguments)
        request = arguments[arguments.index("--packages") + 1]
        target = request.rsplit("@", 1)[1]
        selected[dependency] = "v1.3.0" if target == "v1.2.0" else target
        return ""

    module.run_go = run_go
    invoke_main(module, root)
    assert [command[command.index("--packages") + 1] for command in commands] == [
        f"{dependency}@v1.2.0",
        f"{dependency}@v1.4.0",
    ]


def test_vendor_patch_precedes_vendored_build(module, root: Path) -> None:
    broken = 'package dependency\nfunc Value() string { return "broken" }\n'
    workspace_root, module_root, environment = prepare_project(root, False, True, dependency_source=broken)
    failed = subprocess.run(
        ["go", "build", "-mod=vendor", "."],
        cwd=module_root,
        env=environment,
        check=False,
        capture_output=True,
    )
    assert failed.returncode != 0
    patch = workspace_root / "vendor-source.patch"
    patch.write_text(
        "--- a/vendor/example.com/dependency/dependency.go\n"
        "+++ b/vendor/example.com/dependency/dependency.go\n"
        "@@ -1,2 +1,2 @@\n"
        " package dependency\n"
        '-func Value() string { return "broken" }\n'
        "+func Value() int { return 1 }\n",
        encoding="utf-8",
    )
    previous_environ = os.environ.copy()
    os.environ.update(environment)
    try:
        patches = module.resolve_vendor_patches(workspace_root, patch.name)
        module.reconcile(workspace_root, module_root, ["."], None, patches)
    finally:
        os.environ.clear()
        os.environ.update(previous_environ)
    vendored = module_root / "vendor/example.com/dependency/dependency.go"
    assert "func Value() int" in vendored.read_text(encoding="utf-8")


def test_vendor_patch_escape_rejected(module, root: Path) -> None:
    workspace = root / "workspace"
    workspace.mkdir(exist_ok=True)
    root.joinpath("outside.patch").write_text("not a patch\n", encoding="utf-8")
    assert_raises(
        module.RemediationError,
        "vendor patch escapes workspace",
        lambda: module.resolve_vendor_patches(workspace, "../outside.patch"),
    )


def test_no_compatible_fix_continues(module, root: Path) -> None:
    workspace_root, module_root, environment = prepare_project(root, False, False)
    incompatible = "example.com/dependency/v2"
    raw = stream(osv("GO-2", incompatible, "v3.0.0"), finding("GO-2", incompatible, "v2.0.0"))
    scanner = sequence_scanner(root, [(raw, 3), (raw, 3)])
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    previous_scan_modules = module.scan_modules
    module.scan_modules = lambda *_args, **_kwargs: []
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "", "."]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            module.main()
    finally:
        module.scan_modules = previous_scan_modules
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    assert "no-compatible-fix" in output.getvalue()


def test_incompatible_candidate_reaches_omnibump(module, root: Path) -> None:
    legacy = "example.com/legacy"
    vulnerable = module.parse_stream(stream(
        osv("GO-LEGACY", legacy, "v28.0.0"),
        finding("GO-LEGACY", legacy, "v27.0.0+incompatible"),
    ))
    scans = iter((vulnerable, module.parse_stream(stream())))
    selected = {legacy: "v27.0.0+incompatible"}
    commands = []

    module.scan = lambda *_args, **_kwargs: next(scans)
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.reconcile = lambda *_args, **_kwargs: None

    def run_go(arguments, _root, capture=False, workspace=None, report=False):
        assert workspace is None
        if arguments[0] == "go":
            return json.dumps({"Go": "1.25", "Toolchain": None}) if capture else ""
        assert not capture and report
        commands.append(arguments)
        selected[legacy] = "v28.0.0+incompatible"
        return ""

    module.run_go = run_go
    invoke_main(module, root)
    assert commands == [[
        "omnibump", "--language", "go", "--dir", str(root),
        "--packages", f"{legacy}@v28.0.0", "--tidy=false",
    ]]


def test_package_graph_and_post_scan_failures(module, root: Path) -> None:
    graph = root / "graph"
    graph.mkdir()
    workspace_root, module_root, environment = prepare_project(graph, False, False)
    scanner = sequence_scanner(graph, [(stream(), 0)], package="./missing")
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "", "./missing"]
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
    binary_dir, _, real_go = install_command_wrappers(unavailable)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(unavailable / "go.log"),
        OMNIBUMP_LOG=str(unavailable / "omnibump.log"),
    )
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(module_root), "", "."]
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
    binary_dir, go_log, real_go = install_command_wrappers(root)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(go_log),
        OMNIBUMP_LOG=str(root / "omnibump.log"),
    )
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(workspace_root), "", "./..."]
    try:
        module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    go_mod = workspace_root.joinpath("go.mod").read_text(encoding="utf-8")
    assert "example.com/high v1.2.0" in go_mod
    assert "example.com/low v1.3.0" in go_mod
    assert not any(command.startswith("get ") for command in go_log.read_text(encoding="utf-8").splitlines())
    assert omnibump_commands(root) == [[
        "--language", "go", "--dir", str(workspace_root),
        "--packages", "example.com/high@v1.2.0 example.com/low@v1.2.0", "--tidy=false",
    ]]


def test_omnibump_errors_are_loud(module, root: Path) -> None:
    error = "required co-update example.com/peer@v1.3.0"
    assert_raises(
        module.RemediationError,
        error,
        lambda: run_resolver(module, root, omnibump_error=error),
    )
    assert root.joinpath("scan-state").read_text(encoding="utf-8") == "1"
    assert len(omnibump_commands(root)) == 1
    commands = root.joinpath("go.log").read_text(encoding="utf-8").splitlines()
    assert not any(command.startswith("list -deps -mod=mod ") for command in commands)


def invoke_main(module, root: Path) -> None:
    if not root.joinpath("go.mod").exists():
        root.joinpath("go.mod").write_text("module example.com/app\n\ngo 1.25\n", encoding="utf-8")
    previous_argv = sys.argv
    previous_scan_modules = module.scan_modules
    module.scan_modules = lambda *_args, **_kwargs: []
    sys.argv = ["remediate.py", str(root / "scanner"), str(root), str(root), "", "."]
    try:
        module.main()
    finally:
        module.scan_modules = previous_scan_modules
        sys.argv = previous_argv


def test_outer_pass_limit(module, root: Path) -> None:
    limit = module.MAX_REMEDIATION_PASSES
    selected = {f"example.com/dependency{index}": "v1.0.0" for index in range(limit + 1)}
    scans = 0

    def scan(*_args, **_kwargs):
        nonlocal scans
        scans += 1
        return []

    def derive_fixes(_messages, _selected):
        index = scans - 1
        dependency = f"example.com/dependency{index}"
        identity = (f"GO-{index}", dependency)
        return {dependency: "v1.1.0"}, [], {identity}, {identity}

    def run_go(arguments, _root, capture=False, workspace=None, report=False):
        assert workspace is None
        if arguments[0] == "go":
            return json.dumps({"Go": "1.25", "Toolchain": None}) if capture else ""
        assert not capture and report
        requests = arguments[arguments.index("--packages") + 1].split()
        for request in requests:
            dependency, version = request.rsplit("@", 1)
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
    module.scan = lambda *_args, **_kwargs: []
    module.selected_modules = lambda *_args, **_kwargs: dict(selected)
    module.derive_fixes = lambda *_args, **_kwargs: ({dependency: "v1.2.0"}, [], {identity}, {identity})
    def run_go(arguments, _root, capture=False, workspace=None, report=False):
        assert workspace is None
        if capture:
            assert arguments == ["go", "mod", "edit", "-json"]
            return json.dumps({"Go": "1.25", "Toolchain": None})
        return ""

    module.run_go = run_go
    module.reconcile = lambda *_args, **_kwargs: None
    assert_raises(
        module.RemediationError,
        "go remediation pass made no module graph progress",
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
    binary_dir, log, real_go = install_command_wrappers(root)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        environment,
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        REAL_GO=real_go,
        GO_LOG=str(log),
        OMNIBUMP_LOG=str(root / "omnibump.log"),
    )
    sys.argv = ["remediate.py", str(scanner), str(workspace_root), str(workspace_root), "", "./..."]
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
    assert not any(command.startswith("get ") for command in commands)
    assert omnibump_commands(root) == [
        ["--language", "go", "--dir", str(workspace_root), "--packages", "example.com/exporter@v1.2.0", "--tidy=false"],
        ["--language", "go", "--dir", str(workspace_root), "--packages", "example.com/core@v1.2.0", "--tidy=false"],
    ]
    assert root.joinpath("scan-state").read_text(encoding="utf-8") == "3"


def test_package_inputs(module, root: Path) -> None:
    glob = root / "glob"
    glob.mkdir()
    _, _, _ = run_resolver(module, glob, package="./...")
    commands = glob.joinpath("go.log").read_text(encoding="utf-8").splitlines()
    assert "list -deps -mod=mod ./..." in commands
    assert "list -deps -mod=readonly ./..." in commands
    assert any(command.startswith("build -mod=readonly -o ") and command.endswith(" ./...") for command in commands)

    option = root / "option"
    option.mkdir()
    workspace_root, module_root, environment = prepare_project(option, False, False)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(environment)
    sys.argv = ["remediate.py", str(option / "missing-scanner"), str(workspace_root), str(module_root), "", "-test"]
    try:
        assert_raises(module.RemediationError, "invalid Go package patterns", module.main)
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)


def test_pipeline_contract() -> None:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    assert pipeline.count("go install golang.org/x/vuln/cmd/govulncheck@v1.7.0") == 1
    assert pipeline.count("go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.5.1") == 1
    assert pipeline.count('"--all-vulns"') == 1
    assert "@latest" not in pipeline and "go run golang.org/x/vuln" not in pipeline
    assert "go-remediation-evidence" not in pipeline and "lockContentHash" not in pipeline
    assert "default: ./..." in pipeline and "github.com/gorilla/websocket" not in pipeline
    assert "set -f" in pipeline and 'package.startswith("-")' in pipeline
    assert '"omnibump", "analyze"' not in pipeline and "DirectUpdates" not in pipeline
    assert "vendor-patches:" in pipeline and "- patch" in pipeline
    assert "- uses: go/remediate" in ROOT.joinpath("images/etcd/melange.yaml").read_text(encoding="utf-8")


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_scan_contract(module, root)
        test_module_scan_contract(module, root)
        test_fix_selection(module)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_reconciliation_modes(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_workspace_transitive_candidate_uses_module_root(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_requested_updates_populate_sums(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_package_scoped_reconciliation_ignores_broken_tests(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_requested_update_preserves_split_pattern_types(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_workspace_root_module_supported(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_workspace_escape_rejected(module, root)
        test_vendor_patch_escape_rejected(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_build_failure_targets_package_preserving_consumer(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_build_failure_reconciliation_is_bounded_and_targeted(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_disjoint_vulnerability_ranges_continue_to_fixed_point(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_vendor_patch_precedes_vendored_build(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_no_compatible_fix_continues(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_incompatible_candidate_reaches_omnibump(module, root)
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
        test_interdependent_fixes(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_omnibump_errors_are_loud(module, root)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_newly_exposed_fixes_converge(module, root)
    test_pipeline_contract()
    print("passed scripts/test_go_remediation.py")


if __name__ == "__main__":
    main()
