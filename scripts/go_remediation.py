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


def parse_version(value: str) -> tuple[int, int, int, tuple[tuple[int, str], ...]]:
    match = VERSION.fullmatch(value)
    if match is None:
        raise LockError(f"invalid module version: {value!r}")
    prerelease: tuple[tuple[int, str], ...] = ()
    if match.group(4):
        prerelease = tuple(
            (0, f"{int(part):020d}") if part.isdecimal() else (1, part)
            for part in match.group(4).split(".")
        )
    return int(match.group(1)), int(match.group(2)), int(match.group(3)), prerelease


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
        "findings": sorted(findings, key=lambda item: canonical(item)),
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
    if lock.get("schemaVersion") != SCHEMA_VERSION or lock.get("tool") != TOOL:
        raise LockError("unsupported remediation lock")
    source = lock.get("source")
    if not isinstance(source, dict) or COMMIT.fullmatch(str(source.get("commit", ""))) is None:
        raise LockError("invalid source commit")
    if not isinstance(source.get("version"), str) or not source["version"]:
        raise LockError("invalid source version")
    database = lock.get("database")
    if not isinstance(database, dict) or SHA256.fullmatch(str(database.get("sha256", ""))) is None:
        raise LockError("invalid database provenance")
    scan = lock.get("scan")
    if not isinstance(scan, dict) or SHA256.fullmatch(str(scan.get("captureSha256", ""))) is None:
        raise LockError("invalid scan capture")
    safe_relative(str(scan.get("moduleRoot", "")))
    patterns = scan.get("packages")
    if not isinstance(patterns, list) or not patterns or not all(isinstance(item, str) and item and not item.startswith("-") for item in patterns):
        raise LockError("invalid scan package patterns")
    if scan.get("phase") not in {"source", "post-generation"}:
        raise LockError("invalid scan phase")
    for update in lock.get("updates", []):
        if not isinstance(update, dict):
            raise LockError("invalid update")
        safe_relative(str(update.get("moduleRoot", "")))
        if not compatible(str(update.get("module", "")), str(update.get("fixedVersion", ""))):
            raise LockError("unsafe module update")
        parse_version(str(update.get("oldVersion", "")))
    if lock.get("contentHash") != lock_hash(lock):
        raise LockError("lock content hash mismatch")
    if capture is not None and scan["captureSha256"] != digest(capture):
        raise LockError("captured scan hash mismatch")


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


def run_go(arguments: list[str], cwd: Path, output: bool = False) -> str:
    environment = dict(os.environ, GOTOOLCHAIN="local", GOWORK="off", GOPROXY="off", GOSUMDB="off")
    completed = subprocess.run(arguments, cwd=cwd, env=environment, check=True, text=True, capture_output=output)
    return completed.stdout if output else ""


def file_hash(path: Path) -> str | None:
    return digest(path.read_bytes()) if path.is_file() else None


def apply(lock_path: Path, root: Path, evidence_path: Path) -> None:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    validate_lock(lock)
    roots = {safe_relative(update["moduleRoot"]): (root / safe_relative(update["moduleRoot"])).resolve() for update in lock["updates"]}
    for update in lock["updates"]:
        run_go(["go", "mod", "edit", f"-require={update['module']}@{update['fixedVersion']}"], roots[update["moduleRoot"]])
    selected: dict[str, str] = {}
    for relative, module in sorted(roots.items()):
        patterns = lock["scan"]["packages"] if relative == lock["scan"]["moduleRoot"] else ["./..."]
        run_go(["go", "list", "-mod=readonly", *patterns], module)
        listing = run_go(["go", "list", "-mod=readonly", "-m", "-f", "{{.Path}} {{.Version}}", "all"], module, True)
        selected.update(line.split(" ", 1) for line in listing.splitlines() if " " in line)
        if (module / "vendor").is_dir():
            run_go(["go", "list", "-mod=vendor", *patterns], module)
    if (root / "go.work").is_file():
        run_go(["go", "work", "sync"], root)
        if (root / "vendor").is_dir():
            run_go(["go", "list", "-mod=vendor", *lock["scan"]["packages"]], root)
    for update in lock["updates"]:
        if selected.get(update["module"]) != update["fixedVersion"]:
            raise LockError(f"selected version mismatch for {update['module']}")
    evidence = {
        "schemaVersion": SCHEMA_VERSION,
        "lockContentHash": lock["contentHash"],
        "source": lock["source"],
        "tool": lock["tool"],
        "database": lock["database"],
        "scan": lock["scan"],
        "updates": lock["updates"],
        "nonFixable": lock["nonFixable"],
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
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate(args.spec, args.lock)
        elif args.command == "validate":
            validate_lock(json.loads(args.lock.read_text(encoding="utf-8")), args.capture.read_bytes())
        elif args.command == "apply":
            apply(args.lock, args.root.resolve(), args.evidence)
        else:
            bump_epoch(args.recipe, args.old_lock, args.new_lock)
    except (LockError, KeyError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
