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
RUNS_ON_PREFIX: Final = "runs-on=${{ github.run_id }}-${{ github.run_attempt }}-"
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
FULL_INVENTORY_JQ_FILTER: Final = (
    "(.[0].images | map([.name, .version]) | sort) == "
    "(.[1].include | map([.name, .tag_version]) | sort)"
)
BOOTSTRAP_INVENTORY_COMMAND: Final = (
    "devbox", "run", "--", "jq", "-e", "--slurp", FULL_INVENTORY_JQ_FILTER,
    "input/report/build-report.json", "expected-images.json", ">/dev/null",
)
CATALOG_INVENTORY_COMMAND: Final = (
    "devbox", "run", "--", "jq", "-e", "--slurp", "--from-file", "scripts/catalog_inventory.jq",
    "catalog.json", "expected-images.json", ">/dev/null",
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

    assert ".github/workflows/build.yaml" in gen_matrix.GLOBAL_PATHS
    assert "scripts/gen_matrix.py" not in gen_matrix.GLOBAL_PATHS
    assert not (ROOT / "pipelines/go/bump.yaml").exists()
    assert not [
        path
        for root in ("images", "patched")
        for path in (ROOT / root).glob("**/*melange.yaml")
        if "uses: go/bump" in path.read_text(encoding="utf-8")
    ]
    assert gen_matrix.GO_REMEDIATE_PATHS == {
        "pipelines/go/remediate.yaml",
        "scripts/build_candidate.sh",
    }
    assert gen_matrix.COREPACK_INSTALL_PATHS == {
        "pipelines/corepack/install.yaml",
        "scripts/build_candidate.sh",
    }
    assert gen_matrix.CARGO_REMEDIATE_PATHS == {
        "pipelines/cargo/remediate.yaml",
        "scripts/build_candidate.sh",
    }

    image_catalog = [
        (directory, gen_matrix.parse_metadata(directory / "metadata.yaml"))
        for directory in gen_matrix.image_directories()
    ]

    fixed_pipeline_policies = (
        (gen_matrix.GO_REMEDIATE_PATHS, gen_matrix.GO_REMEDIATE_SAMPLE),
        (gen_matrix.COREPACK_INSTALL_PATHS, gen_matrix.COREPACK_INSTALL_SAMPLE),
    )
    fixed_shared_samples = {
        configured_sample for _, configured_sample in fixed_pipeline_policies
    }
    enabled_catalog = [
        (directory, metadata)
        for directory, metadata in image_catalog
        if metadata.enabled
    ]
    enabled_metadata = {
        directory.relative_to(ROOT).as_posix(): metadata
        for directory, metadata in enabled_catalog
    }

    def variants_for(context: str) -> set[tuple[str, str]]:
        assert context in enabled_metadata
        return {(context, flavor) for flavor in enabled_metadata[context].flavors}

    def global_shared_variants() -> set[tuple[str, str]]:
        samples = {
            (metadata.track, flavor): gen_matrix.GLOBAL_SAMPLES.get(
                (metadata.track, flavor)
            )
            or min(
                candidate.relative_to(ROOT).as_posix()
                for candidate, candidate_metadata in enabled_catalog
                if candidate_metadata.track == metadata.track
                and flavor in candidate_metadata.flavors
            )
            for _, metadata in enabled_catalog
            for flavor in metadata.flavors
        }
        return {
            (context, flavor) for (_, flavor), context in samples.items()
        }

    def shared_policy_contributions(
        changed_path: str,
    ) -> list[set[tuple[str, str]]]:
        contributions: list[set[tuple[str, str]]] = []
        if changed_path in gen_matrix.GLOBAL_PATHS:
            contributions.append(global_shared_variants())
        if changed_path in gen_matrix.OPENSSL_FIPS_PATHS:
            contributions.append(
                {
                    (directory.relative_to(ROOT).as_posix(), flavor)
                    for directory, metadata in enabled_catalog
                    if metadata.track == "wolfi"
                    for flavor in metadata.flavors
                    if gen_matrix.uses_openssl_fips_provider(directory, flavor)
                }
            )
        for paths, configured_sample in fixed_pipeline_policies:
            if changed_path in paths:
                contributions.append(variants_for(configured_sample))
        if changed_path in gen_matrix.CARGO_REMEDIATE_PATHS:
            cargo_sample = min(
                (
                    directory.relative_to(ROOT).as_posix()
                    for directory, _ in enabled_catalog
                    if gen_matrix.uses_cargo_remediate(directory)
                ),
                default="",
            )
            contributions.append(variants_for(cargo_sample) if cargo_sample else set())
        return contributions

    def expected_shared_variants(changed_path: str) -> set[tuple[str, str]]:
        return set().union(*shared_policy_contributions(changed_path))

    def assert_shared_matrix(changed_path: str) -> list[tuple[str, str]]:
        with patch.object(gen_matrix, "changed_paths", return_value={changed_path}):
            entries = gen_matrix.generate("base")["include"]
        actual = [(entry["context"], entry["flavor"]) for entry in entries]
        assert len(actual) == len(set(actual))
        assert set(actual) == expected_shared_variants(changed_path)
        return actual

    shared_paths = set().union(
        gen_matrix.GLOBAL_PATHS,
        gen_matrix.OPENSSL_FIPS_PATHS,
        gen_matrix.CARGO_REMEDIATE_PATHS,
        *(paths for paths, _ in fixed_pipeline_policies),
    )
    for changed_path in shared_paths:
        assert_shared_matrix(changed_path)

    consumer_variants = [
        (directory, flavor)
        for directory in gen_matrix.image_directories()
        if gen_matrix.uses_go_remediate(directory)
        for flavor in gen_matrix.parse_metadata(directory / "metadata.yaml").flavors
    ]
    fingerprints = {
        variant: gen_matrix.input_digest(*variant)
        for variant in consumer_variants
    }
    pipeline = ROOT / "pipelines/go/remediate.yaml"
    read_bytes = Path.read_bytes

    def changed_pipeline(path: Path) -> bytes:
        content = read_bytes(path)
        return content + b"\n" if path == pipeline else content

    with patch.object(Path, "read_bytes", changed_pipeline):
        assert all(
            gen_matrix.input_digest(*variant) != fingerprints[variant]
            for variant in consumer_variants
        )

    cargo_pipeline = ROOT / "pipelines/cargo/remediate.yaml"
    assert cargo_pipeline.is_file()

    def changed_cargo_pipeline(path: Path) -> bytes:
        content = read_bytes(path)
        return content + b"\n" if path == cargo_pipeline else content

    multi_flavor_candidates = sorted(
        (
            (directory, metadata)
            for directory, metadata in enabled_catalog
            if len(metadata.flavors) > 1
            and directory.relative_to(ROOT).as_posix() not in fixed_shared_samples
        ),
        key=lambda item: item[0].relative_to(ROOT).as_posix(),
    )
    assert len(multi_flavor_candidates) >= 2
    cargo_catalog = multi_flavor_candidates[:2]
    cargo_consumers = tuple(directory for directory, _ in cargo_catalog)
    cargo_candidate_paths = tuple(
        directory.relative_to(ROOT).as_posix() for directory in cargo_consumers
    )
    unrelated, unrelated_metadata = next(
        (directory, metadata)
        for directory, metadata in enabled_catalog
        if directory not in cargo_consumers
        and directory.relative_to(ROOT).as_posix() not in fixed_shared_samples
    )
    unrelated_path = unrelated.relative_to(ROOT).as_posix()
    assert cargo_candidate_paths[0] < cargo_candidate_paths[1]

    for active_consumers in ((), cargo_consumers[:1], cargo_consumers):
        active_consumer_set = set(active_consumers)
        active_paths = {
            directory.relative_to(ROOT).as_posix() for directory in active_consumers
        }
        expected_cargo = variants_for(min(active_paths)) if active_paths else set()
        with patch.object(
            gen_matrix,
            "uses_cargo_remediate",
            side_effect=lambda directory: directory in active_consumer_set,
        ):
            for changed_path in gen_matrix.CARGO_REMEDIATE_PATHS:
                selected = set(assert_shared_matrix(changed_path))
                cargo_candidate_variants = set().union(
                    *(variants_for(path) for path in cargo_candidate_paths)
                )
                assert selected & cargo_candidate_variants == expected_cargo
                assert not selected & variants_for(unrelated_path)

    cargo_consumer_set = set(cargo_consumers)
    with patch.object(
        gen_matrix,
        "uses_cargo_remediate",
        side_effect=lambda directory: directory in cargo_consumer_set,
    ):
        cargo_only = set(assert_shared_matrix("pipelines/cargo/remediate.yaml"))
        max_sample_mutation = variants_for(max(cargo_candidate_paths))
        assert cargo_only != max_sample_mutation

        go_cargo_path = "pipelines/go/remediate.yaml"
        with patch.object(
            gen_matrix,
            "CARGO_REMEDIATE_PATHS",
            gen_matrix.CARGO_REMEDIATE_PATHS | {go_cargo_path},
        ):
            contributions = shared_policy_contributions(go_cargo_path)
            selected = set(assert_shared_matrix(go_cargo_path))
            assert len(contributions) == 2
            for omitted in range(len(contributions)):
                without_one = set().union(
                    *(contribution for index, contribution in enumerate(contributions) if index != omitted)
                )
                assert selected != without_one

        build_candidate_contributions = shared_policy_contributions(
            "scripts/build_candidate.sh"
        )
        build_candidate_variants = set(
            assert_shared_matrix("scripts/build_candidate.sh")
        )
        assert len(build_candidate_contributions) == 3
        for omitted in range(len(build_candidate_contributions)):
            without_one = set().union(
                *(
                    contribution
                    for index, contribution in enumerate(build_candidate_contributions)
                    if index != omitted
                )
            )
            assert build_candidate_variants != without_one

    go_cargo_path = "pipelines/go/remediate.yaml"
    overlapping_consumer = ROOT / gen_matrix.GO_REMEDIATE_SAMPLE
    with (
        patch.object(
            gen_matrix,
            "CARGO_REMEDIATE_PATHS",
            gen_matrix.CARGO_REMEDIATE_PATHS | {go_cargo_path},
        ),
        patch.object(
            gen_matrix,
            "uses_cargo_remediate",
            side_effect=lambda directory: directory == overlapping_consumer,
        ),
    ):
        overlapping = assert_shared_matrix(go_cargo_path)
    for variant in variants_for(gen_matrix.GO_REMEDIATE_SAMPLE):
        assert overlapping.count(variant) == 1
    cargo_consumer_set = set(cargo_consumers)
    with patch.object(
        gen_matrix,
        "uses_cargo_remediate",
        side_effect=lambda directory: directory in cargo_consumer_set,
    ):
        consumer_variants = [
            (directory, flavor)
            for directory, metadata in cargo_catalog
            for flavor in metadata.flavors
        ]
        consumer_fingerprints = {
            variant: gen_matrix.input_digest(*variant) for variant in consumer_variants
        }
        unrelated_variants = [
            (unrelated, flavor) for flavor in unrelated_metadata.flavors
        ]
        unrelated_fingerprints = {
            variant: gen_matrix.input_digest(*variant) for variant in unrelated_variants
        }
        with patch.object(Path, "read_bytes", changed_cargo_pipeline):
            assert all(
                gen_matrix.input_digest(*variant) != consumer_fingerprints[variant]
                for variant in consumer_variants
            )
            assert all(
                gen_matrix.input_digest(*variant) == unrelated_fingerprints[variant]
                for variant in unrelated_variants
            )
    with patch.object(
        gen_matrix, "changed_paths", return_value={".github/workflows/build.yaml"}
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
    all_variants = [
        (directory, flavor)
        for directory in gen_matrix.image_directories()
        if (metadata := gen_matrix.parse_metadata(directory / "metadata.yaml")).enabled
        for flavor in metadata.flavors
    ]
    assert len(samples) < len(all_variants)
    parse_metadata = gen_matrix.parse_metadata

    def unknown_flavor_metadata(path: Path) -> gen_matrix.Metadata:
        metadata = parse_metadata(path)
        if path.parent.relative_to(ROOT).as_posix() in {"images/static", "images/go/1.26"}:
            return replace(metadata, flavors=(*metadata.flavors, "unknown"))
        return metadata

    with (
        patch.object(gen_matrix, "parse_metadata", side_effect=unknown_flavor_metadata),
        patch.object(gen_matrix, "changed_paths", return_value={".github/workflows/build.yaml"}),
    ):
        samples = gen_matrix.generate("base")["include"]
    assert [
        (sample["track"], sample["context"])
        for sample in samples
        if sample["flavor"] == "unknown"
    ] == [("wolfi", "images/go/1.26")]
    assert "  merge_group:\n    types: [checks_requested]\n" in lint
    assert (
        "      base-sha:\n"
        "        description: Trusted base commit SHA for changed-image recovery\n"
        "        required: false\n"
        "        type: string\n"
        in workflow
    )
    assert (
        "          BASE_SHA: >-\n"
        "            ${{ inputs['base-sha'] || github.event.pull_request.base.sha ||\n"
        "            github.event.merge_group.base_sha || github.event.before }}\n"
        in workflow
    )
    assert '          if [[ "$EVENT" == workflow_dispatch && -f catalog.json ]]; then\n' in workflow
    assert "scripts/gen_matrix.py --all --catalog catalog.json --max-age-hours 24" in workflow
    assert '          elif [[ "$EVENT" == workflow_dispatch && -z "$BASE_SHA" ]]; then\n' in workflow
    assert "            matrix=$(python3 scripts/gen_matrix.py --all)\n" in workflow
    assert '            matrix=$(python3 scripts/gen_matrix.py --changed "$BASE_SHA")\n' in workflow
    # A version-authority change moves a published identity, so main rebuilds any
    # identity the published catalog does not carry yet.
    assert '          elif [[ "$REF" == refs/heads/main && -f catalog.json ]]; then\n' in workflow
    assert (
        '            matrix=$(python3 scripts/gen_matrix.py --changed "$BASE_SHA" --published catalog.json)\n'
        in workflow
    )
    assert "        if: github.event_name == 'workflow_dispatch' || github.ref == 'refs/heads/main'\n" in workflow
    assert ") || status=000\n" in workflow

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
    # Every delivery has its own immutable id and issue reconciliation. A global
    # concurrency group keeps only one pending run, so burst dispatches silently cancel
    # findings even when cancel-in-progress is false.
    assert "\nconcurrency:\n" not in monitor

    publish_job = between(workflow, "\n  publish:\n", "\n  build-gate:\n")
    matrix_job = between(workflow, "\n  matrix:\n", "\n  validate:\n")
    validate_job = between(workflow, "\n  validate:\n", "\n  stall-guard:\n")
    stall_guard_job = between(workflow, "\n  stall-guard:\n", "\n  publish:\n")
    build_gate_job = between(workflow, "\n  build-gate:\n", "\n  catalog-catch-up:\n")
    catalog_catch_up_job = workflow.split("\n  catalog-catch-up:\n", maxsplit=1)[1]
    deploy_job = catalog.split("\n  deploy:\n", maxsplit=1)[1]
    assert runner(matrix_job) == "ubuntu-latest"
    assert runner(validate_job) == (
        f"{RUNS_ON_PREFIX}validate-${{{{ strategy.job-index }}}}/"
        "family=c8i.*/cpu=32/ram=64/image=ubuntu24-full-x64/volume=100gb:gp3/"
        "extras=otel/spot=false"
    )
    assert runner(stall_guard_job) == "ubuntu-latest"
    assert runner(publish_job) == (
        f"{RUNS_ON_PREFIX}publish-${{{{ strategy.job-index }}}}/"
        "family=c8i+m8i/cpu=32/ram=64/image=ubuntu24-full-x64/volume=200gb:gp3/"
        "extras=otel/spot=false"
    )
    assert runner(build_gate_job) == "ubuntu-latest"
    assert runner(catalog_catch_up_job) == "ubuntu-latest"
    assert runner(catalog) == f"{RUNS_ON_PREFIX}catalog/runner=4cpu-linux-x64"
    assert runner(deploy_job) == f"{RUNS_ON_PREFIX}deploy/runner=4cpu-linux-x64"
    assert runner(lint) == f"{RUNS_ON_PREFIX}lint/runner=4cpu-linux-x64"
    assert runner(monitor) == f"{RUNS_ON_PREFIX}monitor/runner=4cpu-linux-x64"
    assert "\n    timeout-minutes: 300\n" in publish_job and "\n    timeout-minutes:" not in validate_job

    assert "needs: matrix\n" in stall_guard_job
    assert (
        "\n    permissions:\n"
        "      actions: write\n"
        "      contents: read\n"
        in stall_guard_job
    )
    assert "\n    timeout-minutes: 50\n" in stall_guard_job
    assert "github.event_name != 'merge_group' &&" in stall_guard_job
    assert "fromJSON(needs.matrix.outputs.images).include[0] != null" in stall_guard_job
    guard_script = stall_guard_job.split("        run: |\n", maxsplit=1)[1]
    assert 'scripts/cancel_stalled_jobs.sh || status=$?\n' in guard_script
    assert '[[ "$status" -eq 0 ]] && break\n' in guard_script
    assert '[[ "$status" -eq 42 ]] || exit "$status"\n' in guard_script

    assert (
        "    if: >-\n"
        "      always() && github.event_name == 'push' && github.ref == 'refs/heads/main' &&\n"
        "      needs.build-gate.result == 'failure'\n"
        "    needs: build-gate\n"
        in catalog_catch_up_job
    )
    assert (
        "\n    permissions:\n"
        "      actions: write\n"
        "      contents: read\n"
        in catalog_catch_up_job
    )
    assert "          fetch-depth: 0\n" in catalog_catch_up_job
    assert "scripts/dispatch_catalog_catchup.sh\n" in catalog_catch_up_job
    assert (
        "\n    concurrency:\n"
        "      group: publish-${{ matrix.owner }}-${{ matrix.name }}-${{ matrix.tag_version }}-${{ matrix.flavor }}\n"
        "      cancel-in-progress: false\n"
    ) in publish_job

    assert (
        "    if: >-\n"
        "      github.ref == 'refs/heads/main' &&\n"
        "      (github.event_name == 'push' ||\n"
        "      github.event_name == 'workflow_dispatch' ||\n"
        "      (github.event_name == 'workflow_run' && github.event.workflow_run.head_branch == 'main')\n"
        "      )\n"
        in catalog
    )
    assert "github.event.workflow_run.conclusion" not in catalog
    source_step = between(
        catalog,
        "      - name: Select source run\n",
        "\n      - name: Stage site assets\n",
    )
    assert 'conclusion=$(jq -r .conclusion <<<"$metadata")\n' in source_step
    assert '"$conclusion" != success && "$conclusion" != failure && "$conclusion" != cancelled' in source_step
    assert 'Run %s (id %s) is not terminal; catalog unchanged.' in source_step
    assert 'select(.name == "build-report" and .expired == false)' in catalog

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
    assert "      - name: Check out source revision\n" not in catalog
    assert catalog.index("      - name: Select source run\n") < catalog.index(
        "      - name: Check source artifacts\n"
    ) < catalog.index("      - name: Generate expected images\n")
    assert 'git merge-base --is-ancestor "$source_sha" HEAD' in source_step
    assert catalog.index("scripts/gen_matrix.py --all > expected-images.json") < catalog.index(
        "      - name: Download current catalog\n"
    )
    assert "devbox --quiet run -- sh -c 'python3 scripts/gen_matrix.py --all > expected-images.json'" in catalog
    assert "for report in reports/report-*.json; do" in workflow
    assert "length == 1 and" in workflow
    assert "(.[0].name + \"-\" + .[0].version == $expected)" in workflow
    assert '$event == "pull_request"' in workflow
    assert ".[0].digest == \"local\"" in workflow
    assert '"inputDigest", "name", "runId", "runUrl", "scan", "sourceCommit"' in workflow
    assert 'hashFiles(\'reports/report-*.json\') != \'\'' in build_gate_job
    assert 'hashFiles(\'build-report.json\') != \'\'' in build_gate_job
    assert "reports/report-*.json > build-report.json" in workflow
    assert (
        "      github.event_name != 'merge_group' &&\n"
        "      github.ref != 'refs/heads/main' &&\n"
        "      fromJSON(needs.matrix.outputs.images).include[0] != null\n"
    ) in validate_job
    assert build_gate_job.count("github.event_name != 'merge_group'") == 3
    assert build_gate_job.count("fromJSON(needs.matrix.outputs.images).include[0] != null") == 3

    build_gate_script = workflow.split("\n  build-gate:\n", maxsplit=1)[1].split(
        "\n\n      - name:", maxsplit=1
    )[0].split("        run: |\n", maxsplit=1)[1]
    for event, ref, images, validate, publish, expected in (
        ("pull_request", "refs/pull/1/merge", '{"include":[{}]}', "success", "failure", 0),
        (
            "merge_group",
            "refs/heads/gh-readonly-queue/main/pr-111-f4fd989828677e72f1bdfee557636db67af25f5f",
            '{"include":[{}]}',
            "skipped",
            "skipped",
            0,
        ),
        ("merge_group", "refs/heads/main", '{"include":[{}]}', "success", "skipped", 1),
        ("push", "refs/heads/main", '{"include":[{}]}', "success", "success", 0),
        ("workflow_dispatch", "refs/heads/main", '{"include":[{}]}', "skipped", "success", 0),
        ("pull_request", "refs/pull/1/merge", '{"include":[{}]}', "failure", "success", 1),
        ("push", "refs/heads/main", '{"include":[{}]}', "success", "failure", 0),
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
    assert "${{ steps.source.outputs." not in catalog_script
    for variable in ("PUBLISHED_AT", "RUN_ID", "RUN_URL", "SOURCE_SHA"):
        assert f'"${variable}"' in catalog_script
    inventory_filter = (ROOT / "scripts/catalog_inventory.jq").read_text(encoding="utf-8")
    assert "cat > inventory-filter.jq <<'EOF'" not in catalog
    assert "(.[1].include | map([.name, .tag_version])) as $expected" in inventory_filter
    # A superseded identity may only remain while no expected version of the same
    # image has been published, so an authority change cannot prune a live entry.
    assert "($expected | any(.[0] == $image.name))" in inventory_filter
    assert CATALOG_INVENTORY_COMMAND in shell_commands(catalog_script)


if __name__ == "__main__":
    main()
