#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_catalog.py BUILD_REPORT SCAN_DIR PREVIOUS OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Final

IDENTITY: Final = "https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main"
ISSUER: Final = "https://token.actions.githubusercontent.com"
FILTER: Final = r"""
.report.images |= map(
  .tags = (.tags | split(",")) |
  .registry = ("ghcr.io/tektum/" + .name) |
  .reference = (.registry + "@" + .digest) |
  .scanArtifact = ("scan-" + .name + "-" + .version) |
  .verification = {
    signature: ("cosign verify --certificate-identity '" + $identity +
      "' --certificate-oidc-issuer '" + $issuer + "' " + .reference),
    sbom: ("cosign verify-attestation --type spdxjson --certificate-identity '" + $identity +
      "' --certificate-oidc-issuer '" + $issuer + "' " + .reference),
    provenance: ("gh attestation verify oci://" + .reference + " --repo tektum/verity-images")
  }
) |
if $previous != "" then
  .report as $updates | .previous as $current |
  .report.images = (reduce ($current.images + $updates.images)[] as $image ({};
    .[$image.name + "@" + $image.version] = $image
  ) | [.[]] | sort_by(.name, .version))
else
  .report.images |= sort_by(.name, .version)
end |
{
  schemaVersion: 2,
  publishedAt: $publishedAt,
  source: {runId: $runId, runUrl: $runUrl, commit: $sourceSha},
  policy: {
    fixableVulnerabilitiesAllowed: 0,
    sbomFormat: "SPDX-JSON",
    cosignMinimumVersion: "3.0.6",
    certificateIdentity: $identity,
    certificateIssuer: $issuer
  },
  images: .report.images
}
"""


def run(command: list[str], input_text: str = "") -> str:
    return subprocess.run(command, check=True, capture_output=True, input=input_text, text=True).stdout


def document(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"invalid JSON in {label}: {path}: line {error.lineno}, column {error.colno}: {error.msg}"
        ) from error
    if not isinstance(value, dict):
        raise SystemExit(f"invalid {label}: {path}: expected an object")
    images = value.get("images")
    if not isinstance(images, list) or not images:
        raise SystemExit(f"invalid {label}: {path}: expected a non-empty images array")
    return value


def main() -> None:
    if len(sys.argv) != 9:
        raise SystemExit(
            "usage: build_catalog.py BUILD_REPORT SCAN_DIR PREVIOUS OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT"
        )
    report, scans = map(Path, sys.argv[1:3])
    previous = Path(sys.argv[3]) if sys.argv[3] else None
    output = Path(sys.argv[4])
    run_id, run_url, source_sha, published_at = sys.argv[5:]
    report_document = document(report, "build report")
    previous_document = document(previous, "previous catalog") if previous else None
    for image in report_document["images"]:
        if not isinstance(image, dict):
            raise SystemExit(f"invalid build report: {report}: images must contain objects")
        name = image.get("name")
        version = image.get("version")
        if not isinstance(name, str) or not name or not isinstance(version, str) or not version:
            raise SystemExit(f"invalid build report: {report}: image name and version must be non-empty strings")
        artifact = scans / f"scan-{name}-{version}"
        if not artifact.is_dir() or not tuple(artifact.glob("scan-*.json")):
            raise SystemExit(f"missing scan artifact: {artifact}")
    catalog = run(
        [
            "jq",
            "--sort-keys",
            "--arg",
            "runId",
            run_id,
            "--arg",
            "runUrl",
            run_url,
            "--arg",
            "sourceSha",
            source_sha,
            "--arg",
            "publishedAt",
            published_at,
            "--arg",
            "identity",
            IDENTITY,
            "--arg",
            "issuer",
            ISSUER,
            "--arg",
            "previous",
            "present" if previous_document else "",
            FILTER,
        ],
        json.dumps({"report": report_document, "previous": previous_document}),
    )
    _ = output.write_text(catalog, encoding="utf-8")


if __name__ == "__main__":
    main()
