#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "pipelines/cargo/remediate.yaml"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
CHECKSUM = "0" * 64
VERIFICATION = [["metadata", "--locked", "--format-version", "1"], ["fetch", "--locked"]]

OMNIBUMP = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import re
import sys

arguments = sys.argv[1:]
with open(os.environ["OMNIBUMP_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(arguments) + "\n")
assert arguments[arguments.index("--language") + 1] == "rust"
assert "--fail-on-unapplied-pins" in arguments
if error := os.environ.get("OMNIBUMP_ERROR"):
    print(error, file=sys.stderr)
    raise SystemExit(42)
print("omnibump: rust dependency graph analysis complete", file=sys.stderr)
directory = pathlib.Path(arguments[arguments.index("--dir") + 1])
pins = dict(pin.rsplit("@", 1) for pin in arguments[arguments.index("--packages") + 1].split())
mode = os.environ.get("OMNIBUMP_MODE", "collapse")
if mode == "noop":
    raise SystemExit(0)


def key(value):
    return tuple(int(part) for part in re.split(r"[.-]", value) if part.isdigit())


lock = directory / "Cargo.lock"
text = lock.read_text(encoding="utf-8")
for crate, requested in sorted(pins.items()):
    target = "0.0.1" if mode == "downgrade" else requested
    pattern = re.compile(r'(\[\[package\]\]\nname = "' + re.escape(crate) + r'"\nversion = ")([^"]+)(")')
    matches = list(pattern.finditer(text))
    skip = matches[0].start() if mode == "partial" and len(matches) > 1 else -1

    def replace(match, target=target, skip=skip):
        if match.start() == skip or (mode != "downgrade" and key(match.group(2)) >= key(target)):
            return match.group(0)
        return match.group(1) + target + match.group(3)

    text = pattern.sub(replace, text)
lock.write_text(text, encoding="utf-8")
for manifest in sorted(directory.rglob("Cargo.toml")):
    content = manifest.read_text(encoding="utf-8")
    for crate, requested in sorted(pins.items()):
        content = re.sub(
            r'(?m)^' + re.escape(crate) + r' = "[^"]+"$',
            crate + ' = "' + requested + '"',
            content,
        )
    manifest.write_text(content, encoding="utf-8")
'''

CARGO = r'''#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["CARGO_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if os.environ.get("CARGO_FAIL") == sys.argv[1]:
    print("cargo: simulated failure", file=sys.stderr)
    raise SystemExit(101)
'''


def extract_resolver(root: Path) -> Path:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool_dir/remediate.py\" <<'PYTHON'\n", 1)[1].split("      PYTHON\n", 1)[0]
    script = "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"
    path = root / "remediate.py"
    path.write_text(script, encoding="utf-8")
    return path


def load_resolver(root: Path):
    spec = importlib.util.spec_from_file_location("cargo_remediate", extract_resolver(root))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def vulnerability(
    identifier: str,
    crate: str,
    version: str,
    patched: tuple[str, ...] = (),
    unaffected: tuple[str, ...] = (),
) -> dict:
    return {
        "advisory": {"id": identifier, "package": crate, "title": identifier, "informational": None},
        "versions": {"patched": list(patched), "unaffected": list(unaffected)},
        "affected": None,
        "package": {
            "name": crate,
            "version": version,
            "source": REGISTRY,
            "checksum": CHECKSUM,
            "replace": None,
        },
    }


def warning(kind: str, crate: str, version: str, identifier: str | None = None) -> dict:
    package = {"name": crate, "version": version, "source": REGISTRY, "checksum": CHECKSUM, "replace": None}
    advisory = None if identifier is None else {"id": identifier, "package": crate, "informational": kind}
    return {"kind": kind, "package": package, "advisory": advisory, "affected": None}


def report(*items: dict, warnings: dict | None = None) -> str:
    return json.dumps(
        {
            "database": {"advisory-count": len(items), "last-commit": None, "last-updated": None},
            "lockfile": {"dependency-count": 2},
            "settings": {
                "target_arch": [],
                "target_os": [],
                "severity": None,
                "ignore": [],
                "informational_warnings": ["unmaintained", "unsound", "notice"],
            },
            "vulnerabilities": {"found": bool(items), "count": len(items), "list": list(items)},
            "warnings": warnings or {},
        }
    ) + "\n"


def findings(*items: dict, warnings: dict | None = None) -> tuple[str, int]:
    return report(*items, warnings=warnings), 1 if items else 0


def write_lock(path: Path, packages: tuple[tuple[str, str], ...]) -> None:
    body = "version = 4\n"
    for name, version in packages:
        body += f'\n[[package]]\nname = "{name}"\nversion = "{version}"\n'
        if name != "app":
            body += f'source = "{REGISTRY}"\nchecksum = "{CHECKSUM}"\n'
    path.write_text(body, encoding="utf-8")


def prepare_project(
    case: Path,
    packages: tuple[tuple[str, str], ...],
    dependencies: tuple[tuple[str, str], ...] = (),
    members: tuple[str, ...] = (),
) -> Path:
    project = case / "checkout"
    project.mkdir(parents=True)
    if members:
        manifest = "[workspace]\nmembers = [" + ", ".join(f'"{member}"' for member in members) + "]\n"
        for member in members:
            directory = project / member
            directory.mkdir(parents=True)
            body = f'[package]\nname = "{member}"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n'
            body += "".join(f'{crate} = "{requirement}"\n' for crate, requirement in dependencies)
            directory.joinpath("Cargo.toml").write_text(body, encoding="utf-8")
    else:
        manifest = '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n'
        manifest += "".join(f'{crate} = "{requirement}"\n' for crate, requirement in dependencies)
    project.joinpath("Cargo.toml").write_text(manifest, encoding="utf-8")
    write_lock(project / "Cargo.lock", packages)
    return project


def fake_scanner(
    case: Path,
    outputs: list[tuple[str, int]],
    lockfile: Path,
    version: str = "cargo-audit 0.22.2",
) -> Path:
    scanner = case / "cargo-audit"
    paths = []
    statuses = []
    for index, (raw, status) in enumerate(outputs):
        path = case / f"scan-{index}.json"
        path.write_text(raw, encoding="utf-8")
        paths.append(str(path))
        statuses.append(status)
    state = case / "scan-state"
    scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib, sys\n"
        f"if sys.argv[1:] == ['--version']:\n"
        f"    print({version!r})\n"
        "    raise SystemExit(0)\n"
        f"assert sys.argv[1:] == {['audit', '--json', '--color', 'never', '--file', str(lockfile)]!r}, sys.argv[1:]\n"
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


def install_command_wrappers(case: Path) -> Path:
    binary_dir = case / "bin"
    binary_dir.mkdir()
    for name, source in (("cargo", CARGO), ("omnibump", OMNIBUMP)):
        wrapper = binary_dir / name
        wrapper.write_text(source, encoding="utf-8")
        wrapper.chmod(0o755)
    return binary_dir


def logged(path: Path) -> list[list[str]]:
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def assert_raises(error_type, message: str, action) -> None:
    try:
        action()
    except error_type as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected {error_type.__name__}: {message}")


def run_main(
    module,
    case: Path,
    project: Path,
    scanner: Path,
    features: str = "",
    environment: dict[str, str] | None = None,
) -> str:
    install_command_wrappers(case)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        PATH=f"{case / 'bin'}:{os.environ['PATH']}",
        CARGO_LOG=str(case / "cargo.log"),
        OMNIBUMP_LOG=str(case / "omnibump.log"),
        **(environment or {}),
    )
    sys.argv = ["remediate.py", str(scanner), str(project), features]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    return output.getvalue()


def remediate(
    module,
    root: Path,
    name: str,
    outputs: list[tuple[str, int]],
    packages: tuple[tuple[str, str], ...],
    dependencies: tuple[tuple[str, str], ...] = (),
    members: tuple[str, ...] = (),
    features: str = "",
    environment: dict[str, str] | None = None,
) -> tuple[Path, Path, str]:
    case = root / name
    case.mkdir()
    project = prepare_project(case, packages, dependencies, members)
    scanner = fake_scanner(case, outputs, project / "Cargo.lock")
    output = run_main(module, case, project, scanner, features, environment)
    return case, project, output


def test_scan_contract(module, root: Path) -> None:
    case = root / "scan"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"), ("directvuln", "1.0.0")))
    lockfile = project / "Cargo.lock"
    vulnerable = report(vulnerability("RUSTSEC-2099-0001", "directvuln", "1.0.0", (">=1.2.0",)))

    def run(raw: str, status: int, version: str = "cargo-audit 0.22.2"):
        scanner = fake_scanner(case, [(raw, status)], lockfile, version)
        return module.scan(scanner, project, lockfile)

    assert run(vulnerable, 1)["vulnerabilities"]["count"] == 1
    assert run(report(), 0)["vulnerabilities"]["list"] == []
    assert_raises(module.RemediationError, "unexpected cargo-audit exit status 2", lambda: run(vulnerable, 2))
    assert_raises(module.RemediationError, "contradicts its vulnerability list", lambda: run(vulnerable, 0))
    assert_raises(module.RemediationError, "contradicts its vulnerability list", lambda: run(report(), 1))
    for raw in ("", "not-json\n", '{"vulnerabilities":', "[]\n", '{"vulnerabilities": {}}'):
        assert_raises(module.RemediationError, "cargo-audit", lambda raw=raw: run(raw, 1))
    inconsistent = json.dumps({"vulnerabilities": {"found": True, "count": 2, "list": []}})
    assert_raises(module.RemediationError, "invalid cargo-audit vulnerability summary", lambda: run(inconsistent, 1))
    mistyped = json.dumps({"vulnerabilities": {"found": True, "count": 0, "list": []}, "warnings": []})
    assert_raises(module.RemediationError, "invalid cargo-audit vulnerability summary", lambda: run(mistyped, 1))

    scanner = fake_scanner(case, [(report(), 0)], lockfile)
    module.verify_tool(scanner)
    stale = fake_scanner(case, [(report(), 0)], lockfile, version="cargo-audit 0.21.2")
    assert_raises(module.RemediationError, "unexpected cargo-audit version", lambda: module.verify_tool(stale))
    assert_raises(OSError, "No such file", lambda: module.verify_tool(case / "absent"))


def test_requirement_floor(module) -> None:
    assert module.requirement_floor(">=1.2.0") == ("1.2.0", True)
    assert module.requirement_floor(">= 0.9.7, <0.10.0") == ("0.9.7", True)
    assert module.requirement_floor("^0.22.1") == ("0.22.1", True)
    assert module.requirement_floor("~0.9.5") == ("0.9.5", True)
    assert module.requirement_floor("0.25.4") == ("0.25.4", True)
    assert module.requirement_floor(">= 0.9") == ("0.9.0", True)
    assert module.requirement_floor(">=1.0.0-rc.2") == ("1.0.0-rc.2", True)
    assert module.requirement_floor("<0.10.0") == ("", True)
    assert module.requirement_floor(">=1.0.0, <1.0.0") == ("", True)
    assert module.requirement_floor("> 0.3.1") == ("", False)
    assert module.requirement_floor(">0.3.1, >=0.4.0") == ("0.4.0", True)
    for requirement in ("1.*", "", "latest", ">=1.0.0 <2.0.0"):
        assert_raises(
            module.RemediationError,
            "version requirement",
            lambda requirement=requirement: module.requirement_floor(requirement),
        )


def test_fix_selection(module) -> None:
    locked = {"direct": ("1.0.0",), "dupe": ("0.1.40", "0.3.10"), "boundary": ("3.5.0",), "stuck": ("1.3.0",)}
    updates, unresolved, detected, fixable = module.derive_fixes(
        json.loads(
            report(
                vulnerability("RUSTSEC-2099-0001", "direct", "1.0.0", (">=1.2.0", ">=1.4.0")),
                vulnerability("RUSTSEC-2099-0002", "direct", "1.0.0", (">=1.3.0",)),
            )
        ),
        locked,
    )
    assert updates == {"direct": "1.3.0"}
    assert unresolved == []
    assert detected == {("RUSTSEC-2099-0001", "direct", "1.0.0"), ("RUSTSEC-2099-0002", "direct", "1.0.0")}
    assert fixable == detected

    updates, unresolved, detected, fixable = module.derive_fixes(
        json.loads(
            report(
                vulnerability("RUSTSEC-2099-0003", "dupe", "0.1.40", (">=0.1.45",)),
                vulnerability("RUSTSEC-2099-0004", "dupe", "0.1.40", (">=0.3.20",)),
                vulnerability("RUSTSEC-2099-0004", "dupe", "0.3.10", (">=0.3.20",)),
            )
        ),
        locked,
    )
    assert updates == {"dupe": "0.3.20"}
    assert len(detected) == 3 and fixable == detected

    updates, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0005", "boundary", "3.5.0", (">=4.0.0",)))),
        locked,
    )
    assert updates == {"boundary": "4.0.0"}

    updates, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0006", "direct", "1.0.0", (), (">=3.0.0",)))),
        locked,
    )
    assert updates == {"direct": "3.0.0"}

    for entry in (
        vulnerability("RUSTSEC-2099-0007", "stuck", "1.3.0"),
        vulnerability("RUSTSEC-2099-0008", "stuck", "1.3.0", (">=1.2.0",)),
        vulnerability("RUSTSEC-2099-0009", "stuck", "1.3.0", (), ("<0.10.0",)),
    ):
        updates, unresolved, _, fixable = module.derive_fixes(json.loads(report(entry)), locked)
        assert updates == {} and fixable == set()
        assert unresolved == [(entry["advisory"]["id"], "stuck", "1.3.0", "no-fix")]

    assert_raises(
        module.RemediationError,
        "cannot derive an exact patched version for RUSTSEC-2099-0010 in stuck@1.3.0",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0010", "stuck", "1.3.0", ("> 1.3.0",)))),
            locked,
        ),
    )
    assert_raises(
        module.RemediationError,
        "Cargo.lock does not lock",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0011", "direct", "9.9.9", (">=9.9.10",)))),
            locked,
        ),
    )


def test_locked_versions(module, root: Path) -> None:
    case = root / "locked"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"), ("dupe", "0.3.10"), ("dupe", "0.1.40")))
    lockfile = project / "Cargo.lock"
    assert module.locked_versions(lockfile) == {"app": ("0.1.0",), "dupe": ("0.1.40", "0.3.10")}
    lockfile.write_text("version = 4\n", encoding="utf-8")
    assert_raises(module.RemediationError, "locks no packages", lambda: module.locked_versions(lockfile))
    lockfile.write_text('version = 4\n\n[[package]]\nname = "x"\nversion = "one"\n', encoding="utf-8")
    assert_raises(module.RemediationError, "invalid locked crate version", lambda: module.locked_versions(lockfile))
    lockfile.write_text("[[package\n", encoding="utf-8")
    assert_raises(module.RemediationError, "malformed Cargo.lock", lambda: module.locked_versions(lockfile))


def test_clean_audit_verifies(module, root: Path) -> None:
    diagnostics = {
        "unmaintained": [warning("unmaintained", "abandoned", "1.0.0", "RUSTSEC-2099-0100")],
        "yanked": [warning("yanked", "pulled", "2.0.0")],
    }
    case, project, output = remediate(
        module,
        root,
        "clean",
        [findings(warnings=diagnostics)],
        (("app", "0.1.0"), ("abandoned", "1.0.0"), ("pulled", "2.0.0")),
    )
    assert logged(case / "omnibump.log") == []
    assert logged(case / "cargo.log") == VERIFICATION
    assert "diagnostic unmaintained RUSTSEC-2099-0100 in abandoned@1.0.0" in output
    assert "diagnostic yanked yanked in pulled@2.0.0" in output
    assert module.locked_versions(project / "Cargo.lock")["abandoned"] == ("1.0.0",)

    assert_raises(
        module.RemediationError,
        "command failed (101)",
        lambda: remediate(
            module,
            root,
            "verification-failure",
            [findings()],
            (("app", "0.1.0"), ("abandoned", "1.0.0")),
            environment={"CARGO_FAIL": "metadata"},
        ),
    )


def test_direct_fix(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0001", "directvuln", "1.0.0", (">=1.2.0",)))
    case, project, output = remediate(
        module,
        root,
        "direct",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("directvuln", "1.0.0")),
        dependencies=(("directvuln", "1.0.0"),),
    )
    assert module.locked_versions(project / "Cargo.lock")["directvuln"] == ("1.2.0",)
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "directvuln@1.2.0", "--fail-on-unapplied-pins",
    ]]
    assert logged(case / "cargo.log") == VERIFICATION
    assert "cargo remediation: applying directvuln@1.2.0" in output
    assert "omnibump: rust dependency graph analysis complete" in output
    assert 'directvuln = "1.2.0"' in project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert case.joinpath("scan-state").read_text(encoding="utf-8") == "2"


def test_transitive_fix(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0002", "transitive", "1.0.0", (">=1.1.0",)))
    case, project, _ = remediate(
        module,
        root,
        "transitive",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("wrapper", "2.0.0"), ("transitive", "1.0.0")),
        dependencies=(("wrapper", "2.0.0"),),
    )
    assert module.locked_versions(project / "Cargo.lock")["transitive"] == ("1.1.0",)
    manifest = project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert "transitive" not in manifest and 'wrapper = "2.0.0"' in manifest
    assert logged(case / "omnibump.log")[0][5] == "transitive@1.1.0"


def test_semver_boundary(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0003", "boundary", "3.5.0", (">=4.0.0",)))
    case, project, _ = remediate(
        module,
        root,
        "boundary",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("boundary", "3.5.0")),
        dependencies=(("boundary", "3.5"),),
    )
    assert module.locked_versions(project / "Cargo.lock")["boundary"] == ("4.0.0",)
    assert 'boundary = "4.0.0"' in project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert logged(case / "omnibump.log")[0][5] == "boundary@4.0.0"


def test_workspace_dependency(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0004", "shared", "0.9.1", ("^0.9.5",)))
    case, project, _ = remediate(
        module,
        root,
        "workspace",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("member-one", "0.1.0"), ("member-two", "0.1.0"), ("shared", "0.9.1")),
        dependencies=(("shared", "0.9.1"),),
        members=("member-one", "member-two"),
        features="sources-stdin sinks-console",
    )
    assert module.locked_versions(project / "Cargo.lock")["shared"] == ("0.9.5",)
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "shared@0.9.5", "--fail-on-unapplied-pins",
        "--features", "sources-stdin,sinks-console",
    ]]
    for member in ("member-one", "member-two"):
        assert 'shared = "0.9.5"' in project.joinpath(member, "Cargo.toml").read_text(encoding="utf-8")


def test_duplicate_lock_versions(module, root: Path) -> None:
    vulnerable = findings(
        vulnerability("RUSTSEC-2099-0005", "dupe", "0.1.40", (">=0.1.45",)),
        vulnerability("RUSTSEC-2099-0006", "dupe", "0.1.40", (">=0.3.20",)),
        vulnerability("RUSTSEC-2099-0006", "dupe", "0.3.10", (">=0.3.20",)),
    )
    case, project, _ = remediate(
        module,
        root,
        "duplicates",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("dupe", "0.1.40"), ("dupe", "0.3.10")),
    )
    assert module.locked_versions(project / "Cargo.lock")["dupe"] == ("0.3.20",)
    assert logged(case / "omnibump.log")[0][5] == "dupe@0.3.20"

    stranded = findings(vulnerability("RUSTSEC-2099-0005", "dupe", "0.1.40", (">=0.1.45",)))
    assert_raises(
        module.RemediationError,
        "vulnerable crate versions remain after remediation: RUSTSEC-2099-0005:dupe@0.1.40",
        lambda: remediate(
            module,
            root,
            "duplicates-stranded",
            [vulnerable, stranded],
            (("app", "0.1.0"), ("dupe", "0.1.40"), ("dupe", "0.3.10")),
            environment={"OMNIBUMP_MODE": "partial"},
        ),
    )


def test_coordinated_multi_crate(module, root: Path) -> None:
    vulnerable = findings(
        vulnerability("RUSTSEC-2099-0007", "beta", "2.0.0", (">=2.3.0",)),
        vulnerability("RUSTSEC-2099-0008", "alpha", "1.0.0", (">=1.2.0",)),
    )
    case, project, _ = remediate(
        module,
        root,
        "coordinated",
        [vulnerable, findings()],
        (("app", "0.1.0"), ("alpha", "1.0.0"), ("beta", "2.0.0")),
    )
    locked = module.locked_versions(project / "Cargo.lock")
    assert locked["alpha"] == ("1.2.0",) and locked["beta"] == ("2.3.0",)
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "alpha@1.2.0 beta@2.3.0", "--fail-on-unapplied-pins",
    ]]


def test_newly_exposed_finding(module, root: Path) -> None:
    exposer = findings(vulnerability("RUSTSEC-2099-0009", "exporter", "1.0.0", (">=1.2.0",)))
    exposed = findings(vulnerability("RUSTSEC-2099-0010", "core", "1.1.0", (">=1.2.0",)))
    case, project, output = remediate(
        module,
        root,
        "exposed",
        [exposer, exposed, findings()],
        (("app", "0.1.0"), ("exporter", "1.0.0"), ("core", "1.1.0")),
    )
    locked = module.locked_versions(project / "Cargo.lock")
    assert locked["exporter"] == ("1.2.0",) and locked["core"] == ("1.2.0",)
    assert logged(case / "omnibump.log") == [
        ["--language", "rust", "--dir", str(project), "--packages", "exporter@1.2.0", "--fail-on-unapplied-pins"],
        ["--language", "rust", "--dir", str(project), "--packages", "core@1.2.0", "--fail-on-unapplied-pins"],
    ]
    assert case.joinpath("scan-state").read_text(encoding="utf-8") == "3"
    assert logged(case / "cargo.log") == VERIFICATION
    assert output.count("cargo remediation: applying") == 2


def test_no_progress(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0011", "stuck", "1.0.0", (">=1.2.0",)))
    assert_raises(
        module.RemediationError,
        "cargo remediation pass made no lock graph progress: stuck@1.2.0",
        lambda: remediate(
            module,
            root,
            "stalled",
            [vulnerable, vulnerable],
            (("app", "0.1.0"), ("stuck", "1.0.0")),
            environment={"OMNIBUMP_MODE": "noop"},
        ),
    )


def test_downgrade_rejected(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0012", "regressed", "1.0.0", (">=1.2.0",)))
    assert_raises(
        module.RemediationError,
        "cargo remediation downgraded locked crates: regressed@1.0.0->0.0.1",
        lambda: remediate(
            module,
            root,
            "downgrade",
            [vulnerable, findings()],
            (("app", "0.1.0"), ("regressed", "1.0.0")),
            environment={"OMNIBUMP_MODE": "downgrade"},
        ),
    )


def test_unapplied_fix_is_loud(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0013", "blocked", "1.0.0", (">=1.2.0",)))
    case = root / "unapplied"
    error = "requested pin blocked@1.2.0 did not land"
    assert_raises(
        module.RemediationError,
        error,
        lambda: remediate(
            module,
            root,
            "unapplied",
            [vulnerable, findings()],
            (("app", "0.1.0"), ("blocked", "1.0.0")),
            environment={"OMNIBUMP_ERROR": error},
        ),
    )
    assert len(logged(case / "omnibump.log")) == 1
    assert logged(case / "cargo.log") == []
    assert case.joinpath("scan-state").read_text(encoding="utf-8") == "1"


def test_pass_limit(module, root: Path) -> None:
    case = root / "limit"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"),))
    limit = module.MAX_REMEDIATION_PASSES
    state = {f"crate{index}": ("1.0.0",) for index in range(limit + 1)}
    scans = 0

    def scan(*_args, **_kwargs):
        nonlocal scans
        scans += 1
        return scans - 1

    def derive_fixes(index, _locked):
        crate = f"crate{index}"
        identity = (f"RUSTSEC-2099-{index:04d}", crate, "1.0.0")
        return {crate: "1.1.0"}, [], {identity}, {identity}

    def run_command(arguments, _cwd, capture=False, report=False):
        assert arguments[0] == "omnibump" and report and not capture
        for pin in arguments[arguments.index("--packages") + 1].split():
            crate, version = pin.rsplit("@", 1)
            state[crate] = (version,)
        return ""

    module.verify_tool = lambda *_args, **_kwargs: None
    module.report_diagnostics = lambda *_args, **_kwargs: None
    module.scan = scan
    module.derive_fixes = derive_fixes
    module.locked_versions = lambda *_args, **_kwargs: dict(state)
    module.run_command = run_command
    module.verify = lambda *_args, **_kwargs: None
    previous_argv = sys.argv
    sys.argv = ["remediate.py", "cargo-audit", str(project), ""]
    try:
        assert_raises(
            module.RemediationError,
            f"cargo remediation pass limit reached after {limit} passes",
            module.main,
        )
    finally:
        sys.argv = previous_argv
    assert scans == limit + 1


def test_argument_contract(module, root: Path) -> None:
    case = root / "arguments"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"),))
    previous_argv = sys.argv
    try:
        sys.argv = ["remediate.py", "cargo-audit", str(project)]
        assert_raises(module.RemediationError, "usage: remediate.py", module.main)
        sys.argv = ["remediate.py", "cargo-audit", str(case), ""]
        assert_raises(module.RemediationError, "no Cargo.lock in", module.main)
    finally:
        sys.argv = previous_argv


def test_pipeline_contract() -> None:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    assert pipeline.count('cargo install cargo-audit --version 0.22.2 --locked --root "$tool_dir"') == 1
    assert 'TOOL_VERSION = "0.22.2"' in pipeline
    assert "@latest" not in pipeline and "cargo audit fix" not in pipeline
    assert "cargo update" not in pipeline and "--precise" not in pipeline
    assert "RUSTSEC-" not in pipeline
    assert '"--language", "rust"' in pipeline and '"--fail-on-unapplied-pins"' in pipeline
    assert "MAX_REMEDIATION_PASSES = 8" in pipeline
    assert 'report["vulnerabilities"]["list"]' in pipeline
    assert "cargo-remediation-evidence" not in pipeline and "lockContentHash" not in pipeline
    needs = pipeline.split("inputs:", 1)[0]
    assert "- omnibump" in needs and "- python3" in needs and "cargo-audit" not in needs


def main() -> None:
    cases = (
        (test_scan_contract, True),
        (test_requirement_floor, False),
        (test_fix_selection, False),
        (test_locked_versions, True),
        (test_clean_audit_verifies, True),
        (test_direct_fix, True),
        (test_transitive_fix, True),
        (test_semver_boundary, True),
        (test_workspace_dependency, True),
        (test_duplicate_lock_versions, True),
        (test_coordinated_multi_crate, True),
        (test_newly_exposed_finding, True),
        (test_no_progress, True),
        (test_downgrade_rejected, True),
        (test_unapplied_fix_is_loud, True),
        (test_pass_limit, True),
        (test_argument_contract, True),
    )
    for case, needs_root in cases:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            module = load_resolver(root)
            case(module, root) if needs_root else case(module)
    test_pipeline_contract()
    print("passed scripts/test_cargo_remediation.py")


if __name__ == "__main__":
    main()
