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
POLICY: Final = ROOT / "scripts/apk_repository_policy.py"
RUNTIME_TEST: Final = ROOT / "scripts/test_fips_runtime.sh"
RUNTIME_IMAGE: Final = "cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e"


def job(text: str, name: str, next_name: str) -> str:
    start = f"  {name}:\n"
    end = f"\n  {next_name}:\n"
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    policy = POLICY.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
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
    assert "GH_TOKEN: ${{ github.token }}" in signing
    assert "SOURCE_SHA: ${{ inputs.source-sha }}" in signing
    assert '[[ "$GITHUB_SHA" == "$SOURCE_SHA" ]]' in signing
    assert 'bash .github/scripts/validate-artifact-digest.sh artifact.json "$artifact_digest" "$GITHUB_RUN_ID"' in signing
    assert "gh attestation verify" in signing
    assert "--source-digest \"$SOURCE_SHA\"" in signing
    assert "artifact-ids:" in signing
    assert "run-id:" not in signing
    assert signing.index("Validate source and artifacts") < signing.index("APK_REPOSITORY_PRIVATE_KEY")
    assert signing.index("Validate source and artifacts") < signing.index("Download only current-run build artifacts")
    assert "gh release view \"$RELEASE_TAG\"" in signing
    assert 'git ls-remote --exit-code --tags origin "refs/tags/${RELEASE_TAG}"' in signing
    assert "gh release upload \"$RELEASE_TAG\" \"$ARCHIVE\"" in signing
    assert "--clobber" not in signing
    assert (
        "    concurrency:\n"
        "      group: apk-signing-${{ inputs.release-tag }}\n"
        "      cancel-in-progress: false\n"
    ) in signing
    assert "verity-apk-repository.tar.zst" in signing
    assert 'private_key="$work_dir/verity-apk-2026.rsa"' in signing
    assert 'melange sign --signing-key "$private_key" "$package"' in signing
    assert signing.index("gh release view \"$RELEASE_TAG\"") < signing.index(
        "private_key=\"$work_dir/verity-apk-2026.rsa\""
    )
    assert signing.index('git ls-remote --exit-code --tags origin "refs/tags/${RELEASE_TAG}"') < signing.index(
        'melange sign --signing-key "$private_key" "$package"'
    )
    assert signing.index('melange sign --signing-key "$private_key" "$package"') < signing.index(
        ".github/scripts/assemble-apk-repository.sh"
    )
    assert "unset APK_REPOSITORY_PRIVATE_KEY" in signing
    assert 'rm -f "$private_key"' in signing
    assert "PRIVATE KEY" in signing
    assert "APK_REPOSITORY_PRIVATE_KEY" not in x86_64 + aarch64
    assert RUNTIME_IMAGE in policy + runtime_test
    assert ":latest" not in policy + runtime_test


if __name__ == "__main__":
    main()
