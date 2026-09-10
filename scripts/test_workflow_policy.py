#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_workflow_policy.py

import json
import os
import shlex
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
    "catalog.json", "expected-images.json", ">/dev/null",
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

def reconciliation_plan(
    runs: list[dict[str, object]],
    ledger: dict[str, int],
    forced: dict[str, object] | None = None,
) -> dict[str, object]:
    result = subprocess.run(
        [
            "jq",
            "--argjson",
            "ledger",
            json.dumps(ledger),
            "--argjson",
            "forced",
            json.dumps(forced),
            "--from-file",
            str(ROOT / "scripts/catalog_reconciliation.jq"),
        ],
        check=True,
        capture_output=True,
        input=json.dumps(runs),
        text=True,
    )
    plan: dict[str, object] = json.loads(result.stdout)
    return plan


def env_pins(workflow: str) -> dict[str, str]:
    return dict(
        line.strip().split(": ", maxsplit=1)
        for line in between(workflow, "\nenv:\n", "\njobs:\n").splitlines()
        if line.startswith("  ") and ": " in line
    )


def check_lock_refresh_policy(build: str) -> None:
    refresh = (ROOT / ".github/workflows/apko-lock-refresh.yaml").read_text(encoding="utf-8")
    triggers = between(refresh, "\non:\n", "\npermissions: {}\n")
    # Manual exact-image only: monitoring findings, not package novelty, drive refreshes.
    assert "  schedule:\n" not in triggers
    assert "  workflow_dispatch:\n" in triggers
    assert "      image:\n" in triggers
    assert "        required: true\n" in triggers
    assert "pull_request" not in refresh and "workflow_run" not in refresh
    assert "\n  push:\n" not in refresh

    assert between(refresh, "permissions: {}\n", "\nenv:\n").endswith(
        "\nconcurrency:\n  group: apko-lock-refresh\n  cancel-in-progress: false\n"
    )
    job = refresh.split("\n  refresh:\n", maxsplit=1)[1]
    assert runner(job) == "ubuntu-latest"
    assert "\n    timeout-minutes: 60\n" in job
    assert "\n    permissions:\n      contents: read\n    steps:\n" in job
    assert (
        "    if: github.repository == 'tektum/verity-images' && github.ref == 'refs/heads/main'\n"
    ) in job
    assert "persist-credentials: false\n" in job
    # The pinned toolchain has one source of truth, so a build.yaml bump cannot drift.
    pins = env_pins(refresh)
    assert set(pins) == {
        "APKO_VERSION",
        "APKO_SHA256",
        "MELANGE_VERSION",
        "MELANGE_SHA256",
        "GRYPE_VERSION",
        "GRYPE_SHA256",
        "SYFT_VERSION",
        "SYFT_SHA256",
    }
    assert all(env_pins(build)[name] == value for name, value in pins.items())
    assert "scripts/install_image_tools.sh wolfi\n" in job
    # Untrusted-looking input reaches the shell only through the environment.
    assert "          IMAGE: ${{ inputs.image }}\n" in job
    assert 'python3 scripts/gen_apko_lock_targets.py --image "$IMAGE"' in job
    assert "gen_apko_lock_targets.py --all" not in job
    assert 'if [[ -n "$IMAGE" ]]' not in job

    assert "scripts/refresh_apko_locks.sh apko-lock-targets.json\n" in job
    # Only an operator credential may propose a pull request that starts the required checks.
    assert "          GH_TOKEN: ${{ secrets.APKO_LOCK_REFRESH_TOKEN }}\n" in job
    assert "github.token" not in refresh
    # Refresh automation is not an image build input, so it never rebuilds sample images.
    assert ".github/workflows/apko-lock-refresh.yaml" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/refresh_apko_locks.sh" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/gen_apko_lock_targets.py" not in gen_matrix.GLOBAL_PATHS


