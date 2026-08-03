#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_release_workflow.py

import os
import subprocess
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
WORKFLOW: Final = ROOT / ".github/workflows/apk-repository.yaml"
SMOKE_WORKFLOW: Final = ROOT / ".github/workflows/apk-signing-smoke.yaml"
POLICY: Final = ROOT / "scripts/apk_repository_policy.py"
RUNTIME_TEST: Final = ROOT / "scripts/test_fips_runtime.sh"
REPOSITORY_VERIFY: Final = ROOT / "scripts/verify_apk_repository.sh"
RUNTIME_IMAGE: Final = "cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e"


def job(text: str, name: str, next_name: str) -> str:
    start = f"  {name}:\n"
    end = f"\n  {next_name}:\n"
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def runner(job: str) -> str:
    line = next(line.strip() for line in job.splitlines() if line.startswith("    runs-on: "))
    return line.removeprefix("runs-on: ").split("  #", maxsplit=1)[0]


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    smoke_workflow = SMOKE_WORKFLOW.read_text(encoding="utf-8")
    policy = POLICY.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
    repository_verify = REPOSITORY_VERIFY.read_text(encoding="utf-8")
    x86_64 = job(workflow, "build-x86_64", "build-aarch64")
    aarch64 = job(workflow, "build-aarch64", "apk-gate")
    gate = job(workflow, "apk-gate", "apk-signing")
    signing = workflow.split("  apk-signing:\n", maxsplit=1)[1]

    assert "  pull_request:\n" in workflow
    assert "  merge_group:\n    types: [checks_requested]\n" in workflow
    assert "    branches: [main]\n" in workflow
    assert runner(x86_64) == "ubuntu-24.04"
    assert runner(aarch64) == "ubuntu-24.04-arm"
    assert 'ARCHITECTURE: x86_64' in x86_64
    assert 'ARCHITECTURE: aarch64' in aarch64
    assert "uname -m" not in x86_64 + aarch64
    assert 'bash scripts/build_apk_package.sh "$ARCHITECTURE"' in x86_64
    assert 'bash scripts/build_apk_package.sh "$ARCHITECTURE"' in aarch64
    assert "environment:" not in x86_64 + aarch64
    assert "secrets." not in x86_64 + aarch64
    assert "retention-days: 7\n" in x86_64 + aarch64
    assert "actions/attest-build-provenance@" in x86_64 + aarch64

    assert "if: always()" in gate
    assert "needs: [build-x86_64, build-aarch64, apk-signing]" in gate
    assert runner(gate) == "ubuntu-24.04"
    assert "EVENT: ${{ github.event_name }}" in gate
    assert "REF: ${{ github.ref }}" in gate
    assert "REPOSITORY: ${{ github.repository }}" in gate
    assert "X86_64_RESULT: ${{ needs.build-x86_64.result }}" in gate
    assert "AARCH64_RESULT: ${{ needs.build-aarch64.result }}" in gate
    assert "SIGNING_RESULT: ${{ needs.apk-signing.result }}" in gate
    assert '[[ "$X86_64_RESULT" == success ]]' in gate
    assert '[[ "$AARCH64_RESULT" == success ]]' in gate
    assert '[[ "$SIGNING_RESULT" == success ]]' in gate
    assert '[[ "$SIGNING_RESULT" == skipped ]]' in gate
    assert "APK_REPOSITORY_PRIVATE_KEY" not in gate
    gate_script = gate.split("        run: |\n", maxsplit=1)[1]
    for event, ref, repository, signing_result, expected in (
        ("pull_request", "refs/pull/1/merge", "fork/example", "skipped", 0),
        ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1", "tektum/verity-images", "skipped", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "success", 0),
        ("workflow_dispatch", "refs/heads/main", "fork/example", "skipped", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "skipped", 1),
        ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1", "tektum/verity-images", "failure", 1),
    ):
        result = subprocess.run(
            ["bash", "-c", gate_script],
            check=False,
            capture_output=True,
            env={
                **os.environ,
                "AARCH64_RESULT": "success",
                "EVENT": event,
                "REF": ref,
                "REPOSITORY": repository,
                "SIGNING_RESULT": signing_result,
                "X86_64_RESULT": "success",
            },
        )
        assert result.returncode == expected

    assert "github.event_name == 'workflow_dispatch'" in signing
    assert "github.repository == 'tektum/verity-images'" in signing
    assert "github.ref == 'refs/heads/main'" in signing
    assert runner(signing) == "ubuntu-24.04"
    assert runner(smoke_workflow) == "ubuntu-latest"
    assert "environment: apk-signing" in signing
    assert "attestations: write" in signing
    assert "id-token: write" in signing
    assert "GH_TOKEN: ${{ github.token }}" in signing
    assert "SOURCE_SHA: ${{ inputs.source-sha }}" in signing
    assert '[[ "$GITHUB_SHA" == "$SOURCE_SHA" ]]' in signing
    assert 'bash .github/scripts/validate-artifact-digest.sh artifact.json "$artifact_digest" "$GITHUB_RUN_ID"' in signing
    assert "gh attestation verify" in signing
    assert "--source-digest \"$SOURCE_SHA\"" in signing
    assert "--deny-self-hosted-runners" in signing
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
    assert 'umask 077' in signing
    assert 'set +x' in signing
    assert 'private_key_source="$work_dir/verity-apk-2026.source.pem"' in signing
    assert 'private_key="$work_dir/verity-apk-2026.rsa"' in signing
    assert 'printf \'%s\' "$APK_REPOSITORY_PRIVATE_KEY" > "$private_key_source"' in signing
    assert 'unset APK_REPOSITORY_PRIVATE_KEY' in signing
    assert ".github/scripts/prepare-apk-signing-key.sh" in signing
    assert 'packages/keys/verity-apk-2026.rsa.pub' in signing
    assert 'melange sign --signing-key "$private_key" "$package"' in signing
    assert signing.index("gh release view \"$RELEASE_TAG\"") < signing.index(
        "private_key=\"$work_dir/verity-apk-2026.rsa\""
    )
    assert signing.index('git ls-remote --exit-code --tags origin "refs/tags/${RELEASE_TAG}"') < signing.index(
        'melange sign --signing-key "$private_key" "$package"'
    )
    assert "Reject previously published package identity" in signing
    assert "packages/repository-state.json" in signing
    assert 'basename "${package}"' in signing
    assert "pkgname" in signing
    assert "pkgver" in signing
    assert "epoch:" in signing
    assert signing.index("Reject previously published package identity") < signing.index(
        "APK_REPOSITORY_PRIVATE_KEY"
    )
    assert signing.index("Reject previously published package identity") < signing.index(
        'printf \'%s\' "$APK_REPOSITORY_PRIVATE_KEY" > "$private_key_source"'
    )
    assert signing.index('melange sign --signing-key "$private_key" "$package"') < signing.index(
        ".github/scripts/assemble-apk-repository.sh"
    )
    assert signing.index("prepare-apk-signing-key.sh") < signing.index(
        'melange sign --signing-key "$private_key" "$package"'
    )
    assert "PRIVATE KEY" in signing
    assert "APK_REPOSITORY_PRIVATE_KEY" not in x86_64 + aarch64
    assert "scripts/test_fips_runtime.sh" not in signing
    assert "--platform" not in signing
    assert 'bash scripts/verify_apk_repository.sh "$work_dir/apk" packages/keys/verity-apk-2026.rsa.pub' in signing
    assert "apk --keys-dir" in repository_verify
    assert "--platform" not in repository_verify
    assert "/repository/x86_64/APKINDEX.tar.gz" in repository_verify
    assert "/repository/x86_64/openssl-fips-provider-*.apk" in repository_verify
    assert "/repository/aarch64/APKINDEX.tar.gz" in repository_verify
    assert "/repository/aarch64/openssl-fips-provider-*.apk" in repository_verify
    assert 'umask 077' in smoke_workflow
    assert 'private_key_source="$work_dir/verity-apk-2026.source.pem"' in smoke_workflow
    assert 'private_key="$work_dir/verity-apk-2026.rsa"' in smoke_workflow
    assert 'set +x' in smoke_workflow
    assert 'printf \'%s\' "$APK_REPOSITORY_PRIVATE_KEY" > "$private_key_source"' in smoke_workflow
    assert 'unset APK_REPOSITORY_PRIVATE_KEY' in smoke_workflow
    assert ".github/scripts/prepare-apk-signing-key.sh" in smoke_workflow
    assert smoke_workflow.index("prepare-apk-signing-key.sh") < smoke_workflow.index(
        'openssl dgst -sha256 -sign "$private_key"'
    )
    assert smoke_workflow.index('rm -f "$private_key"') < smoke_workflow.index(
        "scan_status=0"
    )
    assert RUNTIME_IMAGE in policy + runtime_test
    assert ":latest" not in policy + runtime_test


if __name__ == "__main__":
    main()
