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
VERIFY_STEP_COMMANDS: Final = (
    ("set", "-euo", "pipefail"),
    (IDENTITY_ASSIGNMENT,),
    (ISSUER_ASSIGNMENT,),
    SIGNATURE_COMMAND,
    ATTESTATION_COMMAND,
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
    workflow = (ROOT / ".github/workflows/build.yaml").read_text(encoding="utf-8")

    verify_step = between(
        action,
        "    - name: Verify published signature and SPDX SBOM\n",
        "\n    - name: Attach build provenance\n",
    )
    assert verify_step.startswith("      if: inputs.publish == 'true'\n")
    assert verify_step.count("      run: |\n") == 1
    verify_script = verify_step.split("      run: |\n", maxsplit=1)[1]
    assert action.count("\n        cosign verify") == 2
    assert shell_commands(verify_script) == VERIFY_STEP_COMMANDS

    workflow_policy = between(workflow, "permissions: {}\n", "\nenv:\n")
    assert workflow_policy == (
        "\nconcurrency:\n"
        "  group: build-images-${{ github.ref }}\n"
        "  cancel-in-progress: false\n"
    )

    publish_job = between(workflow, "\n  publish:\n", "\n  build-gate:\n")
    assert "\n    timeout-minutes: 60\n" in publish_job
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
