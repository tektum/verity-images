#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_workflow_policy.py

import shlex
import os
import subprocess
from dataclasses import replace
from pathlib import Path
from typing import Final
from unittest.mock import patch

import gen_matrix

ROOT: Final = Path(__file__).resolve().parents[1]
RUNS_ON_X64: Final = (
    "runs-on=${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/runner=4cpu-linux-x64"
)
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
INVENTORY_JQ_FILTER: Final = (
    "(.[0].images | map([.name, .version]) | sort) == "
    "(.[1].include | map([.name, .tag_version]) | sort)"
)
BOOTSTRAP_INVENTORY_COMMAND: Final = (
    "devbox",
    "run",
    "--",
    "jq",
    "-e",
    "--slurp",
    INVENTORY_JQ_FILTER,
    "input/report/build-report.json",
    "expected-images.json",
    ">/dev/null",
)
CATALOG_INVENTORY_COMMAND: Final = (
    "devbox",
    "run",
    "--",
    "jq",
    "-e",
    "--slurp",
    INVENTORY_JQ_FILTER,
    "catalog.json",
    "expected-images.json",
    ">/dev/null",
)


def between(text: str, start: str, end: str) -> str:
    assert text.count(start) == 1
    assert text.count(end) == 1
    return text.split(start, maxsplit=1)[1].split(end, maxsplit=1)[0]


