#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_build_monitor_sarif.py

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Final


ROOT: Final = Path(__file__).resolve().parents[1]
BUILDER: Final = ROOT / "scripts/build_monitor_sarif.py"
FINGERPRINT: Final = "verityMonitorFinding/v1"
SEVERITIES: Final = ("critical", "high", "medium", "low", "negligible", "unknown")


def database(*, built: str = "2026-09-08T00:00:00Z") -> dict:
    return {
        "built": built,
        "schemaVersion": "6.0.0",
        "from": "https://example.test/grype-db.tar.zst",
        "checksum": "sha256:database",
    }


def descriptor(*, built: str = "2026-09-08T00:00:00Z", version: str = "0.104.1") -> dict:
    return {
        "name": "grype",
        "version": version,
        "db": {
            "status": database(built=built) | {"path": "/tmp/vulnerability.db", "valid": True},
            "providers": {},
        },
    }




def match(
    advisory: str,
    package: str,
    installed: str,
    *,
    severity: str | None,
    fixes: list[str] | None,
    cvss: list[dict] | None = None,
    related: list[dict] | None = None,
) -> dict:
    vulnerability = {
        "id": advisory,
        "description": f"Description for {advisory}",
        "dataSource": f"https://example.test/{advisory}",
    }
    if severity is not None:
        vulnerability["severity"] = severity
    if fixes is not None:
        vulnerability["fix"] = {"versions": fixes, "state": "fixed" if fixes else "not-fixed"}
    if cvss is not None:
        vulnerability["cvss"] = cvss
    finding = {
        "vulnerability": vulnerability,
        "artifact": {
            "name": package,
            "version": installed,
            "type": "apk",
            "purl": f"pkg:apk/wolfi/{package}@{installed}",
        },
    }
    if related is not None:
        finding["relatedVulnerabilities"] = related
    return finding


def scan(matches: list[dict], *, built: str = "2026-09-08T00:00:00Z", version: str = "0.104.1") -> dict:
    return {"descriptor": descriptor(built=built, version=version), "matches": matches}


def counts(*values: int) -> dict[str, int]:
    return dict(zip(SEVERITIES, values, strict=True))


