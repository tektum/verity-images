#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

import json
import os
import subprocess
import time
from typing import Final

WORKFLOW: Final = "local-package-revision.yaml"
ACTIVE: Final = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})


def older_active_runs(value: object, current_run: int) -> list[int]:
    if not isinstance(value, list) or not all(isinstance(page, dict) for page in value):
        raise ValueError("workflow runs response must be an array of pages")
    older: set[int] = set()
    for page in value:
        runs = page.get("workflow_runs")
        if not isinstance(runs, list):
            raise ValueError("workflow runs page is missing workflow_runs")
        for run in runs:
            if not isinstance(run, dict):
                raise ValueError("workflow run must be an object")
            run_id, status = run.get("id"), run.get("status")
            if type(run_id) is not int or not isinstance(status, str):
                raise ValueError("workflow run has an invalid id or status")
            if run_id < current_run and status in ACTIVE:
                older.add(run_id)
    return sorted(older)


def workflow_runs(repository: str) -> object:
    result = subprocess.run(
        [
            "gh", "api", "--paginate", "--slurp",
            f"repos/{repository}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def wait_turn(repository: str, current_run: int, *, interval: int = 15, timeout: int = 3300) -> None:
    deadline = time.monotonic() + timeout
    while older := older_active_runs(workflow_runs(repository), current_run):
        if time.monotonic() >= deadline:
            raise TimeoutError(f"older local package revision runs did not finish: {older}")
        print(f"waiting for older local package revision runs: {','.join(map(str, older))}", flush=True)
        time.sleep(interval)


def main() -> None:
    try:
        repository = os.environ["REPOSITORY"]
        current_run = int(os.environ["RUN_ID"])
        if current_run <= 0 or not os.environ.get("GH_TOKEN"):
            raise ValueError("RUN_ID and GH_TOKEN are required")
        wait_turn(repository, current_run)
    except (KeyError, ValueError, TimeoutError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"local package revision serialization refused: {error}") from error


if __name__ == "__main__":
    main()
