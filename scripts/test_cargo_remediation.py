#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "pipelines/cargo/remediate.yaml"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
DATABASE_URL = "https://github.com/rustsec/advisory-db"
CHECKSUM = "0" * 64
METADATA = ["metadata", "--locked", "--format-version", "1", "--filter-platform", "host-tuple"]
VERIFICATION = [METADATA, ["fetch", "--locked"]]
DEFAULT_SETTINGS = {
    "target_arch": [],
    "target_os": [],
    "severity": None,
    "ignore": [],
    "informational_warnings": ["unmaintained", "unsound", "notice"],
}
# Verbatim `cargo audit --json` output from cargo-audit 0.22.2 for a lockfile
# holding time 0.1.45 against RUSTSEC-2020-0071, whose real advisory carries both
# a patched floor and lower unaffected pins. The unaffected floors must never
# undercut the patched floor.
CAPTURED_REPORT = """{
    "database": {"advisory-count": 1, "last-commit": null, "last-updated": null},
    "lockfile": {"dependency-count": 2},
    "settings": {
        "target_arch": [], "target_os": [], "severity": null, "ignore": [],
        "informational_warnings": ["unmaintained", "unsound", "notice"]
    },
    "vulnerabilities": {
        "found": true,
        "count": 1,
        "list": [
            {
                "advisory": {
                    "id": "RUSTSEC-2020-0071",
                    "package": "time",
                    "title": "Potential segfault in the time crate",
                    "description": "Unix-like operating systems may segfault due to dereferencing a dangling pointer.",
                    "date": "2020-11-18",
                    "aliases": ["CVE-2020-26235", "GHSA-wcg3-cvx6-7396"],
                    "related": [],
                    "collection": "crates",
                    "categories": ["code-execution", "memory-corruption"],
                    "keywords": ["segfault"],
                    "cvss": null,
                    "informational": null,
                    "references": [],
                    "source": null,
                    "url": "https://github.com/time-rs/time/issues/293",
                    "withdrawn": null,
                    "license": "CC0-1.0",
                    "expect-deleted": false
                },
                "versions": {
                    "patched": [">=0.2.23"],
                    "unaffected": [
                        "=0.2.0", "=0.2.1", "=0.2.2", "=0.2.3", "=0.2.4", "=0.2.5", "=0.2.6"
                    ]
                },
                "affected": null,
                "package": {
                    "name": "time", "version": "0.1.45",
                    "source": "registry+https://github.com/rust-lang/crates.io-index",
                    "checksum": "0000000000000000000000000000000000000000000000000000000000000000",
                    "replace": null
                }
            }
        ]
    },
    "warnings": {}
}
"""

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
pins = []
for pin in arguments[arguments.index("--packages") + 1].split():
    crate, transition = pin.rsplit("@", 1)
    current, requested = transition.split("=", 1)
    pins.append((crate, current, requested))
if blocked := os.environ.get("OMNIBUMP_BLOCKED_PACKAGE"):
    if any(crate == blocked for crate, _, _ in pins):
        if os.environ.get("OMNIBUMP_BLOCKED_MUTATES") == "1":
            for name in ("Cargo.toml", "Cargo.lock"):
                path = directory / name
                path.write_text(path.read_text(encoding="utf-8") + "\n# partial omnibump mutation\n", encoding="utf-8")
        print(
            f"no dependent version permits the target: {blocked} has no compatible dependency graph",
            file=sys.stderr,
        )
        raise SystemExit(42)
mode = os.environ.get("OMNIBUMP_MODE", "collapse")
if mode == "noop":
    raise SystemExit(0)


def key(value):
    return tuple(int(part) for part in re.split(r"[.-]", value) if part.isdigit())


def line(value):
    major, minor, patch = (key(value) + (0, 0, 0))[:3]
    return (major,) if major else ((0, minor) if minor else (0, 0, patch))


# Mirrors the real omnibump 0.23.2 semantics proven by
# scripts/test_cargo_omnibump_contract.py: a pin lands on its own compatibility
# line, is skipped once that line satisfies it, and otherwise crosses the
# boundary from the highest lower instance.
lock = directory / "Cargo.lock"
text = lock.read_text(encoding="utf-8")
applied = []
for crate, current, requested in pins:
    pattern = re.compile(r'(\[\[package\]\]\nname = "' + re.escape(crate) + r'"\nversion = ")([^"]+)(")')
    matches = list(pattern.finditer(text))
    if not matches:
        print(f"omnibump: package {crate} not found in Cargo.lock", file=sys.stderr)
        continue
    if mode == "downgrade":
        targets = {match.start(): "0.0.1" for match in matches}
    elif mode == "sink":
        # Lower one non-maximum instance and leave the rest untouched.
        targets = {min(matches, key=lambda match: key(match.group(2))).start(): "0.0.1"}
    else:
        movable = [match for match in matches if match.group(2) == current]
        if not movable:
            print(f"omnibump: {crate}@{current} is not locked", file=sys.stderr)
            raise SystemExit(42)
        if mode == "partial" and len(movable) > 1:
            movable = movable[1:]
        targets = {match.start(): requested for match in movable}
    if targets:
        applied.append((crate, requested))

    def replace(match, targets=targets):
        target = targets.get(match.start())
        return match.group(0) if target is None else match.group(1) + target + match.group(3)

    text = pattern.sub(replace, text)
lock.write_text(text, encoding="utf-8")
for manifest in sorted(directory.rglob("Cargo.toml")):
    content = manifest.read_text(encoding="utf-8")
    for crate, requested in applied:
        content = re.sub(
            r'(?m)^' + re.escape(crate) + r' = "[^"]+"$',
            crate + ' = "' + requested + '"',
            content,
        )
    manifest.write_text(content, encoding="utf-8")
