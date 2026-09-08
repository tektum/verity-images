#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_build_image_dashboard.py

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
BUILDER: Final = ROOT / "scripts/build_image_dashboard.py"
SEVERITIES: Final = ("critical", "high", "medium", "low", "negligible", "unknown")
MARKER: Final = "<!-- verity-image-dashboard/v1 -->\n# Image Dashboard"


def sha(character: str) -> str:
    return f"sha256:{character * 64}"


def catalog(images: int = 8) -> dict:
    return {
        "schemaVersion": 2,
        "publishedAt": "2026-09-08T03:17:00Z",
        "source": {
            "runId": "700",
            "runUrl": "https://github.com/tektum/verity-images/actions/runs/700",
            "commit": "c" * 40,
        },
        "images": images,
        "sha256": sha("a"),
        "inventorySha256": sha("b"),
    }


def grype() -> dict:
    return {
        "name": "grype",
        "version": "0.104.1",
        "db": {
            "built": "2026-09-08T00:00:00Z",
            "schemaVersion": 6,
            "checksum": "sha256:database",
        },
    }


def subject(index: int, *, name: str | None = None, context: str | None = None) -> dict:
    digest = sha(f"{index:x}")
    return {
        "name": name or f"image-{index}",
        "version": f"{index}.0.0",
        "track": "stable",
        "context": context or f"images/image-{index}",
        "reference": f"ghcr.io/tektum/image-{index}@{digest}",
        "digest": digest,
        "inputDigest": sha(f"{index + 8:x}"),
        "platforms": ["linux/amd64", "linux/arm64"],
        "published": {severity: 0 for severity in SEVERITIES},
    }


def finding(
    item: dict,
    fingerprint: str,
    *,
    severity: str = "high",
    package: str = "busybox",
    platforms: list[str] | None = None,
) -> dict:
    platform_names = platforms or ["linux/amd64", "linux/arm64"]
    return {
        "fingerprint": fingerprint,
        "image": item["name"],
        "version": item["version"],
        "track": item["track"],
        "context": item["context"],
        "reference": item["reference"],
        "digest": item["digest"],
        "inputDigest": item["inputDigest"],
        "advisory": f"CVE-2026-{fingerprint}",
        "package": {
            "type": "apk",
            "name": package,
            "purl": f"pkg:apk/wolfi/{package}@1.0-r0",
            "installedVersion": "1.0-r0",
        },
        "severity": severity,
        "fixedVersions": ["1.0-r1"],
        "platforms": [
            {"platform": platform, "fixedVersions": ["1.0-r1"]}
            for platform in platform_names
        ],
    }


def fixture() -> list[dict]:
    shared_catalog = catalog()
    shared_grype = grype()
    reports = []
    for shard in range(8):
        item = subject(shard)
        reports.append(
            {
                "shard": shard,
                "shards": 8,
                "catalog": copy.deepcopy(shared_catalog),
                "grype": copy.deepcopy(shared_grype),
                "totals": {"subjects": 1, "findings": 0},
                "subjects": [item],
                "findings": [],
            }
        )
    reports[0]["findings"] = [
        finding(reports[0]["subjects"][0], "one", severity="medium", package="zlib")
    ]
    reports[3]["findings"] = [
        finding(reports[3]["subjects"][0], "two", severity="critical", package="openssl")
    ]
    return reports


