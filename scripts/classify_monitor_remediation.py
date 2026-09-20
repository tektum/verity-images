#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Classify validated monitor findings into safe remediation controllers."""

from __future__ import annotations

import http.client
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zlib
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Final

import gen_apko_lock_targets
import gen_matrix

ROOT: Final = gen_matrix.ROOT
SCHEMA: Final = "verity-monitor-remediation-plan/v1"
REPORT_SCHEMA: Final = "verity-image-dashboard-report/v1"
APK_RELEASE: Final = re.compile(r"(?P<version>.+)-r(?P<epoch>[0-9]+)$")
WOLFI_REPOSITORY: Final = "https://packages.wolfi.dev/os"
WOLFI_KEY: Final = f"{WOLFI_REPOSITORY}/wolfi-signing.rsa.pub"
APK_ARCHITECTURES: Final = ("aarch64", "x86_64")
MAX_INDEX_DOWNLOAD: Final = 64 * 1024 * 1024
MAX_INDEX_CONTENTS: Final = 64 * 1024 * 1024
MAX_KEY_DOWNLOAD: Final = 16 * 1024
NETWORK_TIMEOUT: Final = 30
VERIFY_TIMEOUT: Final = 10


type Fetch = Callable[[str, int], bytes]


class ClassificationError(ValueError):
    pass


class RepositoryError(ValueError):
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


@dataclass(frozen=True, slots=True)
class WolfiFinding:
    finding: dict[str, object]
    stream: Stream
    config: Path
    lockfile: Path
    recipe: Path
    fixed_versions: tuple[str, ...]


def scalar(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ClassificationError(f"{label} must be a non-empty string")
    return value

def fetch_url(url: str, limit: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "verity-monitor-remediation/1"})
    try:
        with urllib.request.urlopen(request, timeout=NETWORK_TIMEOUT) as response:
            if response.status != 200 or not response.geturl().startswith("https://"):
                raise RepositoryError("Wolfi repository request was not a successful HTTPS response")
            data = response.read(limit + 1)
    except (OSError, TimeoutError, urllib.error.URLError, http.client.HTTPException) as error:
        raise RepositoryError("Wolfi repository request failed") from error
    if not data or len(data) > limit:
        raise RepositoryError("Wolfi repository response has an invalid size")
    return data


def configured_values(path: Path, field: str) -> tuple[str, ...]:
    marker = f"  {field}:"
    values: list[str] = []
    active = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw == marker:
            if active:
                raise RepositoryError(f"{path}: duplicate contents.{field}")
            active = True
            continue
        if not active:
            continue
        if raw.startswith("    - "):
            value = raw[6:].strip().strip("\"'")
            if not value:
                raise RepositoryError(f"{path}: empty contents.{field} entry")
            values.append(value)
            continue
        if raw.strip() and not raw.lstrip().startswith("#"):
            break
    if not values or len(values) != len(set(values)):
        raise RepositoryError(f"{path}: contents.{field} must be a non-empty unique list")
    return tuple(values)


def require_wolfi_repository(path: Path) -> None:
    if WOLFI_REPOSITORY not in configured_values(path, "repositories"):
        raise RepositoryError(f"{path}: configured repositories do not include Wolfi")
    if WOLFI_KEY not in configured_values(path, "keyring"):
        raise RepositoryError(f"{path}: configured keyring does not include the Wolfi signing key")


def gzip_member(data: bytes, limit: int) -> tuple[bytes, bytes, bytes]:
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        plain = inflater.decompress(data, limit + 1)
        if inflater.unconsumed_tail:
            raise RepositoryError("Wolfi repository index member is oversized")
        plain += inflater.flush()
    except zlib.error as error:
        raise RepositoryError("Wolfi repository index has invalid gzip data") from error
    consumed = len(data) - len(inflater.unused_data)
    if not inflater.eof or consumed == 0 or len(plain) > limit:
        raise RepositoryError("Wolfi repository index has an invalid gzip member")
    return data[:consumed], plain, inflater.unused_data