'''

CARGO = r"""#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import tomllib

with open(os.environ["CARGO_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if os.environ.get("CARGO_FAIL") == sys.argv[1]:
    print("cargo: simulated failure", file=sys.stderr)
    raise SystemExit(101)
if sys.argv[1] == "metadata":
    lock = tomllib.loads(pathlib.Path("Cargo.lock").read_text(encoding="utf-8"))
    packages = []
    identities = {}
    for entry in lock["package"]:
        source = entry.get("source")
        identity = (entry["name"], entry["version"], source)
        if identity in identities:
            continue
        package_id = f"pkg-{len(packages)}"
        identities[identity] = package_id
        packages.append({"id": package_id, "name": entry["name"], "version": entry["version"], "source": source})
    roots = [package_id for (name, _, source), package_id in identities.items() if source is None]
    registry_ids = [package_id for (_, _, source), package_id in identities.items() if source is not None]
    nodes = [
        {
            "id": package["id"],
            "deps": [
                {"pkg": dependency, "dep_kinds": [{"kind": None, "target": None}]}
                for dependency in (registry_ids if package["id"] in roots else [])
            ],
        }
        for package in packages
    ]
    print(json.dumps({
        "version": 1,
        "packages": packages,
        "workspace_default_members": roots,
        "workspace_root": os.getcwd(),
        "resolve": {"nodes": nodes, "root": roots[0] if len(roots) == 1 else None},
    }))
"""



def extract_resolver(root: Path) -> Path:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool_dir/remediate.py\" <<'PYTHON'\n", 1)[1].split("      PYTHON\n", 1)[0]
    script = "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"
    path = root / "remediate.py"
    path.write_text(script, encoding="utf-8")
    return path


def extract_cargo_wrapper() -> str:
    pipeline = PIPELINE.read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool_dir/bin/cargo\" <<'SH'\n", 1)[1].split(
        "      SH\n", 1
    )[0]
    return "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n"



def load_resolver(root: Path):
    spec = importlib.util.spec_from_file_location("cargo_remediate", extract_resolver(root))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def registry(*versions: str) -> tuple[tuple[str, str], ...]:
    return tuple((version, REGISTRY) for version in versions)


def cargo_graph(
    packages: tuple[tuple[str, str, str, str], ...],
    roots: tuple[str, ...],
    edges: dict[str, tuple[tuple[str, tuple[tuple[str | None, str | None], ...]], ...]],
    workspace_root: str = "/workspace",
    current: str | None = None,
) -> str:
    return json.dumps(
        {
            "version": 1,
            "packages": [
                {
                    "id": package_id,
                    "name": name,
                    "version": version,
                    "source": source or None,
                }
                for package_id, name, version, source in packages
            ],
            "workspace_default_members": list(roots),
            "workspace_root": workspace_root,
            "resolve": {
                "root": current,
                "nodes": [
                    {
                        "id": package_id,
                        "deps": [
                            {
                                "pkg": dependency,
                                "dep_kinds": [
                                    {"kind": kind, "target": target}
                                    for kind, target in kinds
                                ],
                            }
                            for dependency, kinds in edges.get(package_id, ())
                        ],
                    }
                    for package_id, _, _, _ in packages
                ],
            },
        }
    )


def graph_locked(
    packages: tuple[tuple[str, str, str, str], ...],
) -> dict[str, tuple[tuple[str, str], ...]]:
    locked: dict[str, set[tuple[str, str]]] = {}
    for _, name, version, source in packages:
        locked.setdefault(name, set()).add((version, source))
    return {name: tuple(sorted(instances)) for name, instances in locked.items()}



def vulnerability(
    identifier: str,
    crate: str,
    version: str,
    patched: tuple[str, ...] = (),
    unaffected: tuple[str, ...] = (),
    source: str = REGISTRY,
    replace: str | None = None,
) -> dict:
    return {
        "advisory": {"id": identifier, "package": crate, "title": identifier, "informational": None},
        "versions": {"patched": list(patched), "unaffected": list(unaffected)},
        "affected": None,
        "package": {
            "name": crate,
            "version": version,
            "source": source,
            "checksum": CHECKSUM,
            "replace": replace,
        },
    }


def warning(kind: str, crate: str, version: str, identifier: str | None = None) -> dict:
    package = {"name": crate, "version": version, "source": REGISTRY, "checksum": CHECKSUM, "replace": None}
    advisory = None if identifier is None else {"id": identifier, "package": crate, "informational": kind}
    return {"kind": kind, "package": package, "advisory": advisory, "affected": None}


def report(*items: dict, warnings: dict | None = None, settings: dict | None = None) -> str:
    return json.dumps(
        {
            "database": {"advisory-count": len(items), "last-commit": None, "last-updated": None},
            "lockfile": {"dependency-count": 2},
            "settings": DEFAULT_SETTINGS if settings is None else settings,
            "vulnerabilities": {"found": bool(items), "count": len(items), "list": list(items)},
            "warnings": warnings or {},
        }
    ) + "\n"


def findings(*items: dict, warnings: dict | None = None) -> tuple[str, int]:
    return report(*items, warnings=warnings), 1 if items else 0


def write_lock(path: Path, packages: tuple[tuple[str, str], ...], sources: dict[str, str] | None = None) -> None:
    body = "version = 4\n"
    for name, version in packages:
        body += f'\n[[package]]\nname = "{name}"\nversion = "{version}"\n'
        source = (sources or {}).get(f"{name}@{version}", REGISTRY if name != "app" else "")
        if source:
            body += f'source = "{source}"\nchecksum = "{CHECKSUM}"\n'
    path.write_text(body, encoding="utf-8")


def prepare_project(
    case: Path,
    packages: tuple[tuple[str, str], ...],
    dependencies: tuple[tuple[str, str], ...] = (),
    members: tuple[str, ...] = (),
    sources: dict[str, str] | None = None,
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
    write_lock(project / "Cargo.lock", packages, sources)
    return project


def prepare_tool_dir(case: Path) -> tuple[Path, Path, Path]:
    tool_dir = case / "tool"
    workdir = tool_dir / "audit"
    workdir.joinpath("cargo").mkdir(parents=True, exist_ok=True)
    return tool_dir, workdir, tool_dir / "advisory-db"


def audit_arguments(lockfile: Path, database: Path) -> list[str]:
    return [
        "audit", "--json", "--color", "never", "--no-yanked",
        "--file", str(lockfile), "--db", str(database), "--url", DATABASE_URL,
    ]


def fake_scanner(
    case: Path,
    outputs: list[tuple[str | bytes, int]],
    lockfile: Path,
    database: Path,
    version: str = "cargo-audit 0.22.2",
    stderr: str | bytes = "",
) -> Path:
    scanner = case / "cargo-audit"
    paths = []
    statuses = []
    for index, (raw, status) in enumerate(outputs):
        path = case / f"scan-{index}.json"
        path.write_bytes(raw.encode() if isinstance(raw, str) else raw)
        paths.append(str(path))
        statuses.append(status)
    state = case / "scan-state"
    stderr_path = case / "scan-stderr"
    stderr_path.write_bytes(stderr.encode() if isinstance(stderr, str) else stderr)
    scanner.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, pathlib, sys\n"
        f"if sys.argv[1:] == ['--version']:\n"
        f"    print({version!r})\n"
        "    raise SystemExit(0)\n"
        f"assert sys.argv[1:] == {audit_arguments(lockfile, database)!r}, sys.argv[1:]\n"
        f"with open({str(case / 'audit.log')!r}, 'a', encoding='utf-8') as log:\n"
        "    log.write(json.dumps({\n"
        "        'cwd': os.getcwd(),\n"
        "        'home': os.environ.get('HOME'),\n"
        "        'cargo_home': os.environ.get('CARGO_HOME'),\n"
        "    }) + '\\n')\n"
        f"state = pathlib.Path({str(state)!r})\n"
        "index = int(state.read_text() or '0') if state.exists() else 0\n"
        "state.write_text(str(index + 1))\n"
        f"paths = {paths!r}\n"
        f"statuses = {statuses!r}\n"
        "index = min(index, len(paths) - 1)\n"
        "sys.stdout.buffer.write(pathlib.Path(paths[index]).read_bytes())\n"
        f"sys.stderr.buffer.write(pathlib.Path({str(stderr_path)!r}).read_bytes())\n"
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


def logged(path: Path) -> list:
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


def remediate(
    module,
    root: Path,
    name: str,
    outputs: list[tuple[str, int]],
    packages: tuple[tuple[str, str], ...],
    dependencies: tuple[tuple[str, str], ...] = (),
    members: tuple[str, ...] = (),
    sources: dict[str, str] | None = None,
    features: str = "",
    default_features: bool = True,
    target: str = "host-tuple",
    environment: dict[str, str] | None = None,
) -> tuple[Path, Path, str]:
    case = root / name
    case.mkdir()
    project = prepare_project(case, packages, dependencies, members, sources)
    tool_dir, _, database = prepare_tool_dir(case)
    scanner = fake_scanner(case, outputs, project / "Cargo.lock", database)
    binary_dir = install_command_wrappers(case)
    previous_environ = os.environ.copy()
    previous_argv = sys.argv
    os.environ.update(
        PATH=f"{binary_dir}:{os.environ['PATH']}",
        CARGO_LOG=str(case / "cargo.log"),
        OMNIBUMP_LOG=str(case / "omnibump.log"),
        CARGO_REMEDIATE_REAL_CARGO=str(binary_dir / "cargo"),
        **(environment or {}),
    )
    sys.argv = [
        "remediate.py",
        str(scanner),
        str(project),
        features,
        str(default_features).lower(),
        target,
        str(tool_dir),
    ]
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            module.main()
    finally:
        sys.argv = previous_argv
        os.environ.clear()
        os.environ.update(previous_environ)
    return case, project, output.getvalue()



def test_scan_contract(module, root: Path) -> None:
    case = root / "scan"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"), ("directvuln", "1.0.0")))
    lockfile = project / "Cargo.lock"
    _, workdir, database = prepare_tool_dir(case)
    vulnerable = report(vulnerability("RUSTSEC-2099-0001", "directvuln", "1.0.0", (">=1.2.0",)))

    def run(raw: str | bytes, status: int, version: str = "cargo-audit 0.22.2", stderr: str | bytes = ""):
        scanner = fake_scanner(case, [(raw, status)], lockfile, database, version, stderr)
        return module.scan(scanner, lockfile, workdir, database)

    assert run(vulnerable, 1)["vulnerabilities"]["count"] == 1
    assert run(report(), 0)["vulnerabilities"]["list"] == []

    # An audit that reports findings without a report is scanner failure, not a finding.
    assert_raises(
        module.RemediationError,
        "cargo-audit produced no report (exit 1): fatal: unable to access advisory database",
        lambda: run("", 1, stderr="fatal: unable to access advisory database\n"),
    )
    assert_raises(
        module.RemediationError,
        "cargo-audit scanner failure (exit 2): database fetch failed",
        lambda: run(vulnerable, 2, stderr="database fetch failed\n"),
    )
    assert_raises(
        module.RemediationError,
        "malformed cargo-audit JSON",
        lambda: run("not-json\n", 1, stderr="warning: stale database\n"),
    )
    assert "(exit 1): warning: stale database" in caught(module, lambda: run("not-json\n", 1, stderr="warning: stale database\n"))
    assert_raises(
        module.RemediationError,
        "contradicts its vulnerability list",
        lambda: run(vulnerable, 0),
    )
    assert_raises(module.RemediationError, "contradicts its vulnerability list", lambda: run(report(), 1))
    for raw in ('{"vulnerabilities":', "[]\n", '{"vulnerabilities": {}}'):
        assert_raises(module.RemediationError, "cargo-audit", lambda raw=raw: run(raw, 1))
    inconsistent = json.dumps({"vulnerabilities": {"found": True, "count": 2, "list": []}})
    assert_raises(module.RemediationError, "invalid cargo-audit vulnerability summary", lambda: run(inconsistent, 1))
    settings_missing = json.dumps({"vulnerabilities": {"found": False, "count": 0, "list": []}, "warnings": {}})
    assert_raises(module.RemediationError, "has no settings section", lambda: run(settings_missing, 0))
    assert_raises(
        module.RemediationError,
        "malformed cargo-audit UTF-8 output",
        lambda: run(b"\xff", 0),
    )
    oversized = b"x" * (module.MAX_OUTPUT_BYTES + 1)
    assert_raises(module.RemediationError, "cargo-audit stdout exceeds 32 MiB", lambda: run(oversized, 0))
    assert_raises(
        module.RemediationError,
        "cargo-audit stderr exceeds 32 MiB",
        lambda: run(report(), 0, stderr=oversized),
    )

    scanner = fake_scanner(case, [(report(), 0)], lockfile, database)
    module.verify_tool(scanner)
    stale = fake_scanner(case, [(report(), 0)], lockfile, database, version="cargo-audit 0.21.2")
    assert_raises(module.RemediationError, "unexpected cargo-audit version", lambda: module.verify_tool(stale))
    assert_raises(OSError, "No such file", lambda: module.verify_tool(case / "absent"))


def caught(module, action) -> str:
    try:
        action()
    except module.RemediationError as error:
        return str(error)
    raise AssertionError("expected RemediationError")


def test_policy_overrides_rejected(module, root: Path) -> None:
    case = root / "policy"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"), ("directvuln", "1.0.0")))
    lockfile = project / "Cargo.lock"
    _, workdir, database = prepare_tool_dir(case)
    for override in (
        {"ignore": ["RUSTSEC-2099-0001"]},
        {"severity": "critical"},
        {"target_arch": ["x86_64"]},
        {"target_os": ["linux"]},
        {"informational_warnings": []},
    ):
        settings = dict(DEFAULT_SETTINGS, **override)
        scanner = fake_scanner(case, [(report(settings=settings), 0)], lockfile, database)
        message = caught(module, lambda scanner=scanner: module.scan(scanner, lockfile, workdir, database))
        assert "cargo-audit policy overrides rejected" in message, message
        assert next(iter(override)) in message, message
    missing_severity = dict(DEFAULT_SETTINGS)
    missing_severity.pop("severity")
    scanner = fake_scanner(case, [(report(settings=missing_severity), 0)], lockfile, database)
    message = caught(module, lambda: module.scan(scanner, lockfile, workdir, database))
    assert "cargo-audit policy overrides rejected" in message and "severity" in message, message


def test_audit_isolation(module, root: Path) -> None:
    """The untrusted checkout must never be the audit working directory."""
    case, project, _ = remediate(
        module,
        root,
        "isolation",
        [findings()],
        (("app", "0.1.0"), ("quiet", "1.0.0")),
    )
    tool_dir, workdir, _ = prepare_tool_dir(case)
    records = logged(case / "audit.log")
    assert records, records
    for record in records:
        assert Path(record["cwd"]).resolve() == workdir.resolve(), record
        assert Path(record["cwd"]).resolve() != project.resolve(), record
        assert Path(record["home"]).resolve() == workdir.resolve(), record
        assert Path(record["cargo_home"]).resolve() == (workdir / "cargo").resolve(), record
        assert str(tool_dir.resolve()) in record["cwd"], record


def test_requirement_floor(module) -> None:
    assert module.requirement_floor(">=1.2.0") == ("1.2.0", "exact")
    assert module.requirement_floor(">= 0.9.7, <0.10.0") == ("0.9.7", "exact")
    assert module.requirement_floor("^0.22.1") == ("0.22.1", "exact")
    assert module.requirement_floor("~0.9.5") == ("0.9.5", "exact")
    assert module.requirement_floor("0.25.4") == ("0.25.4", "exact")
    assert module.requirement_floor(">= 0.9") == ("0.9.0", "exact")
    assert module.requirement_floor(">=1.0.0-rc.2") == ("1.0.0-rc.2", "exact")
    assert module.requirement_floor("1.2.3, >=1.5.0") == ("1.5.0", "exact")
    assert module.requirement_floor("=1.2.3") == ("1.2.3", "exact")
    assert module.requirement_floor("=1.2, >=1.2.5") == ("1.2.5", "exact")
    assert module.requirement_floor("<0.10.0") == ("", "open")
    assert module.requirement_floor("<=0.10.0") == ("", "open")
    assert module.requirement_floor("> 0.3.1") == ("", "unnameable")
    assert module.requirement_floor(">0.3.1, >=0.4.0") == ("0.4.0", "exact")
    assert module.requirement_floor(">0.3.1, <2.0.0") == ("", "unnameable")

    # Degenerate caret forms: `^0` allows `<1.0.0` and `^0.0` allows `<0.1.0`,
    # so neither may contradict a higher floor in the same requirement.
    assert module.requirement_floor("^0") == ("0.0.0", "exact")
    assert module.requirement_floor("^0, >=0.5.0") == ("0.5.0", "exact")
    assert module.requirement_floor("^0.0") == ("0.0.0", "exact")
    assert module.requirement_floor("^0.0, >=0.0.5") == ("0.0.5", "exact")
    assert module.requirement_floor("^0.0.3") == ("0.0.3", "exact")
    assert module.requirement_floor("~0") == ("0.0.0", "exact")
    assert module.requirement_floor("~0.0") == ("0.0.0", "exact")

    # Caret and tilde carry implicit upper bounds that can contradict a floor.
    for requirement in (
        ">=1.0.0, <1.0.0",
        ">=2.0.0, <1.0.0",
        "^1.4.3, <1.2.0",
        "~1.4.3, <1.4.0",
        "1.2.3, >=2.0.0",
        "=1.2.3, >=1.2.4",
        "=1.2, >=1.3.0",
        "=1, >=2.0.0",
        "=1.2.3, >1.2.3",
        ">2.0.0, <2.0.0",
    ):
        assert_raises(
            module.RemediationError,
            "unsatisfiable version requirement",
            lambda requirement=requirement: module.requirement_floor(requirement),
        )
    for requirement in ("1.*", "*", "", "latest", ">=1.0.0 <2.0.0", "1.x", "==1.2.3"):
        assert_raises(
            module.RemediationError,
            "version requirement",
            lambda requirement=requirement: module.requirement_floor(requirement),
        )


def test_fix_selection(module) -> None:
    locked = {
        "direct": registry("1.0.0"),
        "dupe": registry("0.1.40", "0.3.10"),
        "boundary": registry("3.5.0"),
        "stuck": registry("1.3.0"),
    }
    updates, unresolved, detected, fixable, _ = module.derive_fixes(
        json.loads(
            report(
                vulnerability("RUSTSEC-2099-0001", "direct", "1.0.0", (">=1.2.0", ">=1.4.0")),
                vulnerability("RUSTSEC-2099-0002", "direct", "1.0.0", (">=1.3.0",)),
            )
        ),
        locked,
    )
    assert updates == {("direct", "1.0.0"): "1.3.0"}
    assert unresolved == []
    assert detected == {("RUSTSEC-2099-0001", "direct", "1.0.0"), ("RUSTSEC-2099-0002", "direct", "1.0.0")}
    assert fixable == detected

    updates, unresolved, detected, fixable, _ = module.derive_fixes(
        json.loads(
            report(
                vulnerability("RUSTSEC-2099-0003", "dupe", "0.1.40", (">=0.1.45",)),
                vulnerability("RUSTSEC-2099-0004", "dupe", "0.3.10", (">=0.3.20",)),
            )
        ),
        locked,
    )
    # One pin per vulnerable line: the 0.1 line must not be stranded behind 0.3.
    assert updates == {("dupe", "0.1.40"): "0.1.45", ("dupe", "0.3.10"): "0.3.20"}
    assert len(detected) == 2 and fixable == detected

    # An instance must satisfy every advisory against it, even across a line.
    updates, _, detected, _, _ = module.derive_fixes(
        json.loads(
            report(
                vulnerability("RUSTSEC-2099-0003", "dupe", "0.1.40", (">=0.1.45",)),
                vulnerability("RUSTSEC-2099-0004", "dupe", "0.1.40", (">=0.3.20",)),
                vulnerability("RUSTSEC-2099-0004", "dupe", "0.3.10", (">=0.3.20",)),
            )
        ),
        locked,
    )
    assert updates == {("dupe", "0.1.40"): "0.3.20", ("dupe", "0.3.10"): "0.3.20"}
    assert len(detected) == 3

    updates, _, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0005", "boundary", "3.5.0", (">=4.0.0",)))),
        locked,
    )
    assert updates == {("boundary", "3.5.0"): "4.0.0"}

    updates, _, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0006", "direct", "1.0.0", (), (">=3.0.0",)))),
        locked,
    )
    assert updates == {("direct", "1.0.0"): "3.0.0"}

    # Disjoint ranges: the lower range is unreachable, the higher one is the fix.
    updates, _, _, _, _ = module.derive_fixes(
        json.loads(
            report(vulnerability("RUSTSEC-2099-0007", "stuck", "1.3.0", (">=1.2.0, <1.3.0", ">=1.6.0")))
        ),
        locked,
    )
    assert updates == {("stuck", "1.3.0"): "1.6.0"}

    entry = vulnerability("RUSTSEC-2099-0008", "stuck", "1.3.0")
    updates, unresolved, _, fixable, _ = module.derive_fixes(json.loads(report(entry)), locked)
    assert updates == {} and fixable == set()
    assert unresolved == [("RUSTSEC-2099-0008", "stuck", "1.3.0", "no-fix")]

    # The advisory's patched floor wins over lower unaffected pins.
    captured = module.parse_report(CAPTURED_REPORT)
    updates, unresolved, detected, fixable, _ = module.derive_fixes(captured, {"time": registry("0.1.45")})
    assert updates == {("time", "0.1.45"): "0.2.23"}
    assert unresolved == []
    assert detected == {("RUSTSEC-2020-0071", "time", "0.1.45")} and fixable == detected

    # An unaffected floor still applies when no patched release is reachable.
    updates, _, _, _, _ = module.derive_fixes(
        json.loads(
            report(vulnerability("RUSTSEC-2099-0009", "direct", "1.0.0", (">=0.9.0",), (">=2.0.0",)))
        ),
        locked,
    )
    assert updates == {("direct", "1.0.0"): "2.0.0"}


def test_blocking_classifications(module) -> None:
    locked = {
        "stuck": registry("1.3.0"),
        "stable": registry("0.9.0"),
        "stable-same-line": registry("1.2.0"),
    }
    for entry, message in (
        (
            vulnerability("RUSTSEC-2099-0010", "stuck", "1.3.0", ("> 1.3.0",)),
            "known fix for RUSTSEC-2099-0010 in stuck@1.3.0 names no exact release",
        ),
        (
            vulnerability("RUSTSEC-2099-0011", "stuck", "1.3.0", (">=1.2.0",)),
            "known fix for RUSTSEC-2099-0011 in stuck@1.3.0 requires a downgrade",
        ),
        (
            vulnerability("RUSTSEC-2099-0012", "stuck", "1.3.0", (), ("<1.0.0",)),
            "known fix for RUSTSEC-2099-0012 in stuck@1.3.0 requires a downgrade",
        ),
        (
            vulnerability("RUSTSEC-2099-0014", "stuck", "1.3.0", ("1.*",)),
            "RUSTSEC-2099-0014 in stuck@1.3.0: unsupported version requirement: '1.*'",
        ),
        (
            vulnerability("RUSTSEC-2099-0015", "stuck", "1.3.0", (">=2.0.0, <1.0.0",)),
            "RUSTSEC-2099-0015 in stuck@1.3.0: unsatisfiable version requirement",
        ),
    ):
        assert_raises(
            module.RemediationError,
            message,
            lambda entry=entry: module.derive_fixes(json.loads(report(entry)), locked),
        )
    # Stable builds do not jump to prereleases. They report the advisory and
    # automatically remediate it once the advisory names a stable release.
    for entry, expected in (
        (
            vulnerability("RUSTSEC-2099-0013", "stable", "0.9.0", (">=1.0.0-rc.2",)),
            ("RUSTSEC-2099-0013", "stable", "0.9.0", "prerelease-fix"),
        ),
        (
            vulnerability("RUSTSEC-2099-0019", "stable-same-line", "1.2.0", (">=1.2.1-rc.1",)),
            ("RUSTSEC-2099-0019", "stable-same-line", "1.2.0", "prerelease-fix"),
        ),
    ):
        updates, unresolved, _, fixable, _ = module.derive_fixes(
            json.loads(report(entry)), locked
        )
        assert updates == {} and fixable == set()
        assert unresolved == [expected]

    # A prerelease fix is acceptable only on the line the lock already occupies.
    updates, _, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0016", "line", "1.0.0-rc.1", (">=1.0.0-rc.2",)))),
        {"line": registry("1.0.0-rc.1")},
    )
    assert updates == {("line", "1.0.0-rc.1"): "1.0.0-rc.2"}

    # A stable candidate wins over a prerelease candidate instead of blocking.
    updates, _, _, _, _ = module.derive_fixes(
        json.loads(
            report(vulnerability("RUSTSEC-2099-0017", "stable", "0.9.0", (">=1.0.0-rc.2", ">=1.0.0")))
        ),
        locked,
    )
    assert updates == {("stable", "0.9.0"): "1.0.0"}

    # A prerelease bump within the locked prerelease train stays allowed.
    updates, _, _, _, _ = module.derive_fixes(
        json.loads(report(vulnerability("RUSTSEC-2099-0018", "train", "2.0.0-rc.1", (">=2.0.1-rc.1",)))),
        {"train": registry("2.0.0-rc.1")},
    )
    assert updates == {("train", "2.0.0-rc.1"): "2.0.1-rc.1"}
    for version in ("1.3.0-rc.1", "2.0.0-rc.1"):
        entry = vulnerability("RUSTSEC-2099-0040", "train", "1.2.0-rc.1", (f">={version}",))
        updates, unresolved, _, fixable, _ = module.derive_fixes(
            json.loads(report(entry)), {"train": registry("1.2.0-rc.1")}
        )
        assert updates == {} and fixable == set()
        assert unresolved == [("RUSTSEC-2099-0040", "train", "1.2.0-rc.1", "prerelease-fix")]


def test_crate_identity(module, root: Path) -> None:
    git = "git+https://github.com/example/dupe?rev=abc123"
    locked = {
        "dual": (("1.0.0", REGISTRY), ("1.0.0", git)),
        "vendored": (("1.0.0", ""),),
        "patched": (("1.0.0", git),),
        "clean": registry("1.0.0"),
    }
    assert_raises(
        module.RemediationError,
        "which Cargo.lock locks from 2 sources",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0020", "dual", "1.0.0", (">=1.1.0",)))),
            locked,
        ),
    )
    assert_raises(
        module.RemediationError,
        "vendored@1.0.0 is locked from a local path, which no registry version pin can remediate",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0021", "vendored", "1.0.0", (">=1.1.0",), source=""))),
            locked,
        ),
    )
    assert_raises(
        module.RemediationError,
        f"patched@1.0.0 is locked from {git}",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0022", "patched", "1.0.0", (">=1.1.0",), source=git))),
            locked,
        ),
    )
    assert_raises(
        module.RemediationError,
        "which Cargo.lock does not lock",
        lambda: module.derive_fixes(
            json.loads(report(vulnerability("RUSTSEC-2099-0023", "clean", "9.9.9", (">=9.9.10",)))),
            locked,
        ),
    )
    assert_raises(
        module.RemediationError,
        "is replaced in Cargo.lock; identity is ambiguous",
        lambda: module.derive_fixes(
            json.loads(
                report(
                    vulnerability(
                        "RUSTSEC-2099-0024", "clean", "1.0.0", (">=1.1.0",), replace="clean 1.0.1"
                    )
                )
            ),
            locked,
        ),
    )

    case = root / "identity"
    case.mkdir()
    project = prepare_project(
        case,
        (("app", "0.1.0"), ("dual", "1.0.0"), ("dual", "1.0.0")),
        sources={"dual@1.0.0": REGISTRY},
    )
    lockfile = project / "Cargo.lock"
    instances = module.locked_instances(lockfile)
    assert instances["dual"] == registry("1.0.0")
    assert instances["app"] == (("0.1.0", ""),)
    replaced = lockfile.read_text(encoding="utf-8") + '\n[[package]]\nname = "old"\nversion = "1.0.0"\nreplace = "old 1.0.1"\n'
    lockfile.write_text(replaced, encoding="utf-8")
    assert_raises(module.RemediationError, "Cargo.lock replaces old@1.0.0", lambda: module.locked_instances(lockfile))


def test_captured_report(module) -> None:
    """Guard the captured field shape, and print each diagnostic once per run."""
    parsed = module.parse_report(CAPTURED_REPORT)
    assert parsed["vulnerabilities"]["count"] == 1 and parsed["warnings"] == {}
    assert parsed["vulnerabilities"]["list"][0]["package"]["source"] == REGISTRY
    diagnostics = module.parse_report(
        report(
            warnings={
                "unmaintained": [warning("unmaintained", "abandoned", "1.0.0", "RUSTSEC-2099-0100")],
                "yanked": [warning("yanked", "pulled", "2.0.0")],
            }
        )
    )
    output = io.StringIO()
    seen = set()
    with contextlib.redirect_stdout(output):
        module.report_diagnostics(diagnostics, seen)
        module.report_diagnostics(diagnostics, seen)
    assert output.getvalue().splitlines() == [
        "cargo remediation: diagnostic unmaintained RUSTSEC-2099-0100 in abandoned@1.0.0",
        "cargo remediation: diagnostic yanked yanked in pulled@2.0.0",
    ]


def test_locked_instances(module, root: Path) -> None:
    case = root / "locked"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"), ("dupe", "0.3.10"), ("dupe", "0.1.40")))
    lockfile = project / "Cargo.lock"
    assert module.locked_instances(lockfile) == {
        "app": (("0.1.0", ""),),
        "dupe": registry("0.1.40", "0.3.10"),
    }
    lockfile.write_text("version = 4\n", encoding="utf-8")
    assert_raises(module.RemediationError, "locks no packages", lambda: module.locked_instances(lockfile))
    lockfile.write_text('version = 4\n\n[[package]]\nname = "x"\nversion = "one"\n', encoding="utf-8")
    assert_raises(module.RemediationError, "invalid locked crate version", lambda: module.locked_instances(lockfile))
    lockfile.write_text("[[package\n", encoding="utf-8")
    assert_raises(module.RemediationError, "malformed Cargo.lock", lambda: module.locked_instances(lockfile))


def test_optional_dependency_feature_selection(module) -> None:
    packages = (
        ("app", "app", "0.1.0", ""),
        ("always", "always", "1.0.0", REGISTRY),
        ("optional", "optional", "1.0.0", REGISTRY),
    )
    locked = graph_locked(packages)
    no_defaults = cargo_graph(
        packages,
        ("app",),
        {"app": (("always", ((None, None),)),)},
    )
    selected = module.parse_shipped_graph(no_defaults, locked)
    assert ("always", "1.0.0", REGISTRY) in selected
    assert ("optional", "1.0.0", REGISTRY) not in selected

    with_feature = cargo_graph(
        packages,
        ("app",),
        {"app": (("always", ((None, None),)), ("optional", ((None, None),)))},
    )
    assert ("optional", "1.0.0", REGISTRY) in module.parse_shipped_graph(
        with_feature, locked
    )


def test_release_dependency_kinds(module) -> None:
    packages = (
        ("app", "app", "0.1.0", ""),
        ("normal", "normal", "1.0.0", REGISTRY),
        ("build", "build", "1.0.0", REGISTRY),
        ("dev", "dev", "1.0.0", REGISTRY),
    )
    raw = cargo_graph(
        packages,
        ("app",),
        {
            "app": (
                ("normal", ((None, None),)),
                ("build", (("build", None),)),
                ("dev", (("dev", None),)),
            )
        },
    )
    shipped = module.parse_shipped_graph(raw, graph_locked(packages))
    assert shipped == {
        ("app", "0.1.0", ""),
        ("normal", "1.0.0", REGISTRY),
        ("build", "1.0.0", REGISTRY),
    }


def test_duplicate_source_identity_graph(module) -> None:
    alternate = "registry+https://example.invalid/index"
    packages = (
        ("app", "app", "0.1.0", ""),
        ("crates-io-dupe", "dupe", "1.0.0", REGISTRY),
        ("alternate-dupe", "dupe", "1.0.0", alternate),
    )
    locked = graph_locked(packages)
    raw = cargo_graph(
        packages,
        ("app",),
        {"app": (("alternate-dupe", ((None, None),)),)},
    )
    shipped = module.parse_shipped_graph(raw, locked)
    assert ("dupe", "1.0.0", alternate) in shipped
    assert ("dupe", "1.0.0", REGISTRY) not in shipped
    updates, _, _, _, excluded = module.derive_fixes(
        json.loads(
            report(vulnerability("RUSTSEC-2099-0200", "dupe", "1.0.0", (">=1.1.0",)))
        ),
        locked,
        shipped,
    )
    assert updates == {}
    assert excluded == {("RUSTSEC-2099-0200", "dupe", "1.0.0", REGISTRY)}
    assert_raises(
        module.RemediationError,
        "Cargo.lock locks from 2 sources",
        lambda: module.derive_fixes(
            json.loads(
                report(
                    vulnerability(
                        "RUSTSEC-2099-0201",
                        "dupe",
                        "1.0.0",
                        (">=1.1.0",),
                        source=alternate,
                    )
                )
            ),
            locked,
            shipped,
        ),
    )


def test_workspace_default_members(module) -> None:
    packages = (
        ("member-a", "member-a", "0.1.0", ""),
        ("member-b", "member-b", "0.1.0", ""),
        ("dep-a", "dep-a", "1.0.0", REGISTRY),
        ("dep-b", "dep-b", "1.0.0", REGISTRY),
    )
    edges = {
        "member-a": (("dep-a", ((None, None),)),),
        "member-b": (("dep-b", ((None, None),)),),
    }
    default_graph = cargo_graph(packages, ("member-a",), edges)
    shipped = module.parse_shipped_graph(default_graph, graph_locked(packages))
    assert ("dep-a", "1.0.0", REGISTRY) in shipped
    assert ("dep-b", "1.0.0", REGISTRY) not in shipped
    virtual_default_graph = cargo_graph(packages, ("member-a", "member-b"), edges)
    shipped = module.parse_shipped_graph(virtual_default_graph, graph_locked(packages))
    assert ("dep-a", "1.0.0", REGISTRY) in shipped
    assert ("dep-b", "1.0.0", REGISTRY) in shipped
    member_graph = cargo_graph(
        packages,
        ("member-a",),
        edges,
        workspace_root="/workspace",
        current="member-b",
    )
    shipped = module.parse_shipped_graph(member_graph, graph_locked(packages))
    assert ("dep-a", "1.0.0", REGISTRY) not in shipped
    assert ("dep-b", "1.0.0", REGISTRY) in shipped


def test_target_conditioned_dependencies(module) -> None:
    packages = (
        ("app", "app", "0.1.0", ""),
        ("unix", "unix-only", "1.0.0", REGISTRY),
        ("windows", "windows-only", "1.0.0", REGISTRY),
    )
    current_target = cargo_graph(
        packages,
        ("app",),
        {"app": (("unix", ((None, "cfg(unix)"),)),)},
    )
    shipped = module.parse_shipped_graph(current_target, graph_locked(packages))
    assert ("unix-only", "1.0.0", REGISTRY) in shipped
    assert ("windows-only", "1.0.0", REGISTRY) not in shipped
    assert_raises(
        module.RemediationError,
        "cargo target must not be empty",
        lambda: module.metadata_arguments([], True, ""),
    )
    mixed_kinds = cargo_graph(
        packages,
        ("app",),
        {
            "app": ((
                "unix",
                ((None, "cfg(windows)"), ("dev", "cfg(unix)")),
            ),)
        },
    )
    shipped = module.parse_shipped_graph(mixed_kinds, graph_locked(packages))
    assert ("unix-only", "1.0.0", REGISTRY) in shipped


def test_feature_argument_compatibility(module) -> None:
    assert module.metadata_arguments([], True, "host-tuple")[1:] == METADATA
    assert module.metadata_arguments(
        ["sources-stdin", "sinks-console"], False, "aarch64-unknown-linux-musl"
    )[1:] == [
        "metadata",
        "--locked",
        "--format-version",
        "1",
        "--filter-platform",
        "aarch64-unknown-linux-musl",
        "--no-default-features",
        "--features",
        "sources-stdin,sinks-console",
    ]


def test_vector_release_graph(module) -> None:
    packages = (
        ("vector", "vector", "0.57.0", ""),
        ("h2-old", "h2", "0.3.26", REGISTRY),
        ("h2-shipped", "h2", "0.4.15", REGISTRY),
        ("eligible", "eligible", "1.0.0", REGISTRY),
    )
    locked = graph_locked(packages)
    raw = cargo_graph(
        packages,
        ("vector",),
        {"vector": (("h2-shipped", ((None, None),)), ("eligible", ((None, None),)))},
        current="vector",
    )
    shipped = module.parse_shipped_graph(raw, locked)
    vector_findings = json.loads(
        report(
            vulnerability("RUSTSEC-2024-0003", "h2", "0.3.26", (">=0.4.16",)),
            vulnerability("RUSTSEC-2099-0300", "eligible", "1.0.0", (">=1.1.0",)),
        )
    )
    updates, _, detected, fixable, excluded = module.derive_fixes(
        vector_findings, locked, shipped
    )
    assert updates == {("eligible", "1.0.0"): "1.1.0"}
    assert detected == fixable == {("RUSTSEC-2099-0300", "eligible", "1.0.0")}
    assert excluded == {("RUSTSEC-2024-0003", "h2", "0.3.26", REGISTRY)}
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        seen = set()
        module.report_unshipped(excluded, seen)
        module.report_unshipped(excluded, seen)
    assert (
        output.getvalue().count("diagnostic unshipped RUSTSEC-2024-0003 in h2@0.3.26")
        == 1
    )


def test_malformed_graph_fails_closed(module) -> None:
    packages = (("app", "app", "0.1.0", ""), ("dep", "dep", "1.0.0", REGISTRY))
    locked = graph_locked(packages)
    assert_raises(
        module.RemediationError,
        "malformed cargo metadata JSON",
        lambda: module.parse_shipped_graph("not-json", locked),
    )
    wrong_source = cargo_graph(
        (
            ("app", "app", "0.1.0", ""),
            ("dep", "dep", "1.0.0", "registry+https://wrong.invalid"),
        ),
        ("app",),
        {"app": (("dep", ((None, None),)),)},
    )
    assert_raises(
        module.RemediationError,
        "cannot be correlated to Cargo.lock",
        lambda: module.parse_shipped_graph(wrong_source, locked),
    )



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
    assert module.locked_instances(project / "Cargo.lock")["abandoned"] == registry("1.0.0")

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
    assert module.locked_instances(project / "Cargo.lock")["directvuln"] == registry("1.2.0")
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "directvuln@1.0.0=1.2.0", "--fail-on-unapplied-pins",
    ]]
    assert logged(case / "cargo.log") == [METADATA, *VERIFICATION]
    assert "cargo remediation: applying directvuln@1.0.0=1.2.0" in output
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
    assert module.locked_instances(project / "Cargo.lock")["transitive"] == registry("1.1.0")
    manifest = project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert "transitive" not in manifest and 'wrapper = "2.0.0"' in manifest
    assert logged(case / "omnibump.log")[0][5] == "transitive@1.0.0=1.1.0"


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
    assert module.locked_instances(project / "Cargo.lock")["boundary"] == registry("4.0.0")
    assert 'boundary = "4.0.0"' in project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert logged(case / "omnibump.log")[0][5] == "boundary@3.5.0=4.0.0"


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
        sources={"member-one@0.1.0": "", "member-two@0.1.0": ""},
        features="sources-stdin sinks-console",
    )
    assert module.locked_instances(project / "Cargo.lock")["shared"] == registry("0.9.5")
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "shared@0.9.1=0.9.5", "--fail-on-unapplied-pins",
        "--features", "sources-stdin,sinks-console",
    ]]
    for member in ("member-one", "member-two"):
        assert 'shared = "0.9.5"' in project.joinpath(member, "Cargo.toml").read_text(encoding="utf-8")


def test_duplicate_lock_versions(module, root: Path) -> None:
    # Each vulnerable line has a fix on its own line, so one invocation carries
    # both pins and omnibump lands each without stranding the lower line.
    per_line = findings(
        vulnerability("RUSTSEC-2099-0005", "dupe", "0.1.40", (">=0.1.45",)),
        vulnerability("RUSTSEC-2099-0006", "dupe", "0.3.10", (">=0.3.20",)),
    )
    case, project, _ = remediate(
        module,
        root,
        "duplicates",
        [per_line, findings()],
        (("app", "0.1.0"), ("dupe", "0.1.40"), ("dupe", "0.3.10")),
    )
    assert module.locked_instances(project / "Cargo.lock")["dupe"] == registry("0.1.45", "0.3.20")
    assert logged(case / "omnibump.log")[0][5] == "dupe@0.1.40=0.1.45 dupe@0.3.10=0.3.20"

    # Explicit source versions also let both lines converge on one fixed release.
    cross_line = findings(
        vulnerability("RUSTSEC-2099-0006", "dupe", "0.1.40", (">=0.3.20",)),
        vulnerability("RUSTSEC-2099-0006", "dupe", "0.3.10", (">=0.3.20",)),
    )
    case, project, _ = remediate(
        module,
        root,
        "duplicates-cross-line",
        [cross_line, findings()],
        (("app", "0.1.0"), ("dupe", "0.1.40"), ("dupe", "0.3.10")),
    )
    assert module.locked_instances(project / "Cargo.lock")["dupe"] == registry("0.3.20")
    assert logged(case / "omnibump.log")[0][5] == "dupe@0.1.40=0.3.20 dupe@0.3.10=0.3.20"


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
    locked = module.locked_instances(project / "Cargo.lock")
    assert locked["alpha"] == registry("1.2.0") and locked["beta"] == registry("2.3.0")
    assert logged(case / "omnibump.log") == [[
        "--language", "rust", "--dir", str(project),
        "--packages", "alpha@1.0.0=1.2.0 beta@2.0.0=2.3.0", "--fail-on-unapplied-pins",
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
    locked = module.locked_instances(project / "Cargo.lock")
    assert locked["exporter"] == registry("1.2.0") and locked["core"] == registry("1.2.0")
    assert logged(case / "omnibump.log") == [
        ["--language", "rust", "--dir", str(project), "--packages", "exporter@1.0.0=1.2.0", "--fail-on-unapplied-pins"],
        ["--language", "rust", "--dir", str(project), "--packages", "core@1.1.0=1.2.0", "--fail-on-unapplied-pins"],
    ]
    assert case.joinpath("scan-state").read_text(encoding="utf-8") == "3"
    assert logged(case / "cargo.log") == [METADATA, METADATA, *VERIFICATION]
    assert output.count("cargo remediation: applying") == 2


def test_no_progress(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0011", "stuck", "1.0.0", (">=1.2.0",)))
    assert_raises(
        module.RemediationError,
        "cargo remediation pass made no lock graph progress: stuck@1.0.0=1.2.0",
        lambda: remediate(
            module,
            root,
            "stalled",
            [vulnerable, vulnerable],
            (("app", "0.1.0"), ("stuck", "1.0.0")),
            environment={"OMNIBUMP_MODE": "noop"},
        ),
    )

def test_persisted_vulnerable_identity(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0041", "partial", "1.0.0", (">=1.2.0",)))
    assert_raises(
        module.RemediationError,
        "vulnerable crate versions remain after remediation: RUSTSEC-2099-0041:partial@1.0.0",
        lambda: remediate(
            module,
            root,
            "partial-update",
            [vulnerable, vulnerable],
            (("app", "0.1.0"), ("partial", "1.0.0"), ("partial", "1.0.0")),
            environment={"OMNIBUMP_MODE": "partial"},
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

    # A duplicate-version regression that leaves the maximum version intact.
    duplicates = findings(
        vulnerability("RUSTSEC-2099-0014", "sunk", "0.1.40", (">=0.3.20",)),
        vulnerability("RUSTSEC-2099-0014", "sunk", "0.3.10", (">=0.3.20",)),
    )
    assert_raises(
        module.RemediationError,
        "cargo remediation downgraded locked crates: sunk@0.1.40->0.0.1",
        lambda: remediate(
            module,
            root,
            "downgrade-duplicate",
            [duplicates, findings()],
            (("app", "0.1.0"), ("sunk", "0.1.40"), ("sunk", "0.3.10")),
            environment={"OMNIBUMP_MODE": "sink"},
        ),
    )

    # An added high version must not hide a lower replacement at another rank.
    assert_raises(
        module.RemediationError,
        "cargo remediation downgraded locked crates: masked@5.0.0->4.0.0",
        lambda: module.reject_downgrades(
            {"masked": registry("1.0.0", "5.0.0", "10.0.0")},
            {"masked": registry("1.0.0", "4.0.0", "10.0.0", "11.0.0")},
        ),
    )
    # Removing unchanged instances first must still permit multiple upgrades.
    module.reject_downgrades(
        {"raised": registry("1.0.0", "10.0.0")},
        {"raised": registry("2.0.0", "11.0.0")},
    )
    # Pure additions and removals have no replacement to classify as a downgrade.
    module.reject_downgrades(
        {"expanded": registry("5.0.0")},
        {"expanded": registry("1.0.0", "5.0.0", "11.0.0")},
    )
    module.reject_downgrades(
        {"contracted": registry("1.0.0", "5.0.0", "10.0.0")},
        {"contracted": registry("1.0.0", "10.0.0")},
    )


def test_unapplied_fix_is_loud(module, root: Path) -> None:
    vulnerable = findings(vulnerability("RUSTSEC-2099-0013", "blocked", "1.0.0", (">=1.2.0",)))
    case = root / "unapplied"
    error = "no compatible version can be upgraded to: blocked is not declared by workspace member"
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
    assert logged(case / "cargo.log") == [METADATA]
    assert case.joinpath("scan-state").read_text(encoding="utf-8") == "1"

def test_graph_incompatible_fix_is_diagnostic(module, root: Path) -> None:
    blocked = vulnerability("RUSTSEC-2099-0042", "blocked", "1.0.0", (">=2.0.0",))
    movable = vulnerability("RUSTSEC-2099-0043", "movable", "1.0.0", (">=1.2.0",))
    case, project, output = remediate(
        module,
        root,
        "graph-incompatible",
        [findings(blocked, movable), findings(blocked)],
        (("app", "0.1.0"), ("blocked", "1.0.0"), ("movable", "1.0.0")),
        dependencies=(("blocked", "1.0.0"), ("movable", "1.0.0")),
        environment={
            "OMNIBUMP_BLOCKED_PACKAGE": "blocked",
            "OMNIBUMP_BLOCKED_MUTATES": "1",
        },
    )
    locked = module.locked_instances(project / "Cargo.lock")
    assert locked["blocked"] == registry("1.0.0")
    assert locked["movable"] == registry("1.2.0")
    assert "partial omnibump mutation" not in project.joinpath("Cargo.toml").read_text(encoding="utf-8")
    assert "partial omnibump mutation" not in project.joinpath("Cargo.lock").read_text(encoding="utf-8")
    assert [entry[5] for entry in logged(case / "omnibump.log")] == [
        "blocked@1.0.0=2.0.0 movable@1.0.0=1.2.0",
        "blocked@1.0.0=2.0.0",
        "movable@1.0.0=1.2.0",
    ]
    assert "cargo remediation: diagnostic incompatible blocked@1.0.0=2.0.0" in output
    assert logged(case / "cargo.log") == [METADATA, METADATA, *VERIFICATION]


def test_pass_limit(module, root: Path) -> None:
    case = root / "limit"
    case.mkdir()
    project = prepare_project(case, (("app", "0.1.0"),))
    tool_dir, _, _ = prepare_tool_dir(case)
    limit = module.MAX_REMEDIATION_PASSES
    state = {f"crate{index}": registry("1.0.0") for index in range(limit + 1)}
    scans = 0

    def scan(*_args, **_kwargs):
        nonlocal scans
        scans += 1
        return {"vulnerabilities": {"list": [{}]}, "index": scans - 1}

    def derive_fixes(report, _locked, _shipped):
        index = report["index"]
        crate = f"crate{index}"
        identity = (f"RUSTSEC-2099-{index:04d}", crate, "1.0.0")
        return {(crate, "1.0.0"): "1.1.0"}, [], {identity}, {identity}, set()

    def run_command(arguments, _cwd, capture=False, report=False):
        assert arguments[0] == "omnibump" and report and not capture
        for pin in arguments[arguments.index("--packages") + 1].split():
            crate, transition = pin.rsplit("@", 1)
            _, version = transition.split("=", 1)
            state[crate] = registry(version)
        return ""

    module.verify_tool = lambda *_args, **_kwargs: None
    module.report_diagnostics = lambda *_args, **_kwargs: None
    module.scan = scan
    module.shipped_instances = lambda *_args, **_kwargs: set()
    module.derive_fixes = derive_fixes
    module.locked_instances = lambda *_args, **_kwargs: dict(state)
    module.run_command = run_command
    module.verify = lambda *_args, **_kwargs: None
    previous_argv = sys.argv
    sys.argv = [
        "remediate.py",
        "cargo-audit",
        str(project),
        "",
        "true",
        "host-tuple",
        str(tool_dir),
    ]
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
    tool_dir, _, _ = prepare_tool_dir(case)
    previous_argv = sys.argv
    try:
        sys.argv = ["remediate.py", "cargo-audit", str(project), ""]
        assert_raises(module.RemediationError, "usage: remediate.py", module.main)
        sys.argv = ["remediate.py", "cargo-audit", str(case), "", "true", "host-tuple", str(tool_dir)]
        assert_raises(module.RemediationError, "no Cargo.lock in", module.main)
    finally:
        sys.argv = previous_argv


def pipeline_script(
    crateroot: str = ".",
    features: str = "",
    default_features: str = "true",
    target: str = "host-tuple",
) -> str:
    block = PIPELINE.read_text(encoding="utf-8").split("  - runs: |\n", 1)[1]
    script = (
        "\n".join(line.removeprefix("      ") for line in block.splitlines()) + "\n"
    )
    return (
        script.replace("${{inputs.crateroot}}", crateroot)
        .replace("${{inputs.features}}", features)
        .replace("${{inputs.default-features}}", default_features)
        .replace("${{inputs.target}}", target)
    )



def test_wrapper_contract(root: Path) -> None:
    case = root / "wrapper"
    case.mkdir()
    wrapper = case / "cargo-wrapper"
    wrapper.write_text(extract_cargo_wrapper(), encoding="utf-8")
    wrapper.chmod(0o755)
    real = case / "real-cargo"
    real.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "with open(os.environ['WRAPPER_LOG'], 'a', encoding='utf-8') as stream:\n"
        "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n",
        encoding="utf-8",
    )
    real.chmod(0o755)
    wrapper_log = case / "wrapper.log"
    environment = dict(
        os.environ,
        CARGO_REMEDIATE_REAL_CARGO=str(real),
        CARGO_REMEDIATE_DEFAULT_FEATURES="false",
        CARGO_REMEDIATE_FEATURES="",
        CARGO_REMEDIATE_TARGET="aarch64-unknown-linux-musl",
        WRAPPER_LOG=str(wrapper_log),
    )
    for arguments in (
        ["metadata", "--format-version", "1", "--all-features"],
        ["+stable", "tree", "-e", "normal,build", "--all-features"],
        ["update", "--locked"],
        ["check", "--workspace", "--release", "--all-features"],
    ):
        assert (
            subprocess.run(
                [str(wrapper), *arguments], env=environment, check=False
            ).returncode
            == 0
        )
    environment["CARGO_REMEDIATE_DEFAULT_FEATURES"] = "true"
    assert (
        subprocess.run(
            [str(wrapper), "metadata", "--format-version", "1", "--all-features"],
            env=environment,
            check=False,
        ).returncode
        == 0
    )
    environment["CARGO_REMEDIATE_FEATURES"] = "selected"
    assert (
        subprocess.run(
            [str(wrapper), "metadata", "--features", "selected"],
            env=environment,
            check=False,
        ).returncode
        == 0
    )
    assert logged(wrapper_log) == [
        [
            "metadata",
            "--filter-platform",
            "aarch64-unknown-linux-musl",
            "--locked",
            "--format-version",
            "1",
            "--no-default-features",
        ],
        [
            "+stable",
            "tree",
            "--target",
            "aarch64-unknown-linux-musl",
            "--locked",
            "-e",
            "normal,build",
            "--no-default-features",
        ],
        ["update", "--locked"],
        [
            "check",
            "--target",
            "aarch64-unknown-linux-musl",
            "--locked",
            "--release",
            "--no-default-features",
        ],
        [
            "metadata",
            "--filter-platform",
            "aarch64-unknown-linux-musl",
            "--locked",
            "--format-version",
            "1",
        ],
        [
            "metadata",
            "--filter-platform",
            "aarch64-unknown-linux-musl",
            "--locked",
            "--features",
            "selected",
        ],
    ]
    valid = case / "valid.sh"
    valid.write_text(pipeline_script(), encoding="utf-8")
    assert subprocess.run(["sh", "-n", str(valid)], capture_output=True).returncode == 0
    escaping = case / "escaping.sh"
    escaping.write_text(pipeline_script(crateroot="/"), encoding="utf-8")
    completed = subprocess.run(
        ["sh", str(escaping)], cwd=case, capture_output=True, text=True
    )
    assert completed.returncode == 1, completed
    assert "escapes workspace" in completed.stderr



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
    assert '"--db", str(database), "--url", DATABASE_URL' in pipeline
    assert "cargo-remediation-evidence" not in pipeline and "lockContentHash" not in pipeline
    needs = pipeline.split("inputs:", 1)[0]
    assert "- omnibump" in needs and "- python3" in needs and "cargo-audit" not in needs


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        module = load_resolver(root)
        test_scan_contract(module, root)
        test_policy_overrides_rejected(module, root)
        test_audit_isolation(module, root)
        test_requirement_floor(module)
        test_fix_selection(module)
        test_blocking_classifications(module)
        test_crate_identity(module, root)
        test_captured_report(module)
        test_locked_instances(module, root)
        test_optional_dependency_feature_selection(module)
        test_release_dependency_kinds(module)
        test_duplicate_source_identity_graph(module)
        test_workspace_default_members(module)
        test_target_conditioned_dependencies(module)
        test_feature_argument_compatibility(module)
        test_vector_release_graph(module)
        test_malformed_graph_fails_closed(module)
        test_clean_audit_verifies(module, root)
        test_direct_fix(module, root)
        test_transitive_fix(module, root)
        test_semver_boundary(module, root)
        test_workspace_dependency(module, root)
        test_duplicate_lock_versions(module, root)
        test_coordinated_multi_crate(module, root)
        test_newly_exposed_finding(module, root)
        test_no_progress(module, root)
        test_persisted_vulnerable_identity(module, root)
        test_downgrade_rejected(module, root)
        test_unapplied_fix_is_loud(module, root)
        test_argument_contract(module, root)
        test_wrapper_contract(root)
    # A fresh module: the pass-limit case replaces resolver functions.
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        test_pass_limit(load_resolver(root), root)
    test_pipeline_contract()
    print("passed scripts/test_cargo_remediation.py")


if __name__ == "__main__":
    main()