def write_reports(root: Path, reports: list[dict]) -> Path:
    input_directory = root / "input"
    input_directory.mkdir()
    for index, report in enumerate(reports):
        directory = input_directory / f"monitor-{index}"
        directory.mkdir()
        (directory / "report.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
    return input_directory


def invoke(
    root: Path,
    reports: list[dict],
    stem: str,
    *,
    expect_success: bool = True,
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    case = root / stem
    case.mkdir()
    input_directory = write_reports(case, reports)
    body = case / "body.md"
    aggregate = case / "aggregate.json"
    result = subprocess.run(
        [
            sys.executable,
            str(BUILDER),
            str(input_directory),
            "tektum/verity-images",
            "12345",
            "2",
            str(body),
            str(aggregate),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert (result.returncode == 0) is expect_success, result.stderr
    return result, body, aggregate


def reject(root: Path, reports: list[dict], stem: str, message: str) -> None:
    result, body, aggregate = invoke(root, reports, stem, expect_success=False)
    assert message in result.stderr
    assert not body.exists()
    assert not aggregate.exists()


def coherent_success(root: Path) -> None:
    reports = fixture()
    _, body_path, report_path = invoke(root, reports, "success")
    body = body_path.read_text(encoding="utf-8")
    raw_report = report_path.read_bytes()
    report = json.loads(raw_report)

    assert body.startswith(MARKER)
    assert "Generated view. Editing this issue does not request remediation." in body
    assert "[12345](https://github.com/tektum/verity-images/actions/runs/12345), attempt 2" in body
    assert "8/8 shards, 8 image streams, 16 platforms" in body
    assert "version 0.104.1" in body
    assert "## Needs work" in body
    assert "vulnerability-free" not in body
    assert "[ ]" not in body
    assert "Rows reflect findings with published fixes in the latest complete scan" in body
    assert "Rows leave this dashboard only after" not in body

    assert report["schemaVersion"] == "verity-image-dashboard-report/v1"
    assert report["runUrl"] == "https://github.com/tektum/verity-images/actions/runs/12345"
    assert report["runAttempt"] == 2
    assert report["totals"] == {
        "affectedSubjects": 2,
        "findings": 2,
        "platforms": 16,
        "severities": {
            "critical": 1,
            "high": 0,
            "medium": 1,
            "low": 0,
            "negligible": 0,
            "unknown": 0,
        },
        "subjects": 8,
    }
    assert raw_report == (
        json.dumps(report, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    ).encode()
    assert body.index("image-3 3.0.0") < body.index("image-0 0.0.0")
    assert "`333333333333`" in body
    assert (
        "security/code-scanning?query=is%3Aopen+tool%3AGrype+path%3Aimages%2Fimage-3%2Fmetadata.yaml"
        in body
    )

    _, repeated_body, repeated_report = invoke(root, reports, "repeated")
    assert repeated_body.read_bytes() == body_path.read_bytes()
    assert repeated_report.read_bytes() == report_path.read_bytes()


def zero_findings(root: Path) -> None:
    reports = fixture()
    for report in reports:
        report["findings"] = []
    _, body_path, _ = invoke(root, reports, "zero")
    body = body_path.read_text(encoding="utf-8")
    assert "## Needs work" not in body
    assert (
        "No published images have findings with a currently published fix as of this complete scan."
        in body
    )


def shard_validation(root: Path) -> None:
    reports = fixture()
    reports[1]["shard"] = 0
    reject(root, reports, "duplicate-shard", "exactly 0 through 7")

    reports = fixture()
    reports[7]["shard"] = 8
    reject(root, reports, "wrong-shard", "exactly 0 through 7")

    case = root / "missing-shard"
    case.mkdir()
    input_directory = write_reports(case, fixture())
    (input_directory / "monitor-7" / "report.json").unlink()
    (input_directory / "monitor-7").rmdir()
    body = case / "body.md"
    aggregate = case / "report.json"
    result = subprocess.run(
        [
            sys.executable,
            str(BUILDER),
            str(input_directory),
            "tektum/verity-images",
            "1",
            "1",
            str(body),
            str(aggregate),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "monitor-0 through monitor-7" in result.stderr
    assert not body.exists()
    assert not aggregate.exists()

    reports = fixture()
    reports[2]["shards"] = 7
    reject(root, reports, "wrong-shard-count", "shards must equal 8")


def identity_validation(root: Path) -> None:
    reports = fixture()
    reports[1]["catalog"]["publishedAt"] = "2026-09-09T00:00:00Z"
    reject(root, reports, "mixed-catalog", "mixed catalogs")

    reports = fixture()
    reports[1]["grype"]["db"]["built"] = "2026-09-09T00:00:00Z"
    reject(root, reports, "mixed-db", "mixed Grype identities")


def subject_validation(root: Path) -> None:
    reports = fixture()
    reports[1]["subjects"][0] = copy.deepcopy(reports[0]["subjects"][0])
    reports[1]["findings"] = []
    reject(root, reports, "duplicate-subject", "duplicate subject identity")

    reports = fixture()
    reports[1]["subjects"] = []
    reject(root, reports, "missing-subject", "does not match catalog.images")

    reports = fixture()
    reports[1]["subjects"][0]["platforms"] = ["linux/amd64", "linux/s390x"]
    reject(root, reports, "wrong-platform", "must contain linux/amd64 and linux/arm64")

    reports = fixture()
    del reports[1]["subjects"][0]["platforms"]
    reject(root, reports, "missing-platform", "must contain linux/amd64 and linux/arm64")


def finding_validation(root: Path) -> None:
    reports = fixture()
    reports[0]["findings"][0]["context"] = "images/not-the-subject"
    reject(root, reports, "finding-mismatch", "does not match its subject")

    reports = fixture()
    reports[3]["findings"][0]["fingerprint"] = "one"
    reject(root, reports, "duplicate-fingerprint", "duplicate finding fingerprint")

    reports = fixture()
    reports[0]["findings"][0]["fixedVersions"] = []
    reject(root, reports, "empty-fixes", "fixedVersions must be a non-empty array")

    reports = fixture()
    reports[0]["findings"][0]["platforms"][0]["fixedVersions"] = []
    reject(root, reports, "empty-platform-fixes", "fixedVersions must be a non-empty array")

    reports = fixture()
    reports[0]["findings"][0]["severity"] = "important"
    reject(root, reports, "bad-severity", "severity is invalid")

    reports = fixture()
    reports[0]["findings"][0]["platforms"][0]["platform"] = "linux/s390x"
    reject(root, reports, "finding-platform", "is not covered by its subject")


def row_ordering(root: Path) -> None:
    reports = fixture()
    for report in reports:
        report["findings"] = []
    reports[0]["findings"] = [
        finding(reports[0]["subjects"][0], "order-high-a", severity="high")
    ]
    reports[1]["findings"] = [
        finding(reports[1]["subjects"][0], "order-high-b", severity="high"),
        finding(reports[1]["subjects"][0], "order-low", severity="low"),
    ]
    reports[2]["findings"] = [
        finding(reports[2]["subjects"][0], "order-high-c", severity="high")
    ]
    reports[3]["findings"] = [
        finding(reports[3]["subjects"][0], "order-critical", severity="critical")
    ]
    reports[4]["findings"] = [
        finding(reports[4]["subjects"][0], "order-medium", severity="medium")
    ]
    _, body_path, _ = invoke(root, reports, "ordering")
    body = body_path.read_text(encoding="utf-8")
    positions = [
        body.index(f"image-{index} {index}.0.0") for index in (3, 1, 0, 2, 4)
    ]
    assert positions == sorted(positions)



def table_rendering(root: Path) -> None:
    reports = fixture()
    special = reports[0]["subjects"][0]
    special["name"] = "slash\\pipe|line\r\nbreak [ ] `tick`"
    special["context"] = "images/slash\\pipe|line\nbreak"
    special["reference"] = f"ghcr.io/tektum/special@{special['digest']}"
    reports[0]["findings"] = [
        finding(special, "escape", severity="high", package="pkg\\one|two\nthree")
    ]
    packages = ["zeta", "alpha", "eta", "beta", "theta", "gamma", "delta"]
    reports[3]["findings"] = [
        finding(
            reports[3]["subjects"][0],
            f"package-{index}",
            severity="critical",
            package=package,
        )
        for index, package in enumerate(packages)
    ]
    _, body_path, _ = invoke(root, reports, "table")
    body = body_path.read_text(encoding="utf-8")
    assert "slash\\\\pipe\\|line<br>break" in body
    assert "\\[ \\]" in body
    assert "\\`tick\\`" in body
    assert " [ ]" not in body
    assert "pkg\\\\one\\|two<br>three" in body
    assert "alpha, beta, delta, eta, gamma, theta, +1 more" in body
    assert body.index("image-3 3.0.0") < body.index("slash\\\\pipe")


def size_truncation(root: Path) -> None:
    reports = fixture()
    for report in reports:
        item = report["subjects"][0]
        report["findings"] = [
            finding(
                item,
                f"large-{report['shard']}-{index}",
                severity="high",
                package=f"package-{index}-" + (chr(97 + report["shard"]) * 2200),
            )
            for index in range(6)
        ]
    _, body_path, _ = invoke(root, reports, "truncated")
    body = body_path.read_text(encoding="utf-8")
    encoded = body.encode("utf-8")
    assert len(encoded) <= 60 * 1024
    assert "Showing " in body
    assert " of 8 affected image streams. Full machine-readable results are in the linked workflow artifacts." in body
    notice = next(line for line in body.splitlines() if line.startswith("Showing "))
    shown = int(notice.split()[1])
    assert 0 < shown < 8
    table_rows = [line for line in body.splitlines() if line.startswith("| image-")]
    assert len(table_rows) == shown
    assert all(line.endswith(" |") for line in table_rows)


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        coherent_success(root)
        zero_findings(root)
        shard_validation(root)
        identity_validation(root)
        subject_validation(root)
        finding_validation(root)
        row_ordering(root)
        table_rendering(root)
        size_truncation(root)
    print("passed scripts/test_build_image_dashboard.py")


if __name__ == "__main__":
    main()
