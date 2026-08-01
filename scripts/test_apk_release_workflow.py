#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_release_workflow.py

from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
WORKFLOW: Final = ROOT / ".github/workflows/apk-repository.yaml"


def job(text: str, name: str, next_name: str) -> str:
    start = f"  {name}:\n"
    end = f"\n  {next_name}:\n"
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    x86_64 = job(workflow, "build-x86_64", "build-aarch64")
    aarch64 = job(workflow, "build-aarch64", "apk-signing")
    signing = workflow.split("  apk-signing:\n", maxsplit=1)[1]

    assert "  pull_request:\n" in workflow
    assert "    branches: [main]\n" in workflow
    assert "runs-on: ubuntu-24.04\n" in x86_64
    assert "runs-on: ubuntu-24.04-arm\n" in aarch64
    assert "environment:" not in x86_64 + aarch64
    assert "secrets." not in x86_64 + aarch64
    assert "retention-days: 7\n" in x86_64 + aarch64
    assert "actions/attest-build-provenance@" in x86_64 + aarch64

    assert "github.event_name == 'workflow_dispatch'" in signing
    assert "github.repository == 'tektum/verity-images'" in signing
    assert "github.ref == 'refs/heads/main'" in signing
    assert "environment: apk-signing" in signing
    assert "attestations: write" in signing
    assert "id-token: write" in signing
    assert "SOURCE_SHA: ${{ inputs.source-sha }}" in signing
    assert '[[ "$GITHUB_SHA" == "$SOURCE_SHA" ]]' in signing
    assert '.workflow_run.id == ($run_id | tonumber)' in signing
    assert '.digest == $digest' in signing
    assert "gh attestation verify" in signing
    assert "--source-digest \"$SOURCE_SHA\"" in signing
    assert "artifact-ids:" in signing
    assert "run-id:" not in signing
    assert signing.index("Validate source and artifacts") < signing.index("APK_REPOSITORY_PRIVATE_KEY")
    assert "gh release view \"$RELEASE_TAG\"" in signing
    assert "gh release upload \"$RELEASE_TAG\" \"$ARCHIVE\"" in signing
    assert "--clobber" not in signing
    assert "verity-apk-repository.tar.zst" in signing
    assert "unset APK_REPOSITORY_PRIVATE_KEY" in signing
    assert 'rm -f "$private_key"' in signing
    assert "PRIVATE KEY" in signing
    assert "APK_REPOSITORY_PRIVATE_KEY" not in x86_64 + aarch64


if __name__ == "__main__":
    main()
