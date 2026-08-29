#!/usr/bin/env python3
"""Generate, validate, and apply reviewed Go vulnerability remediation locks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
TOOL = {
    "module": "golang.org/x/vuln/cmd/govulncheck",
    "version": "v1.7.0",
    "protocol": "v1.0.0",
}
MODULE = re.compile(r"^(?=.{1,255}$)[A-Za-z0-9][A-Za-z0-9._~-]*(?:/[A-Za-z0-9._~+-]+)+$")
VERSION = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
SHA256 = re.compile(r"^sha256:[a-f0-9]{64}$")
COMMIT = re.compile(r"^[a-f0-9]{40}$")


class LockError(ValueError):
    pass


def canonical(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, separators=(",", ": ")) + "\n").encode()


def digest(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def parse_version(value: str) -> tuple[int, int, int, int, tuple[tuple[int, str], ...]]:
    match = VERSION.fullmatch(value)
    if match is None:
        raise LockError(f"invalid module version: {value!r}")
    prerelease = match.group(4)
    identifiers = (
        tuple((0, f"{int(part):020d}") if part.isdecimal() else (1, part) for part in prerelease.split("."))
        if prerelease
        else ()
    )
    return int(match.group(1)), int(match.group(2)), int(match.group(3)), 0 if prerelease else 1, identifiers


def compatible(module: str, version: str) -> bool:
    if MODULE.fullmatch(module) is None:
        raise LockError(f"invalid module path: {module!r}")
    major = parse_version(version)[0]
    suffix = re.search(r"/v([0-9]+)$", module)
    if module.startswith("gopkg.in/"):
        suffix = re.search(r"\.v([0-9]+)$", module)
        if suffix is None:
            return False
    expected = int(suffix.group(1)) if suffix else None
    return (expected is None and major < 2) or expected == major


def message_stream(raw: str) -> list[dict[str, Any]]:
    decoder = json.JSONDecoder()
    result: list[dict[str, Any]] = []
    offset = 0
    while offset < len(raw):
        while offset < len(raw) and raw[offset].isspace():
            offset += 1
        if offset == len(raw):
            break
        try:
            value, offset = decoder.raw_decode(raw, offset)
        except json.JSONDecodeError as error:
            raise LockError(f"malformed govulncheck JSON: {error}") from error
        if not isinstance(value, dict) or len(value) != 1:
            raise LockError("invalid govulncheck message")
        result.append(value)
    if not result:
        raise LockError("empty govulncheck output")
    config = result[0].get("config")
    if not isinstance(config, dict):
        raise LockError("govulncheck output must begin with config")
    if config.get("protocol_version") != TOOL["protocol"] or config.get("scanner_name") != "govulncheck":
        raise LockError("unsupported govulncheck protocol")
    if config.get("scanner_version") != TOOL["version"]:
        raise LockError("unexpected govulncheck version")
    return result


def fixed_version(entry: dict[str, Any], module: str, current: str) -> tuple[str, str]:
    current_key = parse_version(current)
    candidates: list[str] = []
    incompatible = False
    affected = entry.get("affected")
    if not isinstance(affected, list):
        raise LockError("invalid OSV affected records")
    for record in affected:
        if not isinstance(record, dict):
            raise LockError("invalid OSV affected record")
        package = record.get("package")
        if not isinstance(package, dict) or not isinstance(package.get("name"), str):
            raise LockError("invalid OSV package")
        fixes: list[str] = []
        ranges = record.get("ranges", [])
        if not isinstance(ranges, list):
            raise LockError("invalid OSV ranges")
        for interval in ranges:
            if not isinstance(interval, dict):
                raise LockError("invalid OSV range")
            if interval.get("type") != "SEMVER":
                continue
            events = interval.get("events")
            if not isinstance(events, list):
                raise LockError("invalid OSV events")
            active = False
            for event in events:
                if not isinstance(event, dict):
                    raise LockError("invalid OSV event")
                if "introduced" in event:
                    introduced = event["introduced"]
                    if not isinstance(introduced, str):
                        raise LockError("invalid introduced version")
                    active = introduced == "0" or parse_version("v" + introduced.removeprefix("v")) <= current_key
                elif "fixed" in event:
                    fixed = event["fixed"]
                    if not isinstance(fixed, str):
                        raise LockError("invalid fixed version")
                    version = "v" + fixed.removeprefix("v")
                    fixes.append(version)
                    if package["name"] == module and active and current_key < parse_version(version):
                        candidates.append(version)
                    active = False
                else:
                    raise LockError("OSV event has no boundary")
        if package["name"] != module and fixes:
            incompatible = True
    if candidates:
        fixed = min(candidates, key=parse_version)
        return (fixed, "") if compatible(module, fixed) else ("", "no-compatible-fix")
    return "", "no-compatible-fix" if incompatible else "no-fix"


def derive(raw: str) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    stream = message_stream(raw)
    osvs: dict[str, dict[str, Any]] = {}
    findings: list[dict[str, Any]] = []
    for message in stream[1:]:
        if "osv" in message:
            osv = message["osv"]
            if not isinstance(osv, dict) or not isinstance(osv.get("id"), str):
                raise LockError("invalid OSV record")
            osvs[osv["id"]] = osv
        elif "finding" in message:
            finding = message["finding"]
            if not isinstance(finding, dict):
                raise LockError("invalid finding")
            findings.append(finding)
    updates: dict[tuple[str, str], dict[str, Any]] = {}
    nonfixable: dict[tuple[str, str, str], dict[str, Any]] = {}
    for finding in findings:
        osv_id, trace = finding.get("osv"), finding.get("trace")
        if not isinstance(osv_id, str) or osv_id not in osvs or not isinstance(trace, list) or not trace:
            raise LockError("finding cannot be correlated with OSV data")
        frame = trace[0]
        if not isinstance(frame, dict):
            raise LockError("invalid finding frame")
        module, current = frame.get("module"), frame.get("version")
        if not isinstance(module, str) or not isinstance(current, str) or not module or not current:
            raise LockError("finding lacks module identity")
        module_root = str(finding.get("module_root", "."))
        safe_relative(module_root)
        fixed, reason = fixed_version(osvs[osv_id], module, current)
        if not fixed:
            nonfixable[(module_root, module, osv_id)] = {
                "moduleRoot": module_root,
                "module": module,
                "version": current,
                "status": reason,
                "vulnerabilityIds": [osv_id],
            }
            continue
        key = module_root, module
        prior = updates.get(key)
        if prior is None:
            updates[key] = {
                "moduleRoot": module_root,
                "module": module,
                "oldVersion": current,
                "fixedVersion": fixed,
                "vulnerabilityIds": [osv_id],
            }
        else:
            prior["vulnerabilityIds"] = sorted(set(prior["vulnerabilityIds"] + [osv_id]))
            if parse_version(fixed) > parse_version(prior["fixedVersion"]):
                prior["fixedVersion"] = fixed
    capture = {
        "schemaVersion": SCHEMA_VERSION,
        "tool": TOOL,
        "osvs": [osvs[key] for key in sorted(osvs)],
        "findings": sorted(findings, key=canonical),
    }
    return capture, [updates[key] for key in sorted(updates)], [nonfixable[key] for key in sorted(nonfixable)]


def safe_relative(value: str) -> str:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise LockError(f"unsafe relative path: {value!r}")
    return path.as_posix()


def lock_hash(lock: dict[str, Any]) -> str:
    payload = dict(lock)
    payload.pop("contentHash", None)
    return digest(canonical(payload))


def validate_lock(lock: dict[str, Any], capture: bytes | None = None) -> None:
    if not isinstance(lock, dict) or set(lock) != {
        "schemaVersion", "source", "tool", "database", "scan", "updates", "nonFixable", "contentHash"
    }:
        raise LockError("invalid remediation lock fields")
    if lock["schemaVersion"] != SCHEMA_VERSION or lock["tool"] != TOOL:
        raise LockError("unsupported remediation lock")
    source = lock["source"]
    if not isinstance(source, dict) or COMMIT.fullmatch(str(source.get("commit", ""))) is None:
        raise LockError("invalid source commit")
    if not isinstance(source.get("version"), str) or not source["version"]:
        raise LockError("invalid source version")
    database = lock["database"]
    if (
        not isinstance(database, dict)
        or not all(isinstance(database.get(key), str) and database[key] for key in ("source", "revision"))
        or SHA256.fullmatch(str(database.get("sha256", ""))) is None
    ):
        raise LockError("invalid database provenance")
    scan = lock["scan"]
    if not isinstance(scan, dict) or SHA256.fullmatch(str(scan.get("captureSha256", ""))) is None:
        raise LockError("invalid scan capture")
    safe_relative(str(scan.get("moduleRoot", "")))
    safe_relative(str(scan.get("capture", "")))
    patterns = scan.get("packages")
    if not isinstance(patterns, list) or not patterns or not all(isinstance(item, str) and item and not item.startswith("-") for item in patterns):
        raise LockError("invalid scan package patterns")
    if scan.get("phase") not in {"source", "post-generation"}:
        raise LockError("invalid scan phase")
    for collection in ("updates", "nonFixable"):
        if not isinstance(lock[collection], list):
            raise LockError(f"invalid {collection}")
    for update in lock["updates"]:
        if not isinstance(update, dict) or set(update) != {"moduleRoot", "module", "oldVersion", "fixedVersion", "vulnerabilityIds"}:
            raise LockError("invalid update")
        safe_relative(str(update["moduleRoot"]))
        if not compatible(str(update["module"]), str(update["fixedVersion"])):
            raise LockError("unsafe module update")
        if parse_version(str(update["oldVersion"])) >= parse_version(str(update["fixedVersion"])):
            raise LockError("module update does not advance the version")
        ids = update["vulnerabilityIds"]
        if not isinstance(ids, list) or not ids or ids != sorted(set(ids)) or not all(isinstance(item, str) and item for item in ids):
            raise LockError("invalid update vulnerability IDs")
    for record in lock["nonFixable"]:
        if not isinstance(record, dict) or record.get("status") not in {"no-fix", "no-compatible-fix"}:
            raise LockError("invalid non-fixable record")
        safe_relative(str(record.get("moduleRoot", "")))
        if MODULE.fullmatch(str(record.get("module", ""))) is None:
            raise LockError("invalid non-fixable module")
        parse_version(str(record.get("version", "")))
        ids = record.get("vulnerabilityIds")
        if not isinstance(ids, list) or not ids or ids != sorted(set(ids)) or not all(isinstance(item, str) and item for item in ids):
            raise LockError("invalid non-fixable vulnerability IDs")
    if lock["contentHash"] != lock_hash(lock):
        raise LockError("lock content hash mismatch")
    if capture is not None:
        if scan["captureSha256"] != digest(capture):
            raise LockError("captured scan hash mismatch")
        captured = json.loads(capture)
        if captured.get("schemaVersion") != SCHEMA_VERSION or captured.get("tool") != TOOL or captured.get("database") != database:
            raise LockError("captured scan provenance mismatch")


def generate(spec_path: Path, lock_path: Path) -> dict[str, Any]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    capture_source = spec_path.parent / safe_relative(str(spec["capture"]))
    capture, updates, nonfixable = derive(capture_source.read_text(encoding="utf-8"))
    capture["database"] = spec["database"]
    capture_bytes = canonical(capture)
    capture_path = lock_path.with_suffix(".scan.json")
    capture_path.write_bytes(capture_bytes)
    scan = spec["scan"]
    lock = {
        "schemaVersion": SCHEMA_VERSION,
        "source": spec["source"],
        "tool": TOOL,
        "database": spec["database"],
        "scan": {
            "moduleRoot": safe_relative(str(scan["moduleRoot"])),
            "packages": scan["packages"],
            "phase": scan["phase"],
            "capture": capture_path.name,
            "captureSha256": digest(capture_bytes),
        },
        "updates": updates,
        "nonFixable": nonfixable,
    }
    lock["contentHash"] = lock_hash(lock)
    validate_lock(lock, capture_bytes)
    lock_path.write_bytes(canonical(lock))
    return lock


def run_go(arguments: list[str], cwd: Path, output: bool = False, workspace: Path | None = None) -> str:
    gowork = str(workspace) if workspace is not None else "off"
    environment = dict(os.environ, GOTOOLCHAIN="local", GOWORK=gowork, GOPROXY="off", GOSUMDB="off")
    completed = subprocess.run(arguments, cwd=cwd, env=environment, check=True, text=True, capture_output=output)
    return completed.stdout if output else ""


def file_hash(path: Path) -> str | None:
    return digest(path.read_bytes()) if path.is_file() else None


def resolve_module_root(root: Path, relative: str) -> Path:
    candidate = (root / safe_relative(relative)).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise LockError(f"module root escapes workspace: {relative!r}") from error
    if not candidate.is_dir():
        raise LockError(f"module root is not a directory: {relative!r}")
    return candidate


def apply(lock_path: Path, root: Path, evidence_path: Path) -> None:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    capture_path = lock_path.parent / safe_relative(str(lock.get("scan", {}).get("capture", "")))
    validate_lock(lock, capture_path.read_bytes())
    root = root.resolve()
    relatives = {lock["scan"]["moduleRoot"], *(update["moduleRoot"] for update in lock["updates"])}
    roots = {relative: resolve_module_root(root, relative) for relative in relatives}
    expected: dict[tuple[str, str], str] = {}
    for update in lock["updates"]:
        relative = update["moduleRoot"]
        current = run_go(["go", "list", "-m", "-f", "{{.Version}}", update["module"]], roots[relative], True).strip()
        if parse_version(current) >= parse_version(update["fixedVersion"]):
            expected[(relative, update["module"])] = current
            continue
        if current != update["oldVersion"]:
            raise LockError(f"selected version drift for {update['module']}: {current}")
        run_go(["go", "mod", "edit", f"-require={update['module']}@{update['fixedVersion']}"], roots[relative])
        expected[(relative, update["module"])] = update["fixedVersion"]
    selected: dict[tuple[str, str], str] = {}
    for relative, module in sorted(roots.items()):
        patterns = lock["scan"]["packages"] if relative == lock["scan"]["moduleRoot"] else ["./..."]
        run_go(["go", "list", "-mod=readonly", *patterns], module)
        listing = run_go(["go", "list", "-mod=readonly", "-m", "-f", "{{.Path}} {{.Version}}", "all"], module, True)
        selected.update(((relative, path), version) for path, version in (line.split(" ", 1) for line in listing.splitlines() if " " in line))
        if (module / "vendor").is_dir():
            run_go(["go", "list", "-mod=vendor", *patterns], module)
    workspace = root / "go.work"
    if workspace.is_file():
        run_go(["go", "work", "sync"], root, workspace=workspace)
        if (root / "vendor").is_dir():
            scan_root = roots[lock["scan"]["moduleRoot"]]
            run_go(["go", "list", "-mod=vendor", *lock["scan"]["packages"]], scan_root, workspace=workspace)
    for key, version in expected.items():
        if selected.get(key) != version:
            raise LockError(f"selected version mismatch for {key[1]} in {key[0]}")
    evidence = {
        "schemaVersion": SCHEMA_VERSION,
        "lockContentHash": lock["contentHash"],
        "source": lock["source"],
        "tool": lock["tool"],
        "database": lock["database"],
        "scan": lock["scan"],
        "updates": lock["updates"],
        "nonFixable": lock["nonFixable"],
        "selected": [{"moduleRoot": root_key, "module": module, "version": version} for (root_key, module), version in sorted(expected.items())],
        "manifests": {
            relative: {"go.mod": file_hash(module / "go.mod"), "go.sum": file_hash(module / "go.sum"), "vendor/modules.txt": file_hash(module / "vendor/modules.txt")}
            for relative, module in sorted(roots.items())
        },
    }
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_bytes(canonical(evidence))


def bump_epoch(recipe: Path, old_lock: Path, new_lock: Path) -> bool:
    old = json.loads(old_lock.read_text(encoding="utf-8"))
    new = json.loads(new_lock.read_text(encoding="utf-8"))
    if old["contentHash"] == new["contentHash"] or old["source"]["version"] != new["source"]["version"]:
        return False
    text = recipe.read_text(encoding="utf-8")
    match = re.search(r"^(  epoch: )(\d+)$", text, re.MULTILINE)
    if match is None:
        raise LockError("recipe has no numeric epoch")
    recipe.write_text(text[: match.start(2)] + str(int(match.group(2)) + 1) + text[match.end(2) :], encoding="utf-8")
    return True


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise LockError(f"expected JSON object: {path}")
    return value


def scan_specs(root: Path) -> list[Path]:
    return sorted(root.glob("images/**/go-remediation.spec.json"))


def capture_artifact(root: Path, output: Path, repository: str, pr: str, run: str, head: str) -> None:
    if COMMIT.fullmatch(head) is None or not repository or not pr.isdecimal() or not run.isdecimal():
        raise LockError("invalid capture identity")
    output.mkdir(parents=True, exist_ok=True)
    entries: list[dict[str, Any]] = []
    for spec_path in scan_specs(root):
        spec = read_json(spec_path)
        source, database, scan = spec.get("source"), spec.get("database"), spec.get("scan")
        if not isinstance(source, dict) or not isinstance(database, dict) or not isinstance(scan, dict):
            raise LockError(f"invalid scan specification: {spec_path}")
        module_root = safe_relative(str(scan.get("moduleRoot", "")))
        packages = scan.get("packages")
        if scan.get("phase") not in {"source", "post-generation"} or not isinstance(packages, list) or not packages:
            raise LockError(f"unsupported scan specification: {spec_path}")
        workdir = (root / module_root).resolve()
        try:
            workdir.relative_to(root.resolve())
        except ValueError as error:
            raise LockError(f"scan module root escapes repository: {module_root!r}") from error
        if scan["phase"] == "post-generation":
            subprocess.run(
                ["go", "generate", "./..."],
                cwd=workdir,
                env=dict(os.environ, GOTOOLCHAIN="local", GOWORK="off"),
                check=True,
                text=True,
                capture_output=True,
            )
        raw = subprocess.run(
            ["go", "run", f"{TOOL['module']}@{TOOL['version']}", "-json", *packages],
            cwd=workdir,
            env=dict(os.environ, GOTOOLCHAIN="local", GOWORK="off"),
            check=True,
            text=True,
            capture_output=True,
        ).stdout.encode()
        message_stream(raw.decode())
        relative_spec = spec_path.relative_to(root).as_posix()
        raw_path = f"raw/{relative_spec.removesuffix('.json')}.jsonl"
        target = output / raw_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        entries.append(
            {
                "spec": relative_spec,
                "raw": raw_path,
                "rawSha256": digest(raw),
                "source": source,
                "database": database,
                "scan": scan,
            }
        )
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "repository": repository,
        "pr": int(pr),
        "run": int(run),
        "head": head,
        "tool": TOOL,
        "captures": entries,
    }
    (output / "manifest.json").write_bytes(canonical(manifest))


def verify_capture_artifact(artifact: Path, root: Path, repository: str, pr: str, run: str, head: str) -> list[dict[str, Any]]:
    manifest = read_json(artifact / "manifest.json")
    if (
        manifest.get("schemaVersion") != SCHEMA_VERSION
        or manifest.get("repository") != repository
        or manifest.get("pr") != int(pr)
        or manifest.get("run") != int(run)
        or manifest.get("head") != head
        or manifest.get("tool") != TOOL
        or not isinstance(manifest.get("captures"), list)
    ):
        raise LockError("capture artifact identity mismatch")
    expected = {path.relative_to(root).as_posix(): read_json(path) for path in scan_specs(root)}
    verified: list[dict[str, Any]] = []
    for entry in manifest["captures"]:
        if not isinstance(entry, dict) or set(entry) != {"spec", "raw", "rawSha256", "source", "database", "scan"}:
            raise LockError("invalid capture artifact entry")
        spec_name = entry["spec"]
        if not isinstance(spec_name, str) or expected.get(spec_name) is None:
            raise LockError("capture artifact references unknown spec")
        spec = expected.pop(spec_name)
        if any(entry[key] != spec.get(key) for key in ("source", "database", "scan")):
            raise LockError("capture artifact does not match trusted spec")
        raw_path = artifact / safe_relative(str(entry["raw"]))
        raw = raw_path.read_bytes()
        if entry["rawSha256"] != digest(raw):
            raise LockError("capture artifact hash mismatch")
        message_stream(raw.decode())
        verified.append(entry)
    if expected:
        raise LockError("capture artifact omits declared scan")
    return verified


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("spec", type=Path)
    generate_parser.add_argument("lock", type=Path)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("lock", type=Path)
    validate_parser.add_argument("capture", type=Path)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("lock", type=Path)
    apply_parser.add_argument("root", type=Path)
    apply_parser.add_argument("evidence", type=Path)
    epoch_parser = subparsers.add_parser("bump-epoch")
    epoch_parser.add_argument("recipe", type=Path)
    epoch_parser.add_argument("old_lock", type=Path)
    epoch_parser.add_argument("new_lock", type=Path)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--repository", required=True)
    capture_parser.add_argument("--pr", required=True)
    capture_parser.add_argument("--run", required=True)
    capture_parser.add_argument("--head", required=True)
    capture_parser.add_argument("--output", required=True, type=Path)
    verify_parser = subparsers.add_parser("verify-capture")
    verify_parser.add_argument("artifact", type=Path)
    verify_parser.add_argument("--repository", required=True)
    verify_parser.add_argument("--pr", required=True)
    verify_parser.add_argument("--run", required=True)
    verify_parser.add_argument("--head", required=True)
    verify_parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate(args.spec, args.lock)
        elif args.command == "validate":
            validate_lock(read_json(args.lock), args.capture.read_bytes())
        elif args.command == "apply":
            apply(args.lock, args.root.resolve(), args.evidence)
        elif args.command == "capture":
            capture_artifact(Path.cwd(), args.output, args.repository, args.pr, args.run, args.head)
        elif args.command == "verify-capture":
            verify_capture_artifact(args.artifact, args.root, args.repository, args.pr, args.run, args.head)
        else:
            bump_epoch(args.recipe, args.old_lock, args.new_lock)
    except (LockError, KeyError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