def runner(job: str) -> str:
    line = next(line.strip() for line in job.splitlines() if line.startswith("    runs-on: "))
    return line.removeprefix("runs-on: ").split("  #", maxsplit=1)[0]


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
    sample_paths = {
        (sample["track"], sample["flavor"]): sample["context"]
        for sample in samples
    }
    actual_pairs = {
        (metadata.track, flavor)
        for directory in gen_matrix.image_directories()
        if (metadata := gen_matrix.parse_metadata(directory / "metadata.yaml")).enabled
        for flavor in metadata.flavors
    }
    assert len(samples) == len(sample_paths)
    assert sample_paths.keys() == actual_pairs
    assert gen_matrix.GLOBAL_SAMPLES.items() <= sample_paths.items()
    parse_metadata = gen_matrix.parse_metadata

    def unknown_flavor_metadata(path: Path) -> gen_matrix.Metadata:
        metadata = parse_metadata(path)
        if path.parent.relative_to(ROOT).as_posix() in {"images/static", "images/go/1.26"}:
            return replace(metadata, flavors=(*metadata.flavors, "unknown"))
        return metadata

    with (
        patch.object(gen_matrix, "parse_metadata", side_effect=unknown_flavor_metadata),
        patch.object(gen_matrix, "changed_paths", return_value={"scripts/build_candidate.sh"}),
    ):
        samples = gen_matrix.generate("base")["include"]
    assert [
        (sample["track"], sample["context"])
        for sample in samples
        if sample["flavor"] == "unknown"
    ] == [("wolfi", "images/go/1.26")]
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
        "    - name: Verify published signature and SPDX SBOM\n",
        "\n    - name: Attach build provenance\n",
    )
    assert verify_step.startswith("      if: inputs.publish == 'true'\n")
    assert verify_step.count("      run: |\n") == 1
    verify_script = verify_step.split("      run: |\n", maxsplit=1)[1]
    assert action.count("\n        cosign verify") == 2
    assert shell_commands(verify_script) == VERIFY_STEP_COMMANDS

    sign_step = between(
        action,
        "    - name: Sign digest and attach platform SPDX SBOMs\n",
        "\n    - name: Verify published signature and SPDX SBOM\n",
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
    catalog_policy = between(catalog, "permissions: {}\n", "\njobs:\n")
    assert catalog_policy == (
        "\nconcurrency:\n"
        "  group: catalog-pages\n"
        "  cancel-in-progress: false\n"
    )
    assert "\n  schedule:\n" not in workflow
    assert (
        "  GRYPE_VERSION: 0.116.1\n"
        "  GRYPE_SHA256: 0122df7b655981abe547ad3d2190d65551dac6a2bfc80b4dc2a989b5d0587458\n"
        in workflow
    )
    assert "  schedule:\n" not in monitor
    assert "  workflow_dispatch:\n" in monitor
    assert "      payload:\n" in monitor
    assert "        required: true\n" in monitor
    assert "      contents: read\n      issues: write\n" in monitor
    assert "scripts/monitor_sboms.sh squawk-payload.json\n" in monitor

    publish_job = between(workflow, "\n  publish:\n", "\n  build-gate:\n")
    matrix_job = between(workflow, "\n  matrix:\n", "\n  validate:\n")
    validate_job = between(workflow, "\n  validate:\n", "\n  publish:\n")
    build_gate_job = workflow.split("\n  build-gate:\n", maxsplit=1)[1]
    assert runner(matrix_job) == RUNS_ON_X64
    assert runner(validate_job) == (
        "runs-on=${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/"
        "family=c8i+m8i/cpu=16/ram=32/image=ubuntu24-full-x64/volume=100gb:gp3/"
        "extras=otel/spot=false"
    )
    assert runner(publish_job) == (
        "runs-on=${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/"
        "family=c8i+m8i/cpu=32/ram=64/image=ubuntu24-full-x64/volume=200gb:gp3/"
        "extras=otel/spot=false"
    )
    assert runner(build_gate_job) == RUNS_ON_X64
    assert runner(catalog) == RUNS_ON_X64
    assert runner(lint) == "ubuntu-latest"
    assert runner(monitor) == "ubuntu-latest"
    assert "\n    timeout-minutes: 120\n" in publish_job and "\n    timeout-minutes:" not in between(
        workflow, "\n  validate:\n", "\n  publish:\n"
    )
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
    download_catalog_step = between(
        catalog,
        "      - name: Download current catalog\n",
        "\n      - name: Generate catalog\n",
    )
    assert "https://tektum.github.io/verity-images/catalog.json" in catalog
    assert "check-jsonschema --schemafile docs/catalog.schema.json previous.json" in catalog
    assert catalog.index("scripts/gen_matrix.py --all > expected-images.json") < catalog.index(
        "      - name: Download current catalog\n"
    )
    assert "devbox --quiet run -- sh -c 'python3 scripts/gen_matrix.py --all > expected-images.json'" in catalog
    assert "for report in reports/report-*.json; do" in workflow
    assert "length == 1 and" in workflow
    assert "(.[0].name + \"-\" + .[0].version == $expected)" in workflow
    assert '$event == "pull_request"' in workflow
    assert ".[0].digest == \"local\"" in workflow
    assert "reports/report-*.json > build-report.json" in workflow
    assert (
        "github.ref != 'refs/heads/main' && "
        "fromJSON(needs.matrix.outputs.images).include[0] != null"
    ) in workflow

    build_gate_script = workflow.split("\n  build-gate:\n", maxsplit=1)[1].split(
        "\n\n      - name:", maxsplit=1
    )[0].split("        run: |\n", maxsplit=1)[1]
    for event, ref, images, validate, publish, expected in (
        ("pull_request", "refs/pull/1/merge", '{"include":[{}]}', "success", "failure", 0),
        (
            "merge_group",
            "refs/heads/gh-readonly-queue/main/pr-111-f4fd989828677e72f1bdfee557636db67af25f5f",
            '{"include":[{}]}',
            "success",
            "skipped",
            0,
        ),
        ("merge_group", "refs/heads/main", '{"include":[{}]}', "success", "skipped", 0),
        ("push", "refs/heads/main", '{"include":[{}]}', "success", "success", 0),
        ("workflow_dispatch", "refs/heads/main", '{"include":[{}]}', "skipped", "success", 0),
        ("pull_request", "refs/pull/1/merge", '{"include":[{}]}', "failure", "success", 1),
        ("push", "refs/heads/main", '{"include":[{}]}', "success", "failure", 1),
        ("push", "refs/heads/main", '{"include":[]}', "failure", "failure", 0),
    ):
        result = subprocess.run(
            ["bash", "-c", build_gate_script],
            check=False,
            capture_output=True,
            env={
                **os.environ,
                "EVENT": event,
                "GITHUB_REF": ref,
                "IMAGES": images,
                "MATRIX_RESULT": "success",
                "VALIDATE_RESULT": validate,
                "PUBLISH_RESULT": publish,
            },
        )
        assert result.returncode == expected

    assert (
        '          if [[ "$status" == 200 ]]; then\n'
        "            devbox run -- check-jsonschema --schemafile docs/catalog.schema.json previous.json\n"
        in download_catalog_step
    )
    assert '          elif [[ "$status" == 404 ]]; then\n' in download_catalog_step
    assert '"$SOURCE_EVENT" == workflow_dispatch' not in download_catalog_step
    assert download_catalog_step.count("        run: |\n") == 1
    download_catalog_script = download_catalog_step.split("        run: |\n", maxsplit=1)[1]
    assert BOOTSTRAP_INVENTORY_COMMAND in shell_commands(download_catalog_script)
    assert '"$(test -f previous.json && printf previous.json)" catalog.json' in catalog_step
    assert catalog_step.count("        run: |\n") == 1
    catalog_script = catalog_step.split("        run: |\n", maxsplit=1)[1]
    assert CATALOG_JQ_COMMAND in shell_commands(catalog_script)
    assert CATALOG_INVENTORY_COMMAND in shell_commands(catalog_script)


if __name__ == "__main__":
    main()
