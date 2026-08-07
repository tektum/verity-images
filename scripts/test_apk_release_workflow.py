#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_release_workflow.py

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
WORKFLOW: Final = ROOT / ".github/workflows/apk-repository.yaml"
SMOKE_WORKFLOW: Final = ROOT / ".github/workflows/apk-signing-smoke.yaml"
POLICY: Final = ROOT / "scripts/apk_repository_policy.py"
RUNTIME_TEST: Final = ROOT / "scripts/test_fips_runtime.sh"
REPOSITORY_VERIFY: Final = ROOT / "scripts/verify_apk_repository.sh"
RESERVER: Final = ROOT / ".github/scripts/reserve-apk-release-identity.sh"
PACKAGE_VERSION: Final = ROOT / ".github/scripts/apk-package-version.sh"
SIGNING_DOC: Final = ROOT / "docs/APK_REPOSITORY_SIGNING.md"
RUNTIME_IMAGE: Final = "cgr.dev/chainguard/wolfi-base@sha256:003627df3c1e1bba0c4116afcddb314aca9594ee2328c7e876a8081a6c988b2e"
RUNS_ON_PREFIX: Final = "runs-on=${{ github.run_id }}-${{ github.run_attempt }}-"


def job(text: str, name: str, next_name: str) -> str:
    start = f"  {name}:\n"
    end = f"\n  {next_name}:\n"
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def runner(job: str) -> str:
    line = next(line.strip() for line in job.splitlines() if line.startswith("    runs-on: "))
    return line.removeprefix("runs-on: ").split("  #", maxsplit=1)[0]