def archive_files(raw: bytes, expected: set[str]) -> dict[str, bytes]:
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            members = archive.getmembers()
            if {member.name for member in members} != expected or any(not member.isfile() for member in members):
                raise RepositoryError("Wolfi repository index has unexpected archive entries")
            files: dict[str, bytes] = {}
            for member in members:
                source = archive.extractfile(member)
                if source is None or member.size > MAX_INDEX_CONTENTS:
                    raise RepositoryError("Wolfi repository index has an invalid archive entry")
                files[member.name] = source.read()
            return files
    except (OSError, tarfile.TarError) as error:
        raise RepositoryError("Wolfi repository index has an invalid tar archive") from error


def index_packages(raw: bytes, architecture: str, required: set[tuple[str, str]]) -> set[tuple[str, str]]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RepositoryError("Wolfi repository APKINDEX is not UTF-8") from error
    found: set[tuple[str, str]] = set()
    paragraphs = text.strip().split("\n\n")
    if not text.strip():
        raise RepositoryError("Wolfi repository APKINDEX is empty")
    for paragraph in paragraphs:
        values: dict[str, str] = {}
        for line in paragraph.splitlines():
            key, separator, value = line.partition(":")
            if not separator or not key or key in values:
                raise RepositoryError("Wolfi repository APKINDEX has a malformed record")
            values[key] = value
        if not {"P", "V", "A", "C", "S"} <= values.keys() or values["A"] != architecture:
            raise RepositoryError("Wolfi repository APKINDEX has an invalid record")
        try:
            size = int(values["S"])
        except ValueError as error:
            raise RepositoryError("Wolfi repository APKINDEX has an invalid package size") from error
        if size < 0:
            raise RepositoryError("Wolfi repository APKINDEX has an invalid package size")
        package = (values["P"], values["V"])
        if package in required:
            found.add(package)
    return found


