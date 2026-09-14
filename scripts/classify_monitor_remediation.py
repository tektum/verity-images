#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Classify validated monitor findings into safe remediation controllers."""

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import gen_apko_lock_targets
import gen_matrix

ROOT: Final = gen_matrix.ROOT
SCHEMA: Final = "verity-monitor-remediation-plan/v1"
REPORT_SCHEMA: Final = "verity-image-dashboard-report/v1"
APK_RELEASE: Final = re.compile(r"(?P<version>.+)-r(?P<epoch>[0-9]+)$")


class ClassificationError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Stream:
    name: str
    tag_version: str
    context: str
    flavor: str
    track: str
    enabled: bool

    @property
    def target(self) -> str:
        return f"{self.name}@{self.tag_version}"


@dataclass(frozen=True, slots=True)
class RecipeIdentity:
    name: str
    version: str
    epoch: int


def scalar(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ClassificationError(f"{label} must be a non-empty string")
    return value


def recipe_identity(path: Path) -> RecipeIdentity:
    """Read only the top-level package identity from a Melange recipe."""
    values: dict[str, str] = {}
    package = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw == "package:":
            if package:
                raise ClassificationError(f"{path}: duplicate package block")
            package = True
            continue
        if package:
            if raw and not raw[0].isspace():
                break
            match = re.fullmatch(r"  (name|version|epoch):\s*(\S(?:.*\S)?)\s*(?:#.*)?", raw)
            if match is None:
                continue
            key, value = match.groups()
            if key in values:
                raise ClassificationError(f"{path}: duplicate package.{key}")
            values[key] = value.split(" #", maxsplit=1)[0].strip().strip("\"'")
    if set(values) != {"name", "version", "epoch"} or not values["epoch"].isdecimal():
        raise ClassificationError(f"{path}: package identity must declare name, version, and numeric epoch")
    return RecipeIdentity(values["name"], values["version"], int(values["epoch"]))


def streams() -> dict[tuple[str, str], list[Stream]]:
    found: dict[tuple[str, str], list[Stream]] = defaultdict(list)
    for directory in gen_matrix.image_directories():
        metadata = gen_matrix.parse_metadata(directory / "metadata.yaml")
        context = directory.relative_to(ROOT).as_posix()
        for flavor in metadata.flavors:
            version = metadata.versions[0]
            tag_version = version if flavor == "plain" else f"{version}-{flavor}"
            found[(metadata.name, tag_version)].append(
                Stream(metadata.name, tag_version, context, flavor, metadata.track, metadata.enabled)
            )
    return found


def safe_epoch(finding: dict[str, object], identity: RecipeIdentity) -> int | None:
    package = finding["package"]
    if not isinstance(package, dict):
        raise ClassificationError("finding.package must be an object")
    if package.get("name") != identity.name or package.get("type") != "apk":
        return None
    installed = scalar(package.get("installedVersion"), "finding.package.installedVersion")
    current = f"{identity.version}-r{identity.epoch}"
    if installed != current:
        return None
    fixed = finding.get("fixedVersions")
    if not isinstance(fixed, list) or not all(isinstance(item, str) and item for item in fixed):
        raise ClassificationError("finding.fixedVersions must be a non-empty string array")
    valid: set[int] = set()
    for value in fixed:
        match = APK_RELEASE.fullmatch(value)
        if match is not None and match.group("version") == identity.version:
            epoch = int(match.group("epoch"))
            if epoch > identity.epoch:
                valid.add(epoch)
    if len(valid) == 1:
        return valid.pop()
    return None


def validate_report(value: object) -> list[dict[str, object]]:
    if not isinstance(value, dict) or value.get("schemaVersion") != REPORT_SCHEMA:
        raise ClassificationError("monitor report schema is invalid")
    findings = value.get("findings")
    if not isinstance(findings, list):
        raise ClassificationError("monitor report findings must be an array")
    checked: list[dict[str, object]] = []
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            raise ClassificationError(f"finding[{index}] must be an object")
        scalar(finding.get("image"), f"finding[{index}].image")
        scalar(finding.get("version"), f"finding[{index}].version")
        scalar(finding.get("advisory"), f"finding[{index}].advisory")
        package = finding.get("package")
        if not isinstance(package, dict):
            raise ClassificationError(f"finding[{index}].package must be an object")
        scalar(package.get("name"), f"finding[{index}].package.name")
        scalar(package.get("installedVersion"), f"finding[{index}].package.installedVersion")
        fixed = finding.get("fixedVersions")
        if not isinstance(fixed, list) or not fixed or not all(isinstance(item, str) and item for item in fixed):
            raise ClassificationError(f"finding[{index}].fixedVersions must be a non-empty string array")
        checked.append(finding)
    return checked


def blocked(stream: str, finding: dict[str, object], reason: str) -> dict[str, str]:
    return {
        "stream": stream,
        "advisory": scalar(finding.get("advisory"), "finding.advisory"),
        "package": scalar((finding.get("package") or {}).get("name"), "finding.package.name"),
        "reason": reason,
    }


def classify(report: object) -> dict[str, object]:
    entries = streams()
    exact: dict[str, dict[str, object]] = {}
    apko: dict[str, set[str]] = defaultdict(set)
    revisions: dict[tuple[str, str], list[tuple[int, str]]] = defaultdict(list)
    blocked_findings: list[dict[str, str]] = []

    for finding in validate_report(report):
        image = scalar(finding.get("image"), "finding.image")
        version = scalar(finding.get("version"), "finding.version")
        target = f"{image}@{version}"
        candidates = entries.get((image, version), [])
        if len(candidates) != 1:
            reason = "unknown image stream" if not candidates else "ambiguous image stream"
            blocked_findings.append(blocked(target, finding, reason))
            continue
        stream = candidates[0]
        if not stream.enabled:
            blocked_findings.append(blocked(target, finding, "disabled image stream"))
            continue
        directory = ROOT / stream.context
        if stream.track == "patched":
            exact[target] = {"stream": target, "context": stream.context, "flavor": stream.flavor, "kind": "patched"}
            continue
        config, lockfile, recipe = gen_apko_lock_targets.build_inputs(directory, stream.flavor)
        if recipe.is_file():
            identity = recipe_identity(recipe)
            package = finding["package"]
            if isinstance(package, dict) and package.get("name") == identity.name:
                epoch = safe_epoch(finding, identity)
                if epoch is None:
                    blocked_findings.append(
                        blocked(target, finding, f"unsafe local package revision for {identity.name}")
                    )
                else:
                    revisions[(stream.context, recipe.relative_to(ROOT).as_posix())].append((epoch, target))
                continue
            exact[target] = {"stream": target, "context": stream.context, "flavor": stream.flavor, "kind": "recipe"}
            continue
        try:
            targets = gen_apko_lock_targets.lock_targets(directory)
        except gen_apko_lock_targets.LockDiscoveryError as error:
            blocked_findings.append(blocked(target, finding, f"unrefreshable pure APKO context: {error}"))
            continue
        if not config.is_file() or not lockfile.is_file() or stream.flavor not in {item["flavor"] for item in targets}:
            blocked_findings.append(blocked(target, finding, "pure APKO context has no committed lock for stream flavor"))
            continue
        apko[stream.context].add(target)

    proposals: list[dict[str, object]] = []
    for (context, recipe), values in sorted(revisions.items()):
        epochs = {epoch for epoch, _ in values}
        streams_for_recipe = sorted({stream for _, stream in values})
        if len(epochs) != 1:
            for stream in streams_for_recipe:
                blocked_findings.append({"stream": stream, "advisory": "multiple", "package": "local", "reason": "ambiguous local package revision epoch"})
            continue
        identity = recipe_identity(ROOT / recipe)
        proposals.append(
            {
                "context": context,
                "recipe": recipe,
                "package": identity.name,
                "version": identity.version,
                "fromEpoch": identity.epoch,
                "toEpoch": epochs.pop(),
                "streams": streams_for_recipe,
            }
        )

    unique_blocked = {
        (item["stream"], item["advisory"], item["package"], item["reason"]): item
        for item in blocked_findings
    }
    return {
        "schemaVersion": SCHEMA,
        "exact": [exact[target] for target in sorted(exact)],
        "apko": [
            {"context": context, "streams": sorted(targets)}
            for context, targets in sorted(apko.items())
        ],
        "localPackageRevisions": proposals,
        "blocked": [unique_blocked[key] for key in sorted(unique_blocked)],
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: classify_monitor_remediation.py IMAGE_DASHBOARD_JSON")
    try:
        document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        print(json.dumps(classify(document), separators=(",", ":"), sort_keys=True))
    except (OSError, json.JSONDecodeError, ClassificationError, gen_matrix.MetadataError) as error:
        raise SystemExit(f"monitor remediation classification refused: {error}") from error


if __name__ == "__main__":
    main()
