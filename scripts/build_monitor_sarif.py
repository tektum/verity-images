#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_monitor_sarif.py MANIFEST SARIF REPORT
#
# Turns the Grype reports of one monitor shard into a SARIF run and a machine
# readable report. Only findings with a published fix become code scanning
# results: that is the same rule the publication gate applies, so every alert
# is a rebuild that is available now. Unfixed findings stay in the report.

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Final

SARIF_SCHEMA: Final = (
    "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/"
    "schema/sarif-schema-2.1.0.json"
)
SEVERITIES: Final = ("critical", "high", "medium", "low", "negligible", "unknown")
LEVELS: Final = {
    "critical": "error",
    "high": "error",
    "medium": "warning",
    "low": "note",
    "negligible": "note",
    "unknown": "warning",
}
PROBLEM_SEVERITIES: Final = {
    "error": "error",
    "warning": "warning",
    "note": "recommendation",
}
FINGERPRINT: Final = "verityMonitorFinding/v1"
DESCRIPTION_LIMIT: Final = 1000


def severity_of(match: dict) -> str:
    severity = str(match["vulnerability"].get("severity") or "").lower()
    if severity in SEVERITIES and severity != "unknown":
        return severity
    for related in match.get("relatedVulnerabilities") or []:
        candidate = str(related.get("severity") or "").lower()
        if candidate in SEVERITIES and candidate != "unknown":
            return candidate
    return severity if severity in SEVERITIES else "unknown"


def fixed_versions(match: dict) -> list[str]:
    # Parity with scripts/evaluate_scan_gate.sh: a named fix version is what
    # makes a finding actionable, whatever state Grype reports alongside it.
    fix = match["vulnerability"].get("fix") or {}
    return sorted({str(version) for version in fix.get("versions") or [] if version})


def cvss_score(match: dict) -> float | None:
    entries = list(match["vulnerability"].get("cvss") or [])
    for related in match.get("relatedVulnerabilities") or []:
        entries.extend(related.get("cvss") or [])
    best: float | None = None
    for entry in entries:
        version = str(entry.get("version") or "")
        if not version.startswith(("3", "4")):
            continue
        score = (entry.get("metrics") or {}).get("baseScore")
        if isinstance(score, (int, float)) and (best is None or float(score) > best):
            best = float(score)
    return best


def description_of(match: dict) -> str:
    description = str(match["vulnerability"].get("description") or "")
    if not description:
        for related in match.get("relatedVulnerabilities") or []:
            description = str(related.get("description") or "")
            if description:
                break
    collapsed = " ".join(description.split())
    if len(collapsed) > DESCRIPTION_LIMIT:
        return collapsed[: DESCRIPTION_LIMIT - 3] + "..."
    return collapsed


def advisory_url(match: dict) -> str:
    source = str(match["vulnerability"].get("dataSource") or "")
    if source.startswith("https://"):
        return source
    for url in match["vulnerability"].get("urls") or []:
        if str(url).startswith("https://"):
            return str(url)
    return ""


def database_identity(document: dict) -> dict[str, object]:
    descriptor = document.get("descriptor") or {}
    database = descriptor.get("db") or {}
    return {
        "name": descriptor.get("name"),
        "version": descriptor.get("version"),
        "db": {
            key: database[key]
            for key in ("built", "schemaVersion", "checksum")
            if key in database
        },
    }


def empty_counts() -> dict[str, int]:
    return {severity: 0 for severity in SEVERITIES}


def add_counts(into: dict[str, int], other: dict[str, object]) -> None:
    for severity, count in other.items():
        key = str(severity).lower()
        if key in into and isinstance(count, int):
            into[key] += count


class Finding:
    def __init__(self, subject: dict, match: dict) -> None:
        artifact = match["artifact"]
        self.subject = subject
        self.advisory = str(match["vulnerability"]["id"])
        self.package = str(artifact["name"])
        self.installed = str(artifact.get("version") or "")
        self.kind = str(artifact.get("type") or "")
        self.purl = str(artifact.get("purl") or "")
        self.severity = severity_of(match)
        self.fixed: set[str] = set(fixed_versions(match))
        self.platforms: set[str] = set()

    @property
    def key(self) -> tuple[str, str, str, str, str, str]:
        return (
            self.subject["name"],
            self.subject["version"],
            self.advisory,
            self.kind,
            self.package,
            self.installed,
        )

    def fingerprint(self) -> str:
        stream = "|".join(self.key)
        return hashlib.sha256(stream.encode("utf-8")).hexdigest()

    def result(self) -> dict[str, object]:
        platforms = ", ".join(sorted(self.platforms))
        fixes = ", ".join(sorted(self.fixed))
        subject = self.subject
        message = (
            f"{self.package} {self.installed} in {subject['reference']} "
            f"({platforms}) is affected by {self.advisory}, fixed in {fixes}. "
            f"Rebuild {subject['name']} {subject['version']} to ship the fix."
        )
        return {
            "ruleId": self.advisory,
            "level": LEVELS[self.severity],
            "message": {"text": message},
            "locations": [
                {
                    "physicalLocation": {
                        "artifactLocation": {"uri": f"{subject['context']}/metadata.yaml"},
                        "region": {"startLine": 1},
                    }
                }
            ],
            "partialFingerprints": {FINGERPRINT: self.fingerprint()},
            "properties": {
                "image": subject["name"],
                "imageVersion": subject["version"],
                "track": subject["track"],
                "reference": subject["reference"],
                "platforms": sorted(self.platforms),
                "package": self.package,
                "packageType": self.kind,
                "purl": self.purl,
                "installedVersion": self.installed,
                "fixedVersions": sorted(self.fixed),
                "severity": self.severity,
            },
        }