def manifest(*, reference: str, digest: str) -> dict:
    return {
        "shard": 3,
        "shards": 8,
        "catalog": {
            "schemaVersion": 2,
            "publishedAt": "2026-09-08T03:17:00Z",
            "source": {"commit": "e" * 40},
            "images": 2,
            "sha256": "sha256:" + "a" * 64,
            "inventorySha256": "sha256:" + "b" * 64,
        },
        "database": database(),


        "subjects": [
            {
                "name": "verity",
                "version": "1.0.0",
                "track": "stable",
                "reference": reference,
                "digest": digest,
                "inputDigest": "sha256:input-old",
                "context": "images/verity",
                "published": counts(1, 2, 3, 4, 5, 6),
                "platforms": [
                    {"platform": "linux/amd64", "scan": "verity-amd64.json"},
                    {"platform": "linux/arm64", "scan": "verity-arm64.json"},
                ],
            },
            {
                "name": "verity-edge",
                "version": "2.0.0",
                "track": "edge",
                "reference": "registry.example/verity-edge@sha256:edge",
                "digest": "sha256:edge",
                "inputDigest": "sha256:input-edge",
                "context": "images/verity-edge",
                "published": counts(6, 5, 4, 3, 2, 1),
                "platforms": [
                    {"platform": "linux/amd64", "scan": "edge-amd64.json"}
                ],
            },
        ],
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run_builder(root: Path, document: dict, stem: str) -> tuple[dict, dict, bytes, bytes]:
    manifest_path = root / f"manifest-{stem}.json"
    sarif_path = root / f"results-{stem}.sarif"
    report_path = root / f"report-{stem}.json"
    write_json(manifest_path, document)
    subprocess.run(
        [sys.executable, str(BUILDER), str(manifest_path), str(sarif_path), str(report_path)],
        check=True,
    )
    sarif_bytes = sarif_path.read_bytes()
    report_bytes = report_path.read_bytes()
    return (
        json.loads(sarif_bytes),
        json.loads(report_bytes),
        sarif_bytes,
        report_bytes,
    )


def reject_builder(root: Path, document: dict, stem: str, message: str) -> None:
    manifest_path = root / f"manifest-{stem}.json"
    sarif_path = root / f"results-{stem}.sarif"
    report_path = root / f"report-{stem}.json"
    write_json(manifest_path, document)
    result = subprocess.run(
        [sys.executable, str(BUILDER), str(manifest_path), str(sarif_path), str(report_path)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert message in result.stderr
    assert not sarif_path.exists()
    assert not report_path.exists()



def fixture_scans() -> tuple[dict, dict, dict]:
    amd64 = scan(
        [
            match(
                "CVE-2026-0001",
                "merged",
                "1.0-r0",
                severity="High",
                fixes=["3.0-r0", "2.0-r0"],
                cvss=[
                    {"version": "2.0", "metrics": {"baseScore": 9.9}},
                    {"version": "3.1", "metrics": {"baseScore": 7.5}},
                    {"version": "4.0", "metrics": {"baseScore": 8.8}},
                ],
            ),
            match(
                "CVE-2026-0002",
                "package-a",
                "1.0-r0",
                severity="Medium",
                fixes=["1.1-r0"],
            ),
            match(
                "CVE-2026-0002",
                "package-b",
                "2.0-r0",
                severity="Low",
                fixes=["2.1-r0"],
            ),
            match(
                "CVE-2026-NOFIX-EMPTY",
                "unfixed-empty",
                "3.0-r0",
                severity="Critical",
                fixes=[],
            ),
            match(
                "CVE-2026-NOFIX-MISSING",
                "unfixed-missing",
                "4.0-r0",
                severity="Low",
                fixes=None,
            ),
            match(
                "CVE-2026-NEGLIGIBLE",
                "negligible",
                "5.0-r0",
                severity="Negligible",
                fixes=["5.1-r0"],
                cvss=[{"version": "2.0", "metrics": {"baseScore": 10.0}}],
            ),
            match(
                "CVE-2026-MISSING",
                "missing-severity",
                "6.0-r0",
                severity=None,
                fixes=["6.1-r0"],
            ),
            match(
                "CVE-2026-UNKNOWN",
                "unknown-severity",
                "7.0-r0",
                severity="Unknown",
                fixes=["7.1-r0"],
            ),
            match(
                "CVE-2026-RELATED",
                "related-severity",
                "8.0-r0",
                severity="Unknown",
                fixes=["8.1-r0"],
                related=[
                    {
                        "severity": "High",
                        "cvss": [
                            {"version": "3.0", "metrics": {"baseScore": 6.4}}
                        ],
                    }
                ],
            ),
            match(
                "CVE-2026-LOW",
                "low-severity",
                "9.0-r0",
                severity="Low",
                fixes=["9.1-r0"],
            ),
        ]
    )
    arm64 = scan(
        [
            match(
                "CVE-2026-0001",
                "merged",
                "1.0-r0",
                severity="Critical",
                fixes=["4.0-r0", "2.0-r0"],
                cvss=[{"version": "3.1", "metrics": {"baseScore": 9.1}}],
            )
        ]
    )
    edge = scan(
        [
            match(
                "CVE-2026-CRITICAL",
                "critical-severity",
                "10.0-r0",
                severity="Critical",
                fixes=["10.1-r0"],
            )
        ]
    )
    return amd64, arm64, edge


def result_for(results: list[dict], advisory: str, package: str) -> dict:
    return next(
        result
        for result in results
        if result["ruleId"] == advisory and result["properties"]["package"] == package
    )


def fingerprint_for(results: list[dict], advisory: str, package: str) -> str:
    return result_for(results, advisory, package)["partialFingerprints"][FINGERPRINT]


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        amd64, arm64, edge = fixture_scans()
        write_json(root / "verity-amd64.json", amd64)
        write_json(root / "verity-arm64.json", arm64)
        write_json(root / "edge-amd64.json", edge)
        base_manifest = manifest(
            reference="registry.example/verity@sha256:old",
            digest="sha256:old",
        )

        sarif, report, sarif_bytes, report_bytes = run_builder(root, base_manifest, "first")
        repeated = run_builder(root, base_manifest, "second")
        assert repeated[2] == sarif_bytes
        assert repeated[3] == report_bytes

        run = sarif["runs"][0]
        results = run["results"]
        rules = run["tool"]["driver"]["rules"]
        rules_by_id = {rule["id"]: rule for rule in rules}

        assert run["tool"]["driver"]["version"] == "0.104.1"
        assert report["grype"] == {"name": "grype", "version": "0.104.1", "db": database()}

        assert report["totals"] == {
            "subjects": 2,
            "platforms": 3,
            "monitored": counts(3, 2, 1, 3, 1, 2),
            "published": counts(7, 7, 7, 7, 7, 7),
            "fixable": 10,
            "results": 9,
            "advisories": 8,
        }
        assert report["subjects"][0]["published"] == counts(1, 2, 3, 4, 5, 6)
        assert report["subjects"][1]["published"] == counts(6, 5, 4, 3, 2, 1)
        findings = report["findings"]
        merged_finding = next(
            finding
            for finding in findings
            if finding["advisory"] == "CVE-2026-0001"
            and finding["package"]["name"] == "merged"
        )
        assert merged_finding == {
            "fingerprint": hashlib.sha256(
                b"verity|1.0.0|CVE-2026-0001|apk|merged|1.0-r0"
            ).hexdigest(),
            "image": "verity",
            "version": "1.0.0",
            "track": "stable",
            "context": "images/verity",
            "reference": "registry.example/verity@sha256:old",
            "digest": "sha256:old",
            "inputDigest": "sha256:input-old",
            "advisory": "CVE-2026-0001",
            "package": {
                "type": "apk",
                "name": "merged",
                "purl": "pkg:apk/wolfi/merged@1.0-r0",
                "installedVersion": "1.0-r0",
            },
            "severity": "critical",
            "fixedVersions": ["2.0-r0", "3.0-r0", "4.0-r0"],
            "platforms": [
                {
                    "platform": "linux/amd64",
                    "fixedVersions": ["2.0-r0", "3.0-r0"],
                },
                {
                    "platform": "linux/arm64",
                    "fixedVersions": ["2.0-r0", "4.0-r0"],
                },
            ],
        }
        assert report["subjects"][0]["context"] == "images/verity"
        assert report["subjects"][0]["inputDigest"] == "sha256:input-old"


        rule_ids = [rule["id"] for rule in rules]
        assert rule_ids == sorted(rule_ids)
        assert "CVE-2026-NOFIX-EMPTY" not in rule_ids
        assert "CVE-2026-NOFIX-MISSING" not in rule_ids
        assert len([result for result in results if result["ruleId"] == "CVE-2026-0002"]) == 2
        assert rule_ids.count("CVE-2026-0002") == 1

        result_keys = [
            (
                result["properties"]["image"],
                result["properties"]["imageVersion"],
                result["ruleId"],
                result["properties"]["packageType"],
                result["properties"]["package"],
                result["properties"]["installedVersion"],
            )
            for result in results
        ]
        assert result_keys == sorted(result_keys)

        merged = result_for(results, "CVE-2026-0001", "merged")
        assert merged["properties"]["platforms"] == ["linux/amd64", "linux/arm64"]
        assert merged["properties"]["fixedVersions"] == [
            "2.0-r0",
            "3.0-r0",
            "4.0-r0",
        ]
        assert "Apply compatible image inputs" in merged["message"]["text"]
        assert "Rebuild verity" not in merged["message"]["text"]
        assert merged["locations"] == [
            {
                "physicalLocation": {
                    "artifactLocation": {"uri": "images/verity/metadata.yaml"},
                    "region": {"startLine": 1},
                }
            }
        ]
        assert merged["properties"]["severity"] == "critical"
        expected_fingerprint = hashlib.sha256(
            b"verity|1.0.0|CVE-2026-0001|apk|merged|1.0-r0"
        ).hexdigest()
        assert merged["partialFingerprints"][FINGERPRINT] == expected_fingerprint


        assert merged["level"] == "error"
        assert result_for(results, "CVE-2026-CRITICAL", "critical-severity")["level"] == "error"
        assert result_for(results, "CVE-2026-0002", "package-a")["level"] == "warning"
        assert result_for(results, "CVE-2026-LOW", "low-severity")["level"] == "note"
        assert result_for(results, "CVE-2026-NEGLIGIBLE", "negligible")["level"] == "note"
        assert result_for(results, "CVE-2026-MISSING", "missing-severity")["level"] == "warning"
        assert result_for(results, "CVE-2026-UNKNOWN", "unknown-severity")["level"] == "warning"
        related = result_for(results, "CVE-2026-RELATED", "related-severity")
        assert related["properties"]["severity"] == "high"
        assert related["level"] == "error"

        assert rules_by_id["CVE-2026-0001"]["properties"]["security-severity"] == "9.1"
        assert rules_by_id["CVE-2026-RELATED"]["properties"]["security-severity"] == "6.4"
        assert "security-severity" not in rules_by_id["CVE-2026-NEGLIGIBLE"]["properties"]
        assert "security-severity" not in rules_by_id["CVE-2026-MISSING"]["properties"]

        rebuilt_manifest = copy.deepcopy(base_manifest)
        rebuilt_manifest["subjects"][0]["reference"] = "registry.example/verity@sha256:new"
        rebuilt_manifest["subjects"][0]["digest"] = "sha256:new"
        rebuilt_sarif, _, _, _ = run_builder(root, rebuilt_manifest, "rebuilt")
        rebuilt_fingerprint = fingerprint_for(
            rebuilt_sarif["runs"][0]["results"], "CVE-2026-0001", "merged"
        )
        assert rebuilt_fingerprint == expected_fingerprint

        changed_amd64 = copy.deepcopy(amd64)
        changed_arm64 = copy.deepcopy(arm64)
        changed_amd64["matches"][0]["artifact"]["version"] = "1.0-r1"
        changed_arm64["matches"][0]["artifact"]["version"] = "1.0-r1"
        write_json(root / "verity-amd64.json", changed_amd64)
        write_json(root / "verity-arm64.json", changed_arm64)
        changed_sarif, _, _, _ = run_builder(root, rebuilt_manifest, "changed-installed")
        changed_fingerprint = fingerprint_for(
            changed_sarif["runs"][0]["results"], "CVE-2026-0001", "merged"
        )
        assert changed_fingerprint != expected_fingerprint
        assert changed_fingerprint == hashlib.sha256(
            b"verity|1.0.0|CVE-2026-0001|apk|merged|1.0-r1"
        ).hexdigest()

        invalid_database = copy.deepcopy(base_manifest)
        invalid_database["database"]["checksum"] = ""
        reject_builder(
            root,
            invalid_database,
            "invalid-database",
            "invalid vulnerability database identity",
        )

        write_json(root / "verity-amd64.json", amd64)
        different_database = copy.deepcopy(arm64)
        different_database["descriptor"]["db"]["status"]["built"] = "2026-09-09T00:00:00Z"
        write_json(root / "verity-arm64.json", different_database)
        reject_builder(
            root,
            base_manifest,
            "scan-database-mismatch",
            "monitor scan database built does not match",
        )

        different_version = copy.deepcopy(arm64)
        different_version["descriptor"]["version"] = "0.105.0"
        write_json(root / "verity-arm64.json", different_version)
        reject_builder(
            root,
            base_manifest,
            "mixed-version",
            "mixed vulnerability databases",
        )

    print("passed scripts/test_build_monitor_sarif.py")


if __name__ == "__main__":
    main()
