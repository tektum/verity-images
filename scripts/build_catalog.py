#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_catalog.py BUILD_REPORT SCAN_DIR OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Final

IDENTITY: Final = "https://github.com/tektum/verity-images/.github/workflows/build.yaml@refs/heads/main"
ISSUER: Final = "https://token.actions.githubusercontent.com"
FILTER: Final = r"""
.images |= map(
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
{
  schemaVersion: 1,
  publishedAt: $publishedAt,
  source: {runId: $runId, runUrl: $runUrl, commit: $sourceSha},
  policy: {
    fixableVulnerabilitiesAllowed: 0,
    sbomFormat: "SPDX-JSON",
    certificateIdentity: $identity,
    certificateIssuer: $issuer
  },
  images: .images
}
"""


def run(command: list[str]) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def main() -> None:
    if len(sys.argv) != 8:
        raise SystemExit("usage: build_catalog.py BUILD_REPORT SCAN_DIR OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT")
    report, scans, output = map(Path, sys.argv[1:4])
    run_id, run_url, source_sha, published_at = sys.argv[4:]
    for line in run(["jq", "-r", ".images[] | [.name,.version] | @tsv", str(report)]).splitlines():
        name, version = line.split("\t", maxsplit=1)
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
            FILTER,
            str(report),
        ]
    )
    _ = output.write_text(catalog, encoding="utf-8")


if __name__ == "__main__":
    main()