def main() -> None:
    action = (ROOT / ".github/actions/publish-image/action.yaml").read_text(
        encoding="utf-8"
    )
    assert action.count(
        "          ${{ inputs.build-directory }}/apko-sbom/*.spdx.json\n"
    ) == 1
    catalog = (ROOT / ".github/workflows/catalog.yaml").read_text(encoding="utf-8")
    monitor = (ROOT / ".github/workflows/monitor.yaml").read_text(encoding="utf-8")
    monitor_script = (ROOT / "scripts/monitor_sboms.sh").read_text(encoding="utf-8")
    monitor_sarif = (ROOT / "scripts/build_monitor_sarif.py").read_text(
        encoding="utf-8"
    )
    dashboard_script = (ROOT / "scripts/build_image_dashboard.py").read_text(
        encoding="utf-8"
    )

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
        if changed_path in gen_matrix.APK_REPOSITORY_PATHS:
            contributions.append(
                {
                    (directory.relative_to(ROOT).as_posix(), flavor)
                    for directory, metadata in enabled_catalog
                    if metadata.track == "wolfi"
                    for flavor in metadata.flavors
                    if gen_matrix.uses_apk_repository(directory, flavor)
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
        gen_matrix.APK_REPOSITORY_PATHS,
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
        "      image:\n"
        "        description: Exact vulnerable image stream as NAME@VERSION\n"
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
    assert "          IMAGE: ${{ inputs.image }}\n" in workflow
    assert '          if [[ "$EVENT" == workflow_dispatch && -n "$IMAGE" ]]; then\n' in workflow
    assert '            [[ -z "$BASE_SHA" ]] || {\n' in workflow
    assert '            args=(--remediate "$IMAGE")\n' in workflow
    assert '            [[ ! -f catalog.json ]] || args+=(--catalog catalog.json --max-age-hours 24)\n' in workflow
    assert '            matrix=$(python3 scripts/gen_matrix.py "${args[@]}")\n' in workflow
    assert '          elif [[ "$EVENT" == workflow_dispatch && -f catalog.json ]]; then\n' in workflow
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

    # github.event.inputs (not the bare inputs context) is required here:
    # inputs is unavailable in a top-level workflow concurrency expression.
    # Every exact-image dispatch gets its own group so GitHub's one-pending-
    # run-per-group limit can never let one dispatched stream silently evict
    # another's queued rebuild; push/pull_request/merge_group/base-sha
    # catch-up runs keep sharing the original single group unchanged.
    workflow_policy = between(workflow, "permissions: {}\n", "\nenv:\n")
    assert workflow_policy == (
        "\nconcurrency:\n"
        "  group: >-\n"
        "    build-images-${{ github.ref }}${{ github.event.inputs.image &&\n"
        "    format('-{0}', github.event.inputs.image) || '' }}\n"
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
    monitor_triggers = between(monitor, "\non:\n", "\npermissions: {}\n")
    # Monitoring is scheduled or operator-started, never driven by an external payload.
    assert '  schedule:\n    - cron: "17 3 * * *"\n' in monitor_triggers
    assert "  workflow_dispatch:\n" in monitor_triggers
    assert "pull_request" not in monitor_triggers
    assert "workflow_run" not in monitor_triggers
    assert "\n  push:\n" not in monitor_triggers
    assert "inputs:" not in monitor
    assert between(monitor, "permissions: {}\n", "\nenv:\n") == (
        "\nconcurrency:\n"
        "  group: monitor-published-images\n"
        "  cancel-in-progress: false\n"
    )
    monitor_pins = env_pins(monitor)
    assert set(monitor_pins) == {
        "GRYPE_VERSION",
        "GRYPE_SHA256",
        "IMAGE_DASHBOARD_ISSUE",
    }
    assert monitor_pins["IMAGE_DASHBOARD_ISSUE"] == '"1091"'
    assert all(
        env_pins(workflow)[name] == monitor_pins[name]
        for name in ("GRYPE_VERSION", "GRYPE_SHA256")
    )

    snapshot_job = between(monitor, "\n  snapshot:\n", "\n  monitor:\n")
    monitor_job = between(monitor, "\n  monitor:\n", "\n  dashboard:\n")
    dashboard_job = monitor.split("\n  dashboard:\n", maxsplit=1)[1]

    assert "    if: github.repository == 'tektum/verity-images'\n" in snapshot_job
    assert runner(snapshot_job) == "ubuntu-latest"
    assert "\n    timeout-minutes: 10\n" in snapshot_job
    assert "\n    permissions:\n      contents: read\n    steps:\n" in snapshot_job
    snapshot_steps = (
        "uses: actions/checkout@",
        "persist-credentials: false",
        "uses: ./.github/actions/setup-jq",
        "https://tektum.github.io/verity-images/catalog.json",
        "python3 scripts/gen_matrix.py --all > expected-images.json",
        "uses: actions/upload-artifact@",
        "name: monitor-input",
    )
    positions = tuple(snapshot_job.index(step) for step in snapshot_steps)
    assert positions == tuple(sorted(positions))
    assert "([.[0].images[] | [.name, .version]] | sort) ==" in snapshot_job
    assert "([.[1].include[] | [.name, .tag_version]] | sort)" in snapshot_job

    assert "    needs: snapshot\n" in monitor_job
    assert "\n    timeout-minutes: 60\n" in monitor_job
    assert (
        "\n    permissions:\n"
        "      contents: read\n"
        "      security-events: write\n"
        "    strategy:\n"
        in monitor_job
    )
    assert "issues: write" not in monitor_job
    assert "id-token: write" not in monitor_job
    assert (
        "    strategy:\n"
        "      fail-fast: false\n"
        "      matrix:\n"
        "        shard: [0, 1, 2, 3, 4, 5, 6, 7]\n"
        in monitor_job
    )
    monitor_steps = (
        "uses: actions/checkout@",
        "persist-credentials: false",
        "uses: actions/download-artifact@",
        "name: monitor-input",
        "uses: ./.github/actions/setup-jq",
        "scripts/install_image_tools.sh monitor",
        "uses: sigstore/cosign-installer@",
        'scripts/monitor_sboms.sh catalog.json expected-images.json "$SHARD" "$SHARDS" monitor',
        "python3 scripts/build_monitor_sarif.py monitor/manifest.json",
        "uses: github/codeql-action/upload-sarif@",
        "name: monitor-${{ matrix.shard }}",
        "name: monitor-evidence-${{ matrix.shard }}",
    )
    positions = tuple(monitor_job.index(step) for step in monitor_steps)
    assert positions == tuple(sorted(positions))
    assert "https://tektum.github.io/verity-images/catalog.json" not in monitor_job
    assert "python3 scripts/gen_matrix.py --all" not in monitor_job
    assert "          cosign-release: v3.0.6\n" in monitor_job
    scan_step = between(
        monitor_job,
        "      - name: Scan published SBOMs\n",
        "\n      - name: Build code scanning results\n",
    )
    assert (
        "          SHARD: ${{ matrix.shard }}\n"
        "          SHARDS: ${{ strategy.job-total }}\n"
        "        run: |\n"
        '          export PATH="$RUNNER_TEMP/verity-tools:$PATH"\n'
        '          scripts/monitor_sboms.sh catalog.json expected-images.json "$SHARD" "$SHARDS" monitor\n'
        in scan_step
    )
    assert "${{" not in scan_step.split("        run: |\n", maxsplit=1)[1]
    assert (
        "python3 scripts/build_monitor_sarif.py monitor/manifest.json \\\n"
        "            monitor/results.sarif monitor/report.json\n"
        in monitor_job
    )
    sarif_upload = between(
        monitor_job,
        "      - name: Upload code scanning results\n",
        "\n      - name: Upload dashboard shard report\n",
    )
    assert "uses: github/codeql-action/upload-sarif@" in sarif_upload
    assert "          sarif_file: monitor/results.sarif\n" in sarif_upload
    assert "          category: verity-monitor-${{ matrix.shard }}\n" in sarif_upload

    assert "needs.snapshot.result == 'success'" in dashboard_job
    assert "needs.monitor.result == 'success'" in dashboard_job
    assert "github.ref == 'refs/heads/main'" in dashboard_job
    assert runner(dashboard_job) == "ubuntu-latest"
    assert (
        "\n    permissions:\n"
        "      actions: write\n"
        "      contents: read\n"
        "      issues: write\n"
        "    steps:\n"
        in dashboard_job
    )
    assert "pattern: monitor-[0-7]" in dashboard_job
    assert "python3 scripts/build_image_dashboard.py dashboard-input" in dashboard_job
    assert ".title == \"Image Dashboard\"" in dashboard_job
    assert ".state == \"open\"" in dashboard_job
    assert "<!-- verity-image-dashboard/v1 -->" in dashboard_job
    assert 'gh issue edit "$DASHBOARD_ISSUE"' in dashboard_job
    assert "gh issue create" not in dashboard_job
    assert dashboard_job.index("scripts/build_image_dashboard.py") < dashboard_job.index(
        'gh issue edit "$DASHBOARD_ISSUE"'
    )
    # Every affected stream gets an unconditional nightly rebuild attempt; the
    # zero-fixable publication gate is what decides whether it actually
    # resolves, exactly as it already does for a manually dispatched rebuild.
    # Evidence upload happens first so a transient dispatch failure never
    # costs the generated dashboard artifacts, since the dispatch step exits
    # non-zero and a later step would otherwise be skipped by success().
    assert "scripts/dispatch_vulnerability_rebuilds.sh image-dashboard.json\n" in dashboard_job
    assert dashboard_job.index('gh issue edit "$DASHBOARD_ISSUE"') < dashboard_job.index(
        "Upload dashboard evidence"
    )
    assert dashboard_job.index("Upload dashboard evidence") < dashboard_job.index(
        "scripts/dispatch_vulnerability_rebuilds.sh"
    )

    assert monitor.count("uses: actions/checkout@") == 3
    assert monitor.count("uses: ./.github/actions/setup-jq") == 2
    assert 'export PATH="$RUNNER_TEMP/verity-tools:$PATH"' in monitor
    assert "verity-image-dashboard/v1" in dashboard_script


    jq_setup = (ROOT / ".github/actions/setup-jq/action.yaml").read_text(encoding="utf-8")
    assert all("squawk" not in text.lower() for text in (monitor, monitor_script, jq_setup))
    assert "jq-1.8.2/jq-linux-amd64" in jq_setup
    assert "b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f" in jq_setup
    assert '"$tools/jq" | sha256sum --check' in jq_setup
    assert "GITHUB_PATH" not in jq_setup
    assert "$RUNNER_TEMP/verity-tools" in jq_setup
    assert "squawk-tools" not in jq_setup
    assert '"jq@1.8.2"' in (ROOT / "devbox.json").read_text(encoding="utf-8")

    # Exact assignment lines, so the verified publisher cannot be widened to a
    # prefix, a suffix, or a second identity.
    assert [
        line for line in monitor_script.splitlines()
        if line.startswith(("identity=", "issuer="))
    ] == [
        "identity='" + IDENTITY_ASSIGNMENT.removeprefix("identity=") + "'",
        "issuer='" + ISSUER_ASSIGNMENT.removeprefix("issuer=") + "'",
    ]
    assert "cosign verify-attestation --type spdxjson" in monitor_script
    assert monitor_script.index("grype db update") < monitor_script.index(
        'grype "sbom:$predicate"'
    )
    assert "for arch in amd64 arm64; do" in monitor_script
    assert '--arg suffix "-verity-platform-$arch"' in monitor_script
    # A missing platform SBOM is fatal, but republishing a reproducible digest
    # appends verified attestations, so the newest SBOM is the one evaluated.
    assert 'if length == 0 then error("no \\($suffix) SPDX predicate")' in monitor_script
    assert 'sort_by(.creationInfo.created // "") | last' in monitor_script
    assert "if ((selected == 0)); then" in monitor_script
    assert ".schemaVersion == 2 and (.images | length > 0)" in monitor_script
    assert "grype db status --output json" in monitor_script
    assert 'archive_checksum=$(jq -er' in monitor_script
    assert 'capture("[?&]checksum=sha256%3A' in monitor_script
    assert ".inputDigest" in monitor_script
    assert "database: $database[0]" in monitor_script
    assert "export GRYPE_DB_AUTO_UPDATE=false" in monitor_script
    assert 'if [[ "$final_db_checksum" != "$local_db_checksum" ]]; then' in monitor_script


    assert all(command not in monitor_script for command in ("gh ", "docker ", "curl "))

    assert "# Parity with scripts/evaluate_scan_gate.sh: a named fix version" in monitor_sarif
    assert 'fix.get("versions") or [] if version' in monitor_sarif
    assert "if not finding.fixed:\n                    continue" in monitor_sarif
    assert "if len(identities) != 1:" in monitor_sarif
    assert "monitor shard mixed vulnerability databases" in monitor_sarif
    assert '"findings": [finding.report_record() for finding in ordered]' in monitor_sarif
    assert "platformFixes" in monitor_sarif
    assert "Apply compatible image inputs" in monitor_sarif
    assert "Rebuild every affected image" not in monitor_sarif
    assert "monitor scan database {key} does not match" in monitor_sarif


    # Monitoring observes published artifacts and cannot change the image matrix.
    assert ".github/workflows/monitor.yaml" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/monitor_sboms.sh" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/build_monitor_sarif.py" not in gen_matrix.GLOBAL_PATHS
    assert "scripts/build_image_dashboard.py" not in gen_matrix.GLOBAL_PATHS
    assert "BODY_LIMIT: Final = 60 * 1024" in dashboard_script
    assert "report shard indices must be unique and exactly 0 through 7" in dashboard_script
    assert "monitor reports contain mixed catalogs" in dashboard_script
    assert "monitor reports contain mixed Grype identities" in dashboard_script
    assert "[ ]" not in dashboard_script
    assert not (ROOT / "scripts/validate_squawk_reconciliation.jq").exists()

    publish_job = between(workflow, "\n  publish:\n", "\n  build-gate:\n")
    matrix_job = between(workflow, "\n  matrix:\n", "\n  validate:\n")
    validate_job = between(workflow, "\n  validate:\n", "\n  stall-guard:\n")
    stall_guard_job = between(workflow, "\n  stall-guard:\n", "\n  publish:\n")
    build_gate_job = between(workflow, "\n  build-gate:\n", "\n  catalog-catch-up:\n")
    catalog_catch_up_job = workflow.split("\n  catalog-catch-up:\n", maxsplit=1)[1]
    deploy_job = catalog.split("\n  deploy:\n", maxsplit=1)[1]
    assert runner(matrix_job) == "ubuntu-latest"
    assert runner(validate_job) == (
        "${{ matrix.track == 'patched' && format('runs-on={0}-{1}-validate-{2}/"
        "family=c8i.*/cpu=32/ram=64/image=ubuntu24-full-x64/volume=100gb:gp3/"
        "extras=otel/spot=false', github.run_id, github.run_attempt, strategy.job-index) "
        "|| 'namespace-profile-verity-ci-heavy' }}"
    )
    assert "          smoke-before-scan: ${{ matrix.track == 'wolfi' }}\n" in validate_job
    assert "smoke-before-scan:" not in publish_job
    containerd_snapshotter_step = (
        "      - name: Enable Docker containerd snapshotter\n"
        "        if: matrix.track == 'patched'\n"
        "        run: |\n"
        "          printf '%s\\n' "
        "'{\"features\":{\"containerd-snapshotter\":true}}' | sudo tee "
        "/etc/docker/daemon.json\n"
        "          sudo systemctl restart docker\n"
    )
    assert containerd_snapshotter_step in validate_job
    assert containerd_snapshotter_step in publish_job
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
    assert runner(snapshot_job) == "ubuntu-latest"
    assert runner(monitor_job) == (
        f"{RUNS_ON_PREFIX}monitor-${{{{ matrix.shard }}}}/runner=4cpu-linux-x64"
    )
    assert runner(dashboard_job) == "ubuntu-latest"
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
    discovery_step = between(
        catalog,
        "      - name: Discover build runs\n",
        "\n      - name: Download and validate build batches\n",
    )
    assert 'status=$(jq -r .status <<<"$metadata")\n' in discovery_step
    assert '"$status" != completed' in discovery_step
    assert '"$conclusion" != success && "$conclusion" != failure && "$conclusion" != cancelled' in discovery_step
    assert 'Run %s (id %s) is not terminal; catalog unchanged.' in discovery_step
    assert 'select(.name == "build-report" and .expired == false)' in discovery_step
    assert "actions/workflows/build.yaml/runs?branch=main&per_page=100" in discovery_step
    assert "status=completed" not in discovery_step
    assert "gh api --paginate" in discovery_step
    assert '.head_repository.full_name == $repository' in discovery_step
    assert "      - scripts/catalog_reconciliation.jq\n" in catalog
    assert "--from-file scripts/catalog_reconciliation.jq" in discovery_step
    assert '.source.consumedRuns // empty' in discovery_step
    assert 'published_at=$(jq -r .publishedAt previous.json)' in discovery_step
    assert '.updated_at <= $cutoff' in discovery_step
    assert '--argjson ledger "$consumed_runs"' in discovery_step
    assert 'forced_metadata=$explicit_metadata' in discovery_step
    assert 'git merge-base --is-ancestor "$source_sha" HEAD' in discovery_step
    assert discovery_step.count('validate_identity "$metadata"') == 1
    assert 'jq -s . "$RUNNER_TEMP/reconciliation.ndjson" > reconciliation.json' in discovery_step
    assert 'run_attempt' in discovery_step
    assert 'consumedRuns: .' in discovery_step
    assert 'printf \'ready=false\\n\' >> "$GITHUB_OUTPUT"' in discovery_step
    assert '"$EVENT" == workflow_dispatch && -n "$DISPATCH_RUN_ID"' in discovery_step
    assert 'Run %s has no build-report artifact.' in discovery_step
    assert 'missing_scans=$(jq -c --argjson available "$available_scans"' in discovery_step
    assert 'Build report deferred' in discovery_step
    reported_images = {
        "images": [
            {"name": "healthy", "version": "1"},
            {"name": "incomplete", "version": "2"},
        ]
    }
    missing_scans = subprocess.run(
        [
            "jq",
            "-c",
            "--argjson",
            "available",
            '["scan-healthy-1"]',
            '[.images[] | "scan-\\(.name)-\\(.version)"] | unique | . - $available',
        ],
        check=True,
        capture_output=True,
        input=json.dumps(reported_images),
        text=True,
    )
    assert json.loads(missing_scans.stdout) == ["scan-incomplete-2"]

    legacy_runs = [
        {
            "id": 10,
            "run_attempt": 1,
            "status": "completed",
            "updated_at": "2026-09-09T01:00:00Z",
        },
        {
            "id": 11,
            "run_attempt": 1,
            "status": "completed",
            "updated_at": "2026-09-09T02:00:00Z",
        },
        {
            "id": 12,
            "run_attempt": 1,
            "status": "completed",
            "updated_at": "2026-09-09T04:00:00Z",
        },
    ]
    legacy_ledger = subprocess.run(
        [
            "jq",
            "-c",
            "--arg",
            "cutoff",
            "2026-09-09T02:30:00Z",
            "--arg",
            "source",
            "11",
            (
                "reduce (.[] | select(.status == \"completed\" and "
                ".updated_at <= $cutoff)) as $run "
                "({($source): 1}; .[($run.id | tostring)] = $run.run_attempt)"
            ),
        ],
        check=True,
        capture_output=True,
        input=json.dumps(legacy_runs),
        text=True,
    )
    consumed_legacy = json.loads(legacy_ledger.stdout)
    assert consumed_legacy == {"10": 1, "11": 1}
    assert reconciliation_plan(legacy_runs, consumed_legacy) == {
        "candidates": [legacy_runs[2]]
    }
    rerun_after_migration = {
        **legacy_runs[0],
        "run_attempt": 2,
        "updated_at": "2026-09-09T03:00:00Z",
    }
    assert reconciliation_plan(
        [rerun_after_migration, legacy_runs[2]], consumed_legacy
    ) == {"candidates": [rerun_after_migration, legacy_runs[2]]}

    at_frontier_rerun = {
        "id": 11,
        "run_attempt": 2,
        "status": "completed",
        "updated_at": "2026-09-09T02:00:00Z",
    }
    assert reconciliation_plan([at_frontier_rerun], {"11": 1}) == {
        "candidates": [at_frontier_rerun]
    }

    below_frontier_rerun = {
        "id": 10,
        "run_attempt": 2,
        "status": "completed",
        "updated_at": "2026-09-09T03:00:00Z",
    }
    later_trigger = {
        "id": 12,
        "run_attempt": 1,
        "status": "completed",
        "updated_at": "2026-09-09T04:00:00Z",
    }
    evicted_rerun_trigger = reconciliation_plan(
        [below_frontier_rerun, later_trigger], {"10": 1, "11": 1}
    )
    assert evicted_rerun_trigger == {
        "candidates": [below_frontier_rerun, later_trigger]
    }

    higher_id_finished_first = {
        "id": 11,
        "run_attempt": 1,
        "status": "completed",
        "updated_at": "2026-09-09T02:00:00Z",
    }
    completion_order = reconciliation_plan(
        [below_frontier_rerun, higher_id_finished_first], {"10": 1}
    )
    assert completion_order == {
        "candidates": [higher_id_finished_first, below_frontier_rerun]
    }

    forced_reapply = reconciliation_plan(
        [below_frontier_rerun], {"10": 2}, forced=below_frontier_rerun
    )
    assert forced_reapply == {"candidates": [below_frontier_rerun]}
    assert reconciliation_plan(
        [{**later_trigger, "status": "in_progress"}], {"10": 1, "11": 1}
    ) == {"candidates": []}

    reconciliation_filter = (ROOT / "scripts/catalog_reconciliation.jq").read_text(
        encoding="utf-8"
    )
    assert 'sort_by(.updated_at, .id, .run_attempt)' in reconciliation_filter
    assert '$ledger[(.id | tostring)]' in reconciliation_filter

    batch_step = between(
        catalog,
        "      - name: Download and validate build batches\n",
        "\n      - name: Generate expected images\n",
    )
    assert 'done < <(jq -c \'.[]\' reconciliation.json)' in batch_step
    assert 'gh run download "$run_id" --repo "$REPOSITORY"' in batch_step
    assert "--name build-report --dir \"$destination/report\"" in batch_step
    assert "--name \"$artifact\" --dir \"$destination/scans/$artifact\"" in batch_step

    catalog_step = between(
        catalog,
        "      - name: Generate catalog\n",
        "\n\n      - name: Preserve current catalog\n",
    )
    download_catalog_step = between(
        catalog,
        "      - name: Download current catalog\n",
        "\n      - name: Discover build runs\n",
    )
    assert "https://tektum.github.io/verity-images/catalog.json" in catalog
    assert "check-jsonschema --schemafile docs/catalog.schema.json previous.json" in catalog
    assert "      - name: Check out source revision\n" not in catalog
    assert catalog.index("      - name: Download current catalog\n") < catalog.index(
        "      - name: Discover build runs\n"
    ) < catalog.index("      - name: Download and validate build batches\n") < catalog.index(
        "      - name: Generate expected images\n"
    ) < catalog.index("      - name: Generate catalog\n")
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
    assert '"$MODE" == packages' in download_catalog_step
    assert download_catalog_step.count("        run: |\n") == 1
    catalog_script = catalog_step.split("        run: |\n", maxsplit=1)[1]
    assert catalog_step.count("        run: |\n") == 1
    assert 'done < <(jq -c \'.[]\' reconciliation.json)' in catalog_script
    assert 'current=previous.json' in catalog_script
    assert "'.[0] + {source: .[1]}'" in catalog_script
    assert 'cp "$current" catalog.json' in catalog_script
    assert '"$current" "$output" "$run_id" "$run_url" "$source_sha" "$published_at"' in catalog_script
    assert "catalog.json catalog-source.json > sourced-catalog.json" in catalog_script
    assert BOOTSTRAP_INVENTORY_COMMAND in shell_commands(catalog_script)
    assert CATALOG_JQ_COMMAND in shell_commands(catalog_script)
    assert "${{ steps.source.outputs." not in catalog
    assert "steps.artifacts.outputs.ready" not in catalog
    catalog_schema = json.loads(
        (ROOT / "docs/catalog.schema.json").read_text(encoding="utf-8")
    )
    consumed_runs_schema = catalog_schema["properties"]["source"]["properties"][
        "consumedRuns"
    ]
    assert consumed_runs_schema["propertyNames"]["pattern"] == "^[0-9]+$"
    assert consumed_runs_schema["additionalProperties"] == {
        "type": "integer",
        "minimum": 1,
    }
    inventory_filter = (ROOT / "scripts/catalog_inventory.jq").read_text(encoding="utf-8")
    assert "cat > inventory-filter.jq <<'EOF'" not in catalog
    assert "(.[1].include | map([.name, .tag_version])) as $expected" in inventory_filter
    # A superseded identity may only remain while no expected version of the same
    # image has been published, so an authority change cannot prune a live entry.
    assert "($expected | any(.[0] == $image.name))" in inventory_filter
    assert CATALOG_INVENTORY_COMMAND in shell_commands(catalog_script)

    check_lock_refresh_policy(workflow)


if __name__ == "__main__":
    main()
