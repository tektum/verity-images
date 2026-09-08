#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_image_dashboard.py INPUT_DIRECTORY REPOSITORY RUN_ID RUN_ATTEMPT BODY_OUTPUT REPORT_OUTPUT

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Final
from urllib.parse import quote, quote_plus

SCHEMA: Final = "verity-image-dashboard-report/v1"
MARKER: Final = "<!-- verity-image-dashboard/v1 -->"
SHARDS: Final = 8
BODY_LIMIT: Final = 60 * 1024
PLATFORMS: Final = ("linux/amd64", "linux/arm64")
SEVERITIES: Final = ("critical", "high", "medium", "low", "negligible", "unknown")
SEVERITY_RANK: Final = {severity: rank for rank, severity in enumerate(SEVERITIES)}
DIGEST: Final = re.compile(r"sha256:[0-9a-f]{64}")
COMMIT: Final = re.compile(r"[0-9a-f]{40}")
REPOSITORY: Final = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


class DashboardError(ValueError):
    pass


def canonical(value: object) -> str:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def object_value(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise DashboardError(f"{label} must be an object")
    return value


def nonempty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise DashboardError(f"{label} must be a non-empty string")
    return value


def integer(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise DashboardError(f"{label} must be an integer")
    return value


def digest_value(value: object, label: str) -> str:
    text = nonempty_string(value, label)
    if DIGEST.fullmatch(text) is None:
        raise DashboardError(f"{label} must be an immutable sha256 digest")
    return text


def load_reports(root: Path) -> list[dict]:
    expected = {f"monitor-{shard}" for shard in range(SHARDS)}
    try:
        entries = {entry.name for entry in root.iterdir()}
    except OSError as error:
        raise DashboardError(f"cannot read input directory {root}: {error}") from error
    if entries != expected:
        missing = sorted(expected - entries)
        unexpected = sorted(entries - expected)
        raise DashboardError(
            f"input directory must contain exactly monitor-0 through monitor-7; "
            f"missing={missing}, unexpected={unexpected}"
        )

    reports: list[dict] = []
    for shard in range(SHARDS):
        directory = root / f"monitor-{shard}"
        if not directory.is_dir():
            raise DashboardError(f"monitor-{shard} is not a directory")
        files = tuple(directory.iterdir())
        if len(files) != 1 or files[0].name != "report.json" or not files[0].is_file():
            raise DashboardError(f"monitor-{shard} must contain exactly one report.json")
        try:
            document = json.loads(files[0].read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise DashboardError(f"invalid report {files[0]}: {error}") from error
        reports.append(object_value(document, f"monitor-{shard}/report.json"))
    return reports


def validate_catalog(value: object) -> dict:
    catalog = object_value(value, "catalog")
    for key in ("schemaVersion", "publishedAt", "source", "images", "sha256", "inventorySha256"):
        if key not in catalog:
            raise DashboardError(f"catalog.{key} is required")
    nonempty_string(catalog["publishedAt"], "catalog.publishedAt")
    images = integer(catalog["images"], "catalog.images")
    if images < 0:
        raise DashboardError("catalog.images must not be negative")
    source = object_value(catalog["source"], "catalog.source")
    commit = nonempty_string(source.get("commit"), "catalog.source.commit")
    if COMMIT.fullmatch(commit) is None:
        raise DashboardError("catalog.source.commit must be a 40-character commit")
    digest_value(catalog["sha256"], "catalog.sha256")
    digest_value(catalog["inventorySha256"], "catalog.inventorySha256")
    return catalog


def validate_grype(value: object) -> dict:
    grype = object_value(value, "grype")
    nonempty_string(grype.get("name"), "grype.name")
    nonempty_string(grype.get("version"), "grype.version")
    database = object_value(grype.get("db"), "grype.db")
    nonempty_string(database.get("built"), "grype.db.built")
    if "schemaVersion" not in database:
        raise DashboardError("grype.db.schemaVersion is required")
    schema_version = database["schemaVersion"]
    if not isinstance(schema_version, (str, int)) or isinstance(schema_version, bool):
        raise DashboardError("grype.db.schemaVersion must be a string or integer")
    nonempty_string(database.get("checksum"), "grype.db.checksum")
    return grype


def validate_subject(value: object, label: str) -> dict:
    subject = object_value(value, label)
    for key in ("name", "version", "track", "context", "reference"):
        nonempty_string(subject.get(key), f"{label}.{key}")
    digest = digest_value(subject.get("digest"), f"{label}.digest")
    digest_value(subject.get("inputDigest"), f"{label}.inputDigest")
    reference = str(subject["reference"])
    if not reference.endswith(f"@{digest}"):
        raise DashboardError(f"{label}.reference must be pinned to its digest")
    platforms = subject.get("platforms")
    if (
        not isinstance(platforms, list)
        or not all(isinstance(platform, str) for platform in platforms)
        or tuple(sorted(platforms)) != PLATFORMS
    ):
        raise DashboardError(
            f"{label}.platforms must contain linux/amd64 and linux/arm64 exactly once"
        )
    return subject


def validate_string_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise DashboardError(f"{label} must be a non-empty array")
    result: list[str] = []
    for index, item in enumerate(value):
        result.append(nonempty_string(item, f"{label}[{index}]"))
    return result


def validate_finding(value: object, label: str, subjects: dict[tuple[str, str], dict]) -> dict:
    finding = object_value(value, label)
    image = nonempty_string(finding.get("image"), f"{label}.image")
    version = nonempty_string(finding.get("version"), f"{label}.version")
    subject = subjects.get((image, version))
    if subject is None:
        raise DashboardError(f"{label} references unknown subject {image} {version}")

    for key in ("track", "context", "reference", "digest", "inputDigest"):
        if finding.get(key) != subject[key]:
            raise DashboardError(f"{label}.{key} does not match its subject")
    nonempty_string(finding.get("fingerprint"), f"{label}.fingerprint")
    nonempty_string(finding.get("advisory"), f"{label}.advisory")
    severity = finding.get("severity")
    if severity not in SEVERITIES:
        raise DashboardError(f"{label}.severity is invalid")
    package = object_value(finding.get("package"), f"{label}.package")
    nonempty_string(package.get("name"), f"{label}.package.name")
    for key in ("type", "purl", "installedVersion"):
        if not isinstance(package.get(key), str):
            raise DashboardError(f"{label}.package.{key} must be a string")
    validate_string_list(finding.get("fixedVersions"), f"{label}.fixedVersions")

    platforms = finding.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        raise DashboardError(f"{label}.platforms must be a non-empty array")
    seen: set[str] = set()
    for index, platform_value in enumerate(platforms):
        platform = object_value(platform_value, f"{label}.platforms[{index}]")
        name = nonempty_string(platform.get("platform"), f"{label}.platforms[{index}].platform")
        if name not in subject["platforms"]:
            raise DashboardError(f"{label}.platforms[{index}] is not covered by its subject")
        if name in seen:
            raise DashboardError(f"{label} repeats platform {name}")
        seen.add(name)
        validate_string_list(
            platform.get("fixedVersions"),
            f"{label}.platforms[{index}].fixedVersions",
        )
    return finding


def aggregate(reports: list[dict], repository: str, run_id: str, run_attempt: int) -> dict:
    shard_values: list[int] = []
    catalogs: list[dict] = []
    identities: list[dict] = []
    subject_values: list[object] = []
    finding_values: list[object] = []
    for index, report in enumerate(reports):
        shard = integer(report.get("shard"), f"report[{index}].shard")
        shard_values.append(shard)
        if integer(report.get("shards"), f"report[{index}].shards") != SHARDS:
            raise DashboardError(f"report[{index}].shards must equal {SHARDS}")
        catalogs.append(validate_catalog(report.get("catalog")))
        identities.append(validate_grype(report.get("grype")))
        object_value(report.get("totals"), f"report[{index}].totals")
        subjects = report.get("subjects")
        findings = report.get("findings")
        if not isinstance(subjects, list):
            raise DashboardError(f"report[{index}].subjects must be an array")
        if not isinstance(findings, list):
            raise DashboardError(f"report[{index}].findings must be an array")
        subject_values.extend(subjects)
        finding_values.extend(findings)

    if sorted(shard_values) != list(range(SHARDS)):
        raise DashboardError("report shard indices must be unique and exactly 0 through 7")
    if len({canonical(catalog) for catalog in catalogs}) != 1:
        raise DashboardError("monitor reports contain mixed catalogs")
    if len({canonical(identity) for identity in identities}) != 1:
        raise DashboardError("monitor reports contain mixed Grype identities")

    subjects: dict[tuple[str, str], dict] = {}
    for index, value in enumerate(subject_values):
        subject = validate_subject(value, f"subject[{index}]")
        key = (subject["name"], subject["version"])
        if key in subjects:
            raise DashboardError(f"duplicate subject identity {key[0]} {key[1]}")
        subjects[key] = subject
    catalog = catalogs[0]
    if len(subjects) != catalog["images"]:
        raise DashboardError(
            f"subject count {len(subjects)} does not match catalog.images {catalog['images']}"
        )

    findings: list[dict] = []
    fingerprints: set[str] = set()
    for index, value in enumerate(finding_values):
        finding = validate_finding(value, f"finding[{index}]", subjects)
        fingerprint = finding["fingerprint"]
        if fingerprint in fingerprints:
            raise DashboardError(f"duplicate finding fingerprint {fingerprint}")
        fingerprints.add(fingerprint)
        findings.append(finding)

    ordered_subjects = sorted(subjects.values(), key=lambda item: (item["name"], item["version"]))
    ordered_findings = sorted(
        findings,
        key=lambda item: (
            item["image"],
            item["version"],
            SEVERITY_RANK[item["severity"]],
            item["package"]["name"],
            item["advisory"],
            item["fingerprint"],
        ),
    )
    severity_counts = {severity: 0 for severity in SEVERITIES}
    for finding in ordered_findings:
        severity_counts[finding["severity"]] += 1
    affected = {(finding["image"], finding["version"]) for finding in ordered_findings}
    run_url = f"https://github.com/{repository}/actions/runs/{run_id}"
    return {
        "schemaVersion": SCHEMA,
        "repository": repository,
        "runId": run_id,
        "runAttempt": run_attempt,
        "runUrl": run_url,
        "shards": SHARDS,
        "catalog": catalog,
        "grype": identities[0],
        "totals": {
            "subjects": len(ordered_subjects),
            "platforms": sum(len(subject["platforms"]) for subject in ordered_subjects),
            "affectedSubjects": len(affected),
            "findings": len(ordered_findings),
            "severities": severity_counts,
        },
        "subjects": ordered_subjects,
        "findings": ordered_findings,
    }


def markdown(value: object) -> str:
    text = str(value)
    return (
        text.replace("\\", "\\\\")
        .replace("|", "\\|")
        .replace("[", "\\[")
        .replace("]", "\\]")
        .replace("`", "\\`")
        .replace("\r\n", "<br>")
        .replace("\r", "<br>")
        .replace("\n", "<br>")
    )


def definition_url(repository: str, commit: str, context: str) -> str:
    return f"https://github.com/{repository}/tree/{commit}/{quote(context, safe='/')}"


def evidence_url(repository: str, context: str) -> str:
    query = quote_plus(f"is:open tool:Grype path:{context}/metadata.yaml", safe="")
    return f"https://github.com/{repository}/security/code-scanning?query={query}"


def dashboard_row(
    repository: str,
    commit: str,
    subject: dict,
    findings: list[dict],
) -> tuple[tuple[object, ...], str]:
    counts = {severity: 0 for severity in SEVERITIES}
    packages: set[str] = set()
    for finding in findings:
        counts[finding["severity"]] += 1
        packages.add(finding["package"]["name"])
    ordered_packages = sorted(packages)
    visible = ", ".join(markdown(package) for package in ordered_packages[:6])
    if len(ordered_packages) > 6:
        visible += f", +{len(ordered_packages) - 6} more"
    context = subject["context"]
    cells = (
        f"{markdown(subject['name'])} {markdown(subject['version'])}",
        f"[{markdown(context)}]({definition_url(repository, commit, context)})",
        f"`{subject['digest'][7:19]}`",
        "/".join(str(counts[severity]) for severity in SEVERITIES),
        visible,
        f"[alerts]({evidence_url(repository, context)})",
    )
    rank = min(SEVERITY_RANK[finding["severity"]] for finding in findings)
    key = (rank, -len(findings), subject["name"], subject["version"])
    return key, "| " + " | ".join(cells) + " |"


def render_body(report: dict) -> str:
    catalog = report["catalog"]
    source = catalog["source"]
    grype = report["grype"]
    database = grype["db"]
    totals = report["totals"]
    severity_counts = totals["severities"]
    lines = [
        MARKER,
        "# Image Dashboard",
        "",
        "Generated view. Editing this issue does not request remediation. Discuss decisions in comments or linked pull requests.",
        "",
        "## Coverage",
        "",
        f"- Run: [{markdown(report['runId'])}]({report['runUrl']}), attempt {report['runAttempt']}",
        (
            f"- Catalog: published {markdown(catalog['publishedAt'])}, source commit "
            f"`{markdown(source['commit'])}`, hash `{markdown(catalog['sha256'])}`, inventory hash "
            f"`{markdown(catalog['inventorySha256'])}`"
        ),
        (
            f"- Coverage: {report['shards']}/{SHARDS} shards, {totals['subjects']} image streams, "
            f"{totals['platforms']} platforms"
        ),
        (
            f"- Grype: version {markdown(grype['version'])}, database built "
            f"{markdown(database['built'])}, schema {markdown(database['schemaVersion'])}, "
            f"checksum `{markdown(database['checksum'])}`"
        ),
        "",
        "## Summary",
        "",
        f"- Affected image streams: {totals['affectedSubjects']}",
        (
            f"- Fixable findings: {totals['findings']} "
            f"(critical {severity_counts['critical']}, high {severity_counts['high']}, "
            f"medium {severity_counts['medium']}, low {severity_counts['low']}, "
            f"negligible {severity_counts['negligible']}, unknown {severity_counts['unknown']})"
        ),
    ]
    if totals["findings"] == 0:
        lines.extend(
            [
                "",
                "No published images have findings with a currently published fix as of this complete scan.",
            ]
        )

    findings_by_subject: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for finding in report["findings"]:
        findings_by_subject[(finding["image"], finding["version"])].append(finding)
    subjects = {
        (subject["name"], subject["version"]): subject for subject in report["subjects"]
    }
    rows = sorted(
        (
            dashboard_row(
                report["repository"],
                source["commit"],
                subjects[key],
                findings,
            )
            for key, findings in findings_by_subject.items()
        ),
        key=lambda item: item[0],
    )
    table_rows = [row for _, row in rows]
    table_prefix: list[str] = []
    if table_rows:
        table_prefix = [
            "",
            "## Needs work",
            "",
            "| Image stream | Definition | Digest | C/H/M/L/N/U | Packages | Evidence |",
            "| --- | --- | --- | ---: | --- | --- |",
        ]

    policy = [
        "",
        "## Policy",
        "",
        "A package fix is a remediation candidate, not proof that unchanged inputs can apply it. Rows reflect findings with published fixes in the latest complete scan; database updates can remove rows without a new image publication. Findings without published fixes remain in scan artifacts.",
        "",
    ]
    complete = "\n".join(lines + table_prefix + table_rows + policy)
    if len(complete.encode("utf-8")) <= BODY_LIMIT:
        return complete

    rendered: list[str] = []
    total = len(table_rows)
    for row in table_rows:
        candidate_rows = rendered + [row]
        notice = (
            f"Showing {len(candidate_rows)} of {total} affected image streams. "
            "Full machine-readable results are in the linked workflow artifacts."
        )
        candidate = "\n".join(lines + table_prefix + candidate_rows + ["", notice] + policy)
        if len(candidate.encode("utf-8")) > BODY_LIMIT:
            break
        rendered = candidate_rows
    notice = (
        f"Showing {len(rendered)} of {total} affected image streams. "
        "Full machine-readable results are in the linked workflow artifacts."
    )
    truncated = "\n".join(lines + table_prefix + rendered + ["", notice] + policy)
    if len(truncated.encode("utf-8")) > BODY_LIMIT:
        raise DashboardError("dashboard body metadata exceeds the 60 KiB limit")
    return truncated


def build(arguments: list[str]) -> tuple[Path, str, Path, str]:
    if len(arguments) != 6:
        raise DashboardError(
            "usage: build_image_dashboard.py INPUT_DIRECTORY REPOSITORY RUN_ID RUN_ATTEMPT BODY_OUTPUT REPORT_OUTPUT"
        )
    input_directory, repository, run_id, run_attempt_text, body_output, report_output = arguments
    if REPOSITORY.fullmatch(repository) is None:
        raise DashboardError("repository must be in owner/name form")
    if not run_id.isdecimal() or int(run_id) < 1:
        raise DashboardError("run ID must be a positive integer")
    if not run_attempt_text.isdecimal() or int(run_attempt_text) < 1:
        raise DashboardError("run attempt must be a positive integer")
    reports = load_reports(Path(input_directory))
    report = aggregate(reports, repository, run_id, int(run_attempt_text))
    body = render_body(report)
    report_text = canonical(report) + "\n"
    return Path(body_output), body, Path(report_output), report_text


def main() -> None:
    try:
        body_path, body, report_path, report = build(sys.argv[1:])
    except (DashboardError, OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"image dashboard: {error}") from error
    _ = body_path.write_text(body, encoding="utf-8")
    _ = report_path.write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