def signed_index_packages(
    data: bytes,
    key: bytes,
    architecture: str,
    required: set[tuple[str, str]],
) -> set[tuple[str, str]]:
    _, signature_tar, remaining = gzip_member(data, MAX_INDEX_CONTENTS)
    index_member, index_tar, trailing = gzip_member(remaining, MAX_INDEX_CONTENTS)
    if trailing:
        raise RepositoryError("Wolfi repository index has unexpected trailing data")
    signature_name = f".SIGN.RSA256.{WOLFI_KEY.rsplit('/', maxsplit=1)[1]}"
    signature = archive_files(signature_tar, {signature_name})[signature_name]
    files = archive_files(index_tar, {"APKINDEX", "DESCRIPTION"})
    if not key.startswith(b"-----BEGIN PUBLIC KEY-----\n") or not key.rstrip().endswith(b"-----END PUBLIC KEY-----"):
        raise RepositoryError("Wolfi repository signing key is malformed")
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        key_path = directory / "wolfi-signing.rsa.pub"
        signature_path = directory / "APKINDEX.signature"
        key_path.write_bytes(key)
        signature_path.write_bytes(signature)
        try:
            verified = subprocess.run(
                [
                    "openssl",
                    "dgst",
                    "-sha256",
                    "-verify",
                    str(key_path),
                    "-signature",
                    str(signature_path),
                ],
                input=index_member,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=VERIFY_TIMEOUT,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RepositoryError("Wolfi repository signature verification failed") from error
    if verified.returncode != 0:
        raise RepositoryError("Wolfi repository signature verification failed")
    return index_packages(files["APKINDEX"], architecture, required)


def query_wolfi_repository(
    requirements: set[tuple[str, str]],
    *,
    fetch: Fetch = fetch_url,
) -> dict[tuple[str, str], tuple[str, ...]]:
    key = fetch(WOLFI_KEY, MAX_KEY_DOWNLOAD)
    available = {requirement: set() for requirement in requirements}
    for architecture in APK_ARCHITECTURES:
        index = fetch(f"{WOLFI_REPOSITORY}/{architecture}/APKINDEX.tar.gz", MAX_INDEX_DOWNLOAD)
        for requirement in signed_index_packages(index, key, architecture, requirements):
            available[requirement].add(architecture)
    return {
        requirement: tuple(architecture for architecture in APK_ARCHITECTURES if architecture not in found)
        for requirement, found in available.items()
    }


def fixed_versions(finding: dict[str, object]) -> tuple[str, ...]:
    values = finding.get("fixedVersions")
    if not isinstance(values, list) or not values or not all(isinstance(value, str) and value for value in values):
        raise ClassificationError("finding.fixedVersions must be a non-empty string array")
    return tuple(sorted(set(values)))




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


def uses_pipeline(path: Path, pipeline: str) -> bool:
    """Whether one exact Melange recipe invokes the named shared pipeline."""
    marker = f"- uses: {pipeline}"
    return path.is_file() and any(
        line.strip() == marker for line in path.read_text(encoding="utf-8").splitlines()
    )


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


def safe_epoch(
    finding: dict[str, object],
    identity: RecipeIdentity,
    available_versions: set[str],
) -> int | None:
    package = finding["package"]
    if not isinstance(package, dict):
        raise ClassificationError("finding.package must be an object")
    if package.get("name") != identity.name or package.get("type") != "apk":
        return None
    installed = scalar(package.get("installedVersion"), "finding.package.installedVersion")
    current = f"{identity.version}-r{identity.epoch}"
    if installed != current:
        return None
    valid: set[int] = set()
    for value in available_versions:
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


def blocked(stream: str, finding: dict[str, object], reason: str) -> dict[str, object]:
    return {
        "stream": stream,
        "advisory": scalar(finding.get("advisory"), "finding.advisory"),
        "package": scalar((finding.get("package") or {}).get("name"), "finding.package.name"),
        "reason": reason,
    }


def unavailable(
    candidate: WolfiFinding,
    version: str,
    missing: tuple[str, ...],
    reason: str = "fixed Wolfi package version is not published for every required architecture",
) -> dict[str, object]:
    result = blocked(candidate.stream.target, candidate.finding, reason)
    result["requiredFixedVersion"] = version
    result["missingArchitectures"] = list(missing)
    return result


def classify(
    report: object,
    repository_query: Callable[
        [set[tuple[str, str]]], dict[tuple[str, str], tuple[str, ...]]
    ]
    | None = None,
) -> dict[str, object]:
    entries = streams()
    exact: dict[str, dict[str, object]] = {}
    apko: dict[str, set[str]] = defaultdict(set)
    revisions: dict[tuple[str, str], list[tuple[int, str]]] = defaultdict(list)
    blocked_findings: list[dict[str, object]] = []
    invalid_groups: set[tuple[str, str]] = set()
    wolfi_by_group: dict[tuple[str, str], list[WolfiFinding]] = defaultdict(list)
    recipe_exact: dict[tuple[str, str], list[tuple[dict[str, object], Stream]]] = defaultdict(list)
    blocked_candidate_ids: set[int] = set()

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
            exact[target] = {
                "stream": target,
                "context": stream.context,
                "flavor": stream.flavor,
                "kind": "patched",
            }
            continue
        package = finding["package"]
        if not isinstance(package, dict):
            raise ClassificationError("finding.package must be an object")
        config, lockfile, recipe = gen_apko_lock_targets.build_inputs(directory, stream.flavor)
        group = (
            ("recipe", recipe.relative_to(ROOT).as_posix())
            if recipe.is_file()
            else ("apko", stream.context)
        )
        if package.get("type") == "go-module" and uses_pipeline(recipe, "go/remediate"):
            recipe_exact[group].append((finding, stream))
            continue
        if package.get("type") != "apk":
            blocked_findings.append(blocked(target, finding, "unsupported package type for Wolfi remediation"))
            invalid_groups.add(group)
            continue
        try:
            require_wolfi_repository(config)
        except (OSError, UnicodeDecodeError, RepositoryError) as error:
            blocked_findings.append(blocked(target, finding, f"unqueryable Wolfi repository configuration: {error}"))
            invalid_groups.add(group)
            continue
        wolfi_by_group[group].append(
            WolfiFinding(finding, stream, config, lockfile, recipe, fixed_versions(finding))
        )

    candidates = [
        candidate
        for group, group_findings in wolfi_by_group.items()
        if group not in invalid_groups
        for candidate in group_findings
    ]
    requirements = {
        (scalar(candidate.finding["package"].get("name"), "finding.package.name"), version)
        for candidate in candidates
        for version in candidate.fixed_versions
        if isinstance(candidate.finding["package"], dict)
    }
    availability: dict[tuple[str, str], tuple[str, ...]] = {}
    if requirements:
        try:
            availability = (repository_query or query_wolfi_repository)(requirements)
            if set(availability) != requirements or any(
                not isinstance(missing, tuple)
                or any(architecture not in APK_ARCHITECTURES for architecture in missing)
                or tuple(sorted(set(missing))) != missing
                for missing in availability.values()
            ):
                raise RepositoryError("Wolfi repository availability result is malformed")
        except RepositoryError:
            for candidate in candidates:
                blocked_findings.append(
                    unavailable(
                        candidate,
                        candidate.fixed_versions[0],
                        APK_ARCHITECTURES,
                        "Wolfi repository availability check failed",
                    )
                )
                blocked_candidate_ids.add(id(candidate))
                group = (
                    ("recipe", candidate.recipe.relative_to(ROOT).as_posix())
                    if candidate.recipe.is_file()
                    else ("apko", candidate.stream.context)
                )
                invalid_groups.add(group)

    available_by_candidate: dict[int, set[str]] = {}
    if availability:
        for candidate in candidates:
            package = candidate.finding["package"]
            if not isinstance(package, dict):
                raise ClassificationError("finding.package must be an object")
            name = scalar(package.get("name"), "finding.package.name")
            available = {
                version
                for version in candidate.fixed_versions
                if not availability.get((name, version), APK_ARCHITECTURES)
            }
            if available:
                available_by_candidate[id(candidate)] = available
                continue
            required = min(
                candidate.fixed_versions,
                key=lambda version: (len(availability.get((name, version), APK_ARCHITECTURES)), version),
            )
            blocked_findings.append(
                unavailable(candidate, required, availability.get((name, required), APK_ARCHITECTURES))
            )
            blocked_candidate_ids.add(id(candidate))
            group = (
                ("recipe", candidate.recipe.relative_to(ROOT).as_posix())
                if candidate.recipe.is_file()
                else ("apko", candidate.stream.context)
            )
            invalid_groups.add(group)

    groups = sorted(set(wolfi_by_group) | set(recipe_exact))
    for group in groups:
        group_findings = wolfi_by_group.get(group, [])
        exact_findings = recipe_exact.get(group, [])
        if group in invalid_groups:
            for candidate in group_findings:
                if id(candidate) not in blocked_candidate_ids:
                    blocked_findings.append(
                        blocked(
                            candidate.stream.target,
                            candidate.finding,
                            "remediation suppressed by another blocked finding in build input group",
                        )
                    )
            for finding, stream in exact_findings:
                blocked_findings.append(
                    blocked(
                        stream.target,
                        finding,
                        "remediation suppressed by another blocked finding in build input group",
                    )
                )
            continue
        context = (group_findings[0].stream if group_findings else exact_findings[0][1]).context
        context_exact: dict[str, dict[str, object]] = {}
        context_apko: set[str] = set()
        context_revisions: dict[tuple[str, str], list[tuple[int, str]]] = defaultdict(list)
        context_blocked: list[dict[str, object]] = []
        context_blocked_ids: set[int] = set()
        target_cache: dict[str, list[gen_apko_lock_targets.LockTarget]] = {}
        for candidate in group_findings:
            finding = candidate.finding
            stream = candidate.stream
            target = stream.target
            if candidate.recipe.is_file():
                identity = recipe_identity(candidate.recipe)
                package = finding["package"]
                if isinstance(package, dict) and package.get("name") == identity.name:
                    epoch = safe_epoch(finding, identity, available_by_candidate[id(candidate)])
                    if epoch is None:
                        context_blocked.append(
                            blocked(target, finding, f"unsafe local package revision for {identity.name}")
                        )
                        context_blocked_ids.add(id(candidate))
                    else:
                        recipe = candidate.recipe.relative_to(ROOT).as_posix()
                        context_revisions[(context, recipe)].append((epoch, target))
                    continue
                context_exact[target] = {
                    "stream": target,
                    "context": context,
                    "flavor": stream.flavor,
                    "kind": "recipe",
                }
                continue
            try:
                if stream.flavor not in target_cache:
                    target_cache[stream.flavor] = gen_apko_lock_targets.lock_targets(ROOT / context)
                targets = target_cache[stream.flavor]
            except gen_apko_lock_targets.LockDiscoveryError as error:
                context_blocked.append(blocked(target, finding, f"unrefreshable pure APKO context: {error}"))
                context_blocked_ids.add(id(candidate))
                continue
            if (
                not candidate.config.is_file()
                or not candidate.lockfile.is_file()
                or stream.flavor not in {item["flavor"] for item in targets}
            ):
                context_blocked.append(
                    blocked(target, finding, "pure APKO context has no committed lock for stream flavor")
                )
                context_blocked_ids.add(id(candidate))
                continue
            context_apko.add(target)

        for (_, recipe), values in sorted(context_revisions.items()):
            epochs = {epoch for epoch, _ in values}
            if len(epochs) == 1:
                continue
            for stream in sorted({stream for _, stream in values}):
                context_blocked.append(
                    {
                        "stream": stream,
                        "advisory": "multiple",
                        "package": "local",
                        "reason": "ambiguous local package revision epoch",
                    }
                )
                context_blocked_ids.update(
                    id(candidate)
                    for candidate in group_findings
                    if candidate.stream.target == stream
                    and candidate.recipe.relative_to(ROOT).as_posix() == recipe
                )
        if context_blocked:
            for candidate in group_findings:
                if id(candidate) not in context_blocked_ids:
                    context_blocked.append(
                        blocked(
                            candidate.stream.target,
                            candidate.finding,
                            "remediation suppressed by another blocked finding in build input group",
                        )
                    )
            for finding, stream in exact_findings:
                context_blocked.append(
                    blocked(
                        stream.target,
                        finding,
                        "remediation suppressed by another blocked finding in build input group",
                    )
                )
            blocked_findings.extend(context_blocked)
            continue
        revision_targets = {
            target for values in context_revisions.values() for _, target in values
        }
        for finding, stream in exact_findings:
            if stream.target not in revision_targets:
                context_exact[stream.target] = {
                    "stream": stream.target,
                    "context": stream.context,
                    "flavor": stream.flavor,
                    "kind": "recipe",
                }
        for target in revision_targets:
            context_exact.pop(target, None)
        exact.update(context_exact)
        apko[context].update(context_apko)
        for key, values in context_revisions.items():
            revisions[key].extend(values)

    proposals: list[dict[str, object]] = []
    for (context, recipe), values in sorted(revisions.items()):
        epochs = {epoch for epoch, _ in values}
        identity = recipe_identity(ROOT / recipe)
        proposals.append(
            {
                "context": context,
                "recipe": recipe,
                "package": identity.name,
                "version": identity.version,
                "fromEpoch": identity.epoch,
                "toEpoch": epochs.pop(),
                "streams": sorted({stream for _, stream in values}),
            }
        )

    unique_blocked = {
        (
            str(item["stream"]),
            str(item["advisory"]),
            str(item["package"]),
            str(item["reason"]),
            str(item.get("requiredFixedVersion", "")),
            tuple(item.get("missingArchitectures", [])),
        ): item
        for item in blocked_findings
    }
    return {
        "schemaVersion": SCHEMA,
        "exact": [exact[target] for target in sorted(exact)],
        "apko": [
            {"context": context, "streams": sorted(targets)}
            for context, targets in sorted(apko.items())
            if targets
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
