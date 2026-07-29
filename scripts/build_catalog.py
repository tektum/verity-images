#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/build_catalog.py BUILD_REPORT SCAN_DIR PREVIOUS OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT

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
if $previous != "" then
  . as $updates | input as $current |
  .images = (reduce ($current.images + $updates.images)[] as $image ({};
    .[$image.name + "@" + $image.version] = $image
  ) | [.[]] | sort_by(.name, .version))
else
  .images |= sort_by(.name, .version)
end |
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
    if len(sys.argv) != 9:
        raise SystemExit(
            "usage: build_catalog.py BUILD_REPORT SCAN_DIR PREVIOUS OUTPUT RUN_ID RUN_URL SOURCE_SHA PUBLISHED_AT"
        )
    report, scans = map(Path, sys.argv[1:3])
    previous = Path(sys.argv[3]) if sys.argv[3] else None
    output = Path(sys.argv[4])
    run_id, run_url, source_sha, published_at = sys.argv[5:]
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
            "--arg",
            "previous",
            str(previous or ""),
            FILTER,
            str(report),
            *([str(previous)] if previous else []),
        ]
    )
    _ = output.write_text(catalog, encoding="utf-8")


if __name__ == "__main__":
    main()