def rule_of(advisory: str, severity: str, description: str, url: str,
            score: float | None) -> dict[str, object]:
    level = LEVELS[severity]
    text = description or f"{advisory} has no published description."
    help_text = f"{text} Rebuild every affected image against current packages."
    properties: dict[str, object] = {
        "tags": ["security", "vulnerability", f"severity/{severity}"],
        "problem": {"severity": PROBLEM_SEVERITIES[level]},
    }
    if score is not None:
        properties["security-severity"] = f"{score:.1f}"
    rule: dict[str, object] = {
        "id": advisory,
        "name": advisory,
        "shortDescription": {"text": f"{advisory} affects a published package"},
        "fullDescription": {"text": text},
        "help": {"text": help_text, "markdown": help_text},
        "properties": properties,
    }
    if url:
        rule["helpUri"] = url
    return rule


def collect(manifest: dict, root: Path) -> tuple[list[Finding], dict, dict, list[dict]]:
    findings: dict[tuple[str, ...], Finding] = {}
    rules: dict[str, dict[str, object]] = {}
    identities: list[dict[str, object]] = []
    reported: list[dict[str, object]] = []
    for subject in manifest["subjects"]:
        monitored = empty_counts()
        fixable = 0
        for entry in subject["platforms"]:
            document = json.loads((root / entry["scan"]).read_text(encoding="utf-8"))
            identity = database_identity(document)
            if identity not in identities:
                identities.append(identity)
            for match in document.get("matches") or []:
                finding = Finding(subject, match)
                monitored[finding.severity] += 1
                if not finding.fixed:
                    continue
                fixable += 1
                existing = findings.get(finding.key)
                if existing is None:
                    findings[finding.key] = finding
                    existing = finding
                else:
                    existing.fixed |= finding.fixed
                existing.platforms.add(entry["platform"])
                score = cvss_score(match)
                rule = rules.get(finding.advisory)
                if rule is None or (
                    "security-severity" not in rule["properties"] and score is not None
                ):
                    rules[finding.advisory] = rule_of(
                        finding.advisory,
                        finding.severity,
                        description_of(match),
                        advisory_url(match),
                        score,
                    )
        reported.append(
            {
                "name": subject["name"],
                "version": subject["version"],
                "track": subject["track"],
                "reference": subject["reference"],
                "digest": subject["digest"],
                "platforms": [entry["platform"] for entry in subject["platforms"]],
                "monitored": monitored,
                "published": subject["published"],
                "fixable": fixable,
            }
        )
    if len(identities) != 1:
        raise SystemExit(
            "monitor shard mixed vulnerability databases: "
            f"{json.dumps(identities, sort_keys=True)}"
        )
    return list(findings.values()), rules, identities[0], reported


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: build_monitor_sarif.py MANIFEST SARIF REPORT")
    manifest_path = Path(sys.argv[1])
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    findings, rules, identity, reported = collect(manifest, manifest_path.parent)

    ordered = sorted(findings, key=lambda finding: finding.key)
    used = sorted({finding.advisory for finding in ordered})
    monitored = empty_counts()
    published = empty_counts()
    platforms = 0
    fixable = 0
    for subject in reported:
        add_counts(monitored, subject["monitored"])
        add_counts(published, subject["published"])
        platforms += len(subject["platforms"])
        fixable += int(subject["fixable"])
    totals = {
        "subjects": len(reported),
        "platforms": platforms,
        "monitored": monitored,
        "published": published,
        "fixable": fixable,
        "results": len(ordered),
        "advisories": len(used),
    }
    report = {
        "shard": manifest["shard"],
        "shards": manifest["shards"],
        "catalog": manifest["catalog"],
        "grype": identity,
        "totals": totals,
        "subjects": reported,
    }
    sarif = {
        "$schema": SARIF_SCHEMA,
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "Grype",
                        "version": str(identity.get("version") or "unknown"),
                        "informationUri": "https://github.com/anchore/grype",
                        "rules": [rules[advisory] for advisory in used],
                    }
                },
                "automationDetails": {
                    "id": f"verity-images/monitor/{manifest['shard']}/"
                },
                "invocations": [{"executionSuccessful": True}],
                "results": [finding.result() for finding in ordered],
                "properties": report,
            }
        ],
    }
    _ = Path(sys.argv[2]).write_text(
        json.dumps(sarif, indent=1, sort_keys=False) + "\n", encoding="utf-8"
    )
    _ = Path(sys.argv[3]).write_text(
        json.dumps(report, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