def package_version_tests() -> None:
    metadata = {
        "architecture": "x86_64",
        "identity": {"name": "gosu", "version": "1.19-r0"},
        "recipe": {"path": "packages/gosu/melange.yaml", "sha256": "0" * 64},
    }
    forgeries = (
        {"architecture": "aarch64"},
        {"identity": {"name": "openssl-fips-provider", "version": "1.19-r0"}},
        {"identity": {"name": "gosu", "version": "1.19"}},
        {"identity": {"name": "gosu", "version": "1.20-r0"}},
        {"recipe": {"path": "packages/other/melange.yaml", "sha256": "0" * 64}},
    )
    for forgery in (None, *forgeries):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for architecture in ("x86_64", "aarch64"):
                directory = root / f"apk-build-gosu-{architecture}"
                directory.mkdir()
                values = {**metadata, "architecture": architecture}
                if forgery is not None and architecture == "x86_64":
                    values |= forgery
                (directory / "metadata.json").write_text(json.dumps(values), encoding="utf-8")
            result = subprocess.run(
                ["bash", str(PACKAGE_VERSION), str(root), "gosu"],
                check=False,
                capture_output=True,
                text=True,
            )
            if forgery is None:
                assert result.returncode == 0 and result.stdout.strip() == "1.19-r0", result.stderr
            else:
                assert result.returncode != 0, forgery
    with tempfile.TemporaryDirectory() as temporary:
        result = subprocess.run(
            ["bash", str(PACKAGE_VERSION), temporary, "gosu"],
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0 and "missing build metadata" in result.stderr


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    smoke_workflow = SMOKE_WORKFLOW.read_text(encoding="utf-8")
    policy = POLICY.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
    repository_verify = REPOSITORY_VERIFY.read_text(encoding="utf-8")
    reserver = RESERVER.read_text(encoding="utf-8")
    signing_doc = SIGNING_DOC.read_text(encoding="utf-8")
    matrix = job(workflow, "apk-matrix", "build-x86_64")
    x86_64 = job(workflow, "build-x86_64", "build-aarch64")
    aarch64 = job(workflow, "build-aarch64", "apk-gate")
    gate = job(workflow, "apk-gate", "apk-signing")
    signing = workflow.split("  apk-signing:\n", maxsplit=1)[1]

    assert "  pull_request:\n" in workflow
    assert "  merge_group:\n    types: [checks_requested]\n" in workflow
    assert "    branches: [main]\n" in workflow
    assert "python3 scripts/gen_apk_matrix.py" in matrix
    assert "        options: [openssl-fips-provider, gosu]\n" in workflow
    assert "PACKAGE: ${{ inputs.package }}" in matrix
    assert '[[ -f "packages/${PACKAGE}/melange.yaml" ]]' in matrix
    assert 'select(.package == $package)' in matrix
    assert "openssl-fips-provider" not in matrix
    assert "for architecture in aarch64 x86_64" in matrix
    assert "aarch64: ${{ steps.matrix.outputs.aarch64 }}" in matrix
    assert "x86_64: ${{ steps.matrix.outputs.x86_64 }}" in matrix
    assert runner(matrix) == f"{RUNS_ON_PREFIX}apk-matrix/runner=4cpu-linux-x64"
    assert runner(x86_64) == (
        f"{RUNS_ON_PREFIX}build-x86_64-${{{{ strategy.job-index }}}}/runner=4cpu-linux-x64"
    )
    assert runner(aarch64) == (
        f"{RUNS_ON_PREFIX}build-aarch64-${{{{ strategy.job-index }}}}/runner=4cpu-linux-arm64"
    )
    assert 'ARCHITECTURE: x86_64' in x86_64
    assert 'ARCHITECTURE: aarch64' in aarch64
    assert "uname -m" not in x86_64 + aarch64
    assert "needs: [apk-matrix]" in x86_64 + aarch64
    assert "fromJSON(needs.apk-matrix.outputs.x86_64)" in x86_64
    assert "fromJSON(needs.apk-matrix.outputs.aarch64)" in aarch64
    assert 'bash scripts/build_apk_package.sh "${{ matrix.package }}" "$ARCHITECTURE"' in x86_64 + aarch64
    assert "apk-build-${{ matrix.package }}-x86_64" in x86_64
    assert "apk-build-${{ matrix.package }}-aarch64" in aarch64
    assert "environment:" not in x86_64 + aarch64
    assert "secrets." not in x86_64 + aarch64
    assert "retention-days: 7\n" in x86_64 + aarch64
    assert "actions/attest-build-provenance@" in x86_64 + aarch64

    assert "if: always()" in gate
    assert "needs: [build-x86_64, build-aarch64, apk-signing]" in gate
    assert runner(gate) == f"{RUNS_ON_PREFIX}apk-gate/runner=4cpu-linux-x64"
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
    for event, ref, repository, mode, build_result, signing_result, expected in (
        ("pull_request", "refs/pull/1/merge", "fork/example", "replacement", "success", "skipped", 0),
        ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1", "tektum/verity-images", "replacement", "success", "skipped", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "replacement", "success", "success", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "migration", "skipped", "success", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "replacement", "skipped", "success", 1),
        ("workflow_dispatch", "refs/heads/main", "fork/example", "replacement", "success", "skipped", 0),
        ("workflow_dispatch", "refs/heads/main", "tektum/verity-images", "replacement", "success", "skipped", 1),
        ("merge_group", "refs/heads/gh-readonly-queue/main/pr-1", "tektum/verity-images", "replacement", "success", "failure", 1),
    ):
        result = subprocess.run(
            ["bash", "-c", gate_script],
            check=False,
            capture_output=True,
            env={
                **os.environ,
                "AARCH64_RESULT": build_result,
                "EVENT": event,
                "MODE": mode,
                "REF": ref,
                "REPOSITORY": repository,
                "SIGNING_RESULT": signing_result,
                "X86_64_RESULT": build_result,
            },
        )
        assert result.returncode == expected

    assert "github.event_name == 'workflow_dispatch'" in signing
    assert "github.repository == 'tektum/verity-images'" in signing
    assert "github.ref == 'refs/heads/main'" in signing
    assert runner(signing) == f"{RUNS_ON_PREFIX}apk-signing/runner=4cpu-linux-x64/spot=false"
    assert runner(smoke_workflow) == (
        f"{RUNS_ON_PREFIX}sign-and-verify/runner=4cpu-linux-x64/spot=false"
    )
    assert "    if: github.ref == 'refs/heads/main'\n" in smoke_workflow
    assert "environment: apk-signing" in smoke_workflow
    assert "environment: apk-signing" in signing
    assert "attestations: write" in signing
    assert "id-token: write" in signing
    assert "GH_TOKEN: ${{ github.token }}" in signing
    assert "SOURCE_SHA: ${{ inputs.source-sha }}" in signing
    assert '[[ "$GITHUB_SHA" == "$SOURCE_SHA" ]]' in signing
    assert 'bash .github/scripts/validate-artifact-digest.sh artifact.json "$artifact_digest" "$GITHUB_RUN_ID"' in signing
    assert "gh attestation verify" in signing
    assert '--repo "$REPOSITORY"' in signing
    assert (
        '--signer-workflow "$REPOSITORY/.github/workflows/apk-repository.yaml"' in signing
    )
    assert "--source-digest \"$SOURCE_SHA\"" in signing
    assert "--deny-self-hosted-runners" not in signing
    assert "artifact-ids:" in signing
    assert "run-id:" not in signing
    assert signing.index("Validate source and artifacts") < signing.index("APK_REPOSITORY_PRIVATE_KEY")
    source_validation = signing.split("      - name: Validate source and artifacts\n", maxsplit=1)[1].split(
        "      - name: Download only current-run build artifacts\n", maxsplit=1
    )[0]
    assert "if: inputs.mode == 'replacement'" not in source_validation
    assert "MODE: ${{ inputs.mode }}" in source_validation
    assert 'if [[ "$MODE" == replacement ]]; then' in source_validation
    assert signing.index("Validate source and artifacts") < signing.index("Download only current-run build artifacts")
    assert "Reserve package identity" in signing
    assert ".github/scripts/reserve-apk-release-identity.sh reserve" in signing
    assert "packages/repository-state.json release/inputs.json" in signing
    assert 'type:"build-input"' in signing
    assert '--arg x86_artifact "sha256:$X86_64_ARTIFACT_DIGEST"' in signing
    assert '--arg arm_artifact "sha256:$AARCH64_ARTIFACT_DIGEST"' in signing
    assert "openssl-fips-provider" not in signing
    assert 'bash .github/scripts/apk-package-version.sh input "$PACKAGE"' in signing
    assert '[[ "$name" == "$PACKAGE" ]]' in signing
    assert '--arg name "$PACKAGE"' in signing
    assert signing.index("apk-package-version.sh") < signing.index("Reserve package identity")
    assert "gh_call release create" in reserver
    assert "gh_call api --paginate --slurp" in reserver
    assert "releases/assets/" in reserver
    assert "apk-release-reserved" in reserver
    assert "apk-release-complete" in reserver
    assert 'immutable == true' in reserver
    assert 'timeout "${GH_TIMEOUT_SECONDS:-30}" gh' in reserver
    assert 'git/matching-refs/tags/${release_tag}' in reserver
    assert 'gh_call api --method POST "repos/${repository}/git/refs"' in reserver
    assert 'gh_call release create "$release_tag" --repo "$repository"' in reserver
    assert "body=${body//$'\\r'/}" in reserver
    assert "gh release upload \"$RELEASE_TAG\" \"$ARCHIVE\"" in signing
    assert ".github/scripts/reserve-apk-release-identity.sh complete" in signing
    assert ".github/scripts/reserve-apk-release-identity.sh publish" in signing
    assert "release/reservation.json release/verity-apk-repository.tar.zst" in signing
    update_draft = signing.split("      - name: Update reserved draft release\n", maxsplit=1)[1]
    assert "REPOSITORY: ${{ github.repository }}" in update_draft.split("        run: |\n", maxsplit=1)[0]
    assert 'SOURCE_SHA: ${{ inputs.source-sha }}' in update_draft.split("        run: |\n", maxsplit=1)[0]
    assert signing.index("reserve-apk-release-identity.sh complete") < signing.index("gh release upload")
    assert signing.index("gh release upload") < signing.index("reserve-apk-release-identity.sh publish")
    assert "--draft=false" not in signing
    assert "gh release delete apk-repo-vNNNN --yes --cleanup-tag" in signing_doc
    assert "--clobber" not in signing
    reserve_function = reserver.split("reserve() {", maxsplit=1)[1].split("\n}\n\ncomplete()", maxsplit=1)[0]
    publish_function = reserver.split("publish() {", maxsplit=1)[1].split("\n}\n\nmode=", maxsplit=1)[0]
    assert reserve_function.index("scan_releases post-create") < reserve_function.rindex("verify_tag_absent")
    assert publish_function.index("scan_releases publish") < publish_function.index('ensure_live_tag "$source_sha"')
    assert publish_function.index('ensure_live_tag "$source_sha"') < publish_function.index("--draft=false")
    assert (
        "    concurrency:\n"
        "      group: apk-signing\n"
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
    assert 'melange sign --signing-key "$private_key" "$signed"' in signing
    assert "for package in input/*/*.apk" not in signing
    assert "done < <(jq -c '.unsignedPackages[]' release/reservation.json)" in signing
    assert "python3 scripts/compose_apk_inputs.py" in signing
    assert signing.index("Verify build digests and provenance") < signing.index("Reserve package identity")
    assert signing.index("Reserve package identity") < signing.index(
        "private_key=\"$work_dir/verity-apk-2026.rsa\""
    )
    assert signing.index("Reserve package identity") < signing.index(
        'printf \'%s\' "$APK_REPOSITORY_PRIVATE_KEY" > "$private_key_source"'
    )
    assert signing.index('melange sign --signing-key "$private_key" "$signed"') < signing.index(
        ".github/scripts/assemble-apk-repository.sh"
    )
    assert signing.index("prepare-apk-signing-key.sh") < signing.index(
        'melange sign --signing-key "$private_key" "$signed"'
    )
    assert "PRIVATE KEY" in signing
    assert "APK_REPOSITORY_PRIVATE_KEY" not in x86_64 + aarch64
    assert "scripts/test_fips_runtime.sh" not in signing
    assert "--platform" not in signing
    assert 'bash scripts/verify_apk_repository.sh "$work_dir/apk" packages/keys/verity-apk-2026.rsa.pub' in signing
    assert "apk --keys-dir" in repository_verify
    assert "--platform" not in repository_verify
    assert "/repository/x86_64/APKINDEX.tar.gz" in repository_verify
    assert "/repository/aarch64/APKINDEX.tar.gz" in repository_verify
    assert 'python3 - "$repository/manifest.json"' in repository_verify
    assert '"${packages[@]}"' in repository_verify
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

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        repository = root / "repository"
        repository.mkdir()
        (repository / "x86_64").mkdir()
        valid = repository / "x86_64" / "valid.apk"
        valid.write_bytes(b"valid")
        (repository / "manifest.json").write_text(
            json.dumps(
                {
                    "architectures": ["aarch64", "x86_64"],
                    "packages": [
                        {"architecture": "x86_64", "path": "x86_64/valid.apk", "sha256": "0" * 64},
                        {"architecture": "aarch64", "path": "../unsafe.apk", "sha256": "1" * 64},
                    ]
                }
            ),
            encoding="utf-8",
        )
        key = root / "key.pub"
        key.write_text("key", encoding="utf-8")
        binaries = root / "bin"
        binaries.mkdir()
        docker = binaries / "docker"
        docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        docker.chmod(0o755)
        result = subprocess.run(
            ["bash", str(REPOSITORY_VERIFY), str(repository), str(key)],
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}"},
        )
        assert result.returncode == 1 and "unsafe manifest path" in result.stderr

    package_version_tests()


if __name__ == "__main__":
    main()
