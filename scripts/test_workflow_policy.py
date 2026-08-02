#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_workflow_policy.py

import shlex
from pathlib import Path
from typing import Final
from unittest.mock import patch

import gen_matrix

ROOT: Final = Path(__file__).resolve().parents[1]
IDENTITY_ASSIGNMENT: Final = (
    "identity=https://github.com/tektum/verity-images/.github/workflows/"
    "build.yaml@refs/heads/main"
)
ISSUER_ASSIGNMENT: Final = "issuer=https://token.actions.githubusercontent.com"
SIGNATURE_COMMAND: Final = (
    "cosign",
    "verify",
    "--certificate-identity",
    "$identity",
    "--certificate-oidc-issuer",
    "$issuer",
    "--certificate-github-workflow-sha",
    "$GITHUB_SHA",
    "${TARGET}@${DIGEST}",
    ">/dev/null",
)
ATTESTATION_COMMAND: Final = (
    "cosign",
    "verify-attestation",
    "--type",
    "spdxjson",
    "--certificate-identity",
    "$identity",
    "--certificate-oidc-issuer",
    "$issuer",
    "--certificate-github-workflow-sha",
    "$GITHUB_SHA",
    "${TARGET}@${DIGEST}",
    ">/dev/null",
)
CYCLONEDX_ATTESTATION_COMMAND: Final = (
    "cosign",
    "verify-attestation",
    "--type",
    "cyclonedx",
    "--certificate-identity",
    "$identity",
    "--certificate-oidc-issuer",
    "$issuer",
    "--certificate-github-workflow-sha",
    "$GITHUB_SHA",
    "${TARGET}@${DIGEST}",
    ">/dev/null",
)
VERIFY_STEP_COMMANDS: Final = (
    ("set", "-euo", "pipefail"),
    (IDENTITY_ASSIGNMENT,),
    (ISSUER_ASSIGNMENT,),
    SIGNATURE_COMMAND,
    ATTESTATION_COMMAND,
    CYCLONEDX_ATTESTATION_COMMAND,
)
CATALOG_JQ_FILTER: Final = (
    ".schemaVersion == 2 and (.images | length > 0) and "
    "all(.images[]; .scan.fixable == 0)"
)
CATALOG_JQ_COMMAND: Final = (
    "devbox",
    "run",
    "--",
    "jq",
    "-e",
    CATALOG_JQ_FILTER,
    "catalog.json",
    ">/dev/null",
)


def between(text: str, start: str, end: str) -> str:
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def shell_commands(script: str) -> tuple[tuple[str, ...], ...]:
    commands: list[str] = []
    command = ""
    for raw_line in script.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        command = f"{command} {line.removesuffix('\\')}".strip()
        if not line.endswith("\\"):
            commands.append(command)
            command = ""
    assert not command
    return tuple(
        tuple(shlex.split(command, comments=True, posix=True)) for command in commands
    )


def main() -> None:
    action = (ROOT / ".github/actions/publish-image/action.yaml").read_text(
        encoding="utf-8"
    )
    catalog = (ROOT / ".github/workflows/catalog.yaml").read_text(encoding="utf-8")
    monitor = (ROOT / ".github/workflows/monitor.yaml").read_text(encoding="utf-8")
    lint = (ROOT / ".github/workflows/lint.yaml").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/build.yaml").read_text(encoding="utf-8")

    assert ".github/workflows/build.yaml" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/gen_matrix.py" not in gen_matrix.GLOBAL_PATHS
    with patch.object(
        gen_matrix, "changed_paths", return_value={"scripts/build_candidate.sh"}
    ):
        samples = gen_matrix.generate("base")["include"]
    assert {
        (sample["track"], sample["flavor"], sample["context"])
        for sample in samples
    } == {
        ("wolfi", "plain", "images/static"),
        ("wolfi", "fips", "images/go/1.26"),
        ("patched", "plain", "patched/debian-12-slim"),
    }
    assert "  merge_group:\n    types: [checks_requested]\n" in lint
    assert (
        "          BASE_SHA: >-\n"
        "            ${{ github.event.pull_request.base.sha ||\n"
        "            github.event.merge_group.base_sha || github.event.before }}\n"
        in workflow
    )
    assert "          if [[ \"$EVENT\" == workflow_dispatch ]]; then\n" in workflow
    assert '            matrix=$(python3 scripts/gen_matrix.py --changed "$BASE_SHA")\n' in workflow

    verify_step = between(
        action,
        "    - name: Verify published signature and SBOMs\n",
        "\n    - name: Resolve platform digests\n",
    )
    assert verify_step.startswith("      if: inputs.publish == 'true'\n")
    assert verify_step.count("      run: |\n") == 1
    verify_script = verify_step.split("      run: |\n", maxsplit=1)[1]
    assert action.count("\n        cosign verify") == 3
    assert shell_commands(verify_script) == VERIFY_STEP_COMMANDS
    assert action.count(
        "uses: actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d  # v4.2.1"
    ) == 2
    assert action.count("create-storage-record: false") == 3
    assert "sbom-amd64.cyclonedx.json" in action
    assert "sbom-arm64.cyclonedx.json" in action
    assert "scripts/notify_squawk.sh" in action
    for removed in ("SQUAWK_URL", "SQUAWK_AUDIENCE", "DESCOPE_TOKEN_URL", "/v1/sboms"):
        assert removed not in action

    sign_step = between(
        action,
        "    - name: Sign digest and attach platform SPDX SBOMs\n",
        "\n    - name: Verify published signature and SBOMs\n",
    )
    assert (
        'scripts/attest_sboms.sh "$TARGET" "$DIGEST" "$SBOM_DIRECTORY"\n'
        in sign_step
    )

    workflow_policy = between(workflow, "permissions: {}\n", "\nenv:\n")
    assert workflow_policy == (
        "\nconcurrency:\n"
        "  group: build-images-${{ github.ref }}\n"
        "  cancel-in-progress: false\n"
    )
    assert "\n  schedule:\n" not in workflow
    assert "  schedule:\n" not in monitor
    assert "  workflow_dispatch:\n" in monitor
    assert "      contents: read\n      issues: write\n" in monitor
    assert 'scripts/monitor_sboms.sh --squawk-payload squawk-payload.json\n' in monitor

    publish_job = between(workflow, "\n  publish:\n", "\n  build-gate:\n")
    assert "\n    timeout-minutes: 60\n" in publish_job
    assert (
        "    permissions:\n"
        "      attestations: write\n"
        "      contents: read\n"
        "      deployments: write\n"
        "      id-token: write\n"
        "      packages: write\n"
    ) in publish_job
    assert (
        "\n    concurrency:\n"
        "      group: publish-${{ matrix.owner }}-${{ matrix.name }}-${{ matrix.tag_version }}-${{ matrix.flavor }}\n"
        "      cancel-in-progress: false\n"
    ) in publish_job

    catalog_step = between(
        catalog,
        "      - name: Generate catalog\n",
        "\n      - name: Upload catalog data\n",
    )
    assert catalog_step.count("        run: |\n") == 1
    catalog_script = catalog_step.split("        run: |\n", maxsplit=1)[1]
    assert CATALOG_JQ_COMMAND in shell_commands(catalog_script)


if __name__ == "__main__":
    main()
