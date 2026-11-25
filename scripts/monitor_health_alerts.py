#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Persist a daily image monitor failure in one repository issue."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Final

MARKER: Final = "<!-- verity-monitor-run-failure/v1 -->"
LABEL: Final = "main-failure"
TITLE: Final = "Published image monitor is failing"
REPOSITORY: Final = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def request(method: str, path: str, **values: object) -> dict:
    command = ["gh"]
    if method == "POST":
        command.extend(["api", "--method", method, path])
    else:
        command.extend(["exec", "scripts/gh_api_backoff.sh", "api", "--method", method, path])
    for key, value in values.items():
        raw = json.dumps(value) if isinstance(value, list) else str(value)
        command.extend(["--raw-field", f"{key}={raw}"])
    result = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    return json.loads(result) if result else {}


def reconcile(
    failed: bool,
    run_url: str,
    reason: str,
    repository: str,
    lookup: Callable[..., dict] = request,
) -> int | None:
    if not isinstance(failed, bool):
        raise ValueError("monitor failed must be a boolean")
    if REPOSITORY.fullmatch(repository) is None:
        raise ValueError("repository must be in owner/name form")
    matches = lookup("GET", f"repos/{repository}/issues?labels={LABEL}&state=all")
    if not isinstance(matches, list):
        raise ValueError("monitor issue search did not return an array")
    existing = [
        issue for issue in matches
        if str(issue.get("body") or "").startswith(MARKER + "\n")
        and "pull_request" not in issue
    ]
    if len(existing) > 1:
        raise ValueError("multiple monitor failure issues exist")
    body = (
        f"{MARKER}\nThe published image monitor did not complete: {reason}\n\n"
        f"Failed run: {run_url}\n\n"
        "Findings on other shards may be retained from the last complete run. "
        "Restore complete daily scans so fixable findings reach remediation.\n"
        if failed else
        f"{MARKER}\nThe published image monitor completed successfully at {run_url}.\n"
    )
    if existing:
        number = issue_number(existing[0])
        expected_state = "open" if failed else "closed"
        if existing[0].get("body") != body or existing[0].get("state") != expected_state:
            lookup("PATCH", f"repos/{repository}/issues/{number}", body=body, state=expected_state)
        return number
    if not failed:
        return None
    created = lookup("POST", f"repos/{repository}/issues", title=TITLE, body=body, labels=[LABEL])
    return issue_number(created)


def issue_number(issue: dict) -> int:
    number = issue.get("number")
    if isinstance(number, bool) or not isinstance(number, int):
        raise ValueError("monitor failure issue has no valid number")
    return number


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit("usage: monitor_health_alerts.py FAILED RUN_URL REASON REPOSITORY OUTPUT")
    print(f"Monitor run {sys.argv[2]}: {sys.argv[3]}")
    if sys.argv[1] not in {"true", "false"}:
        raise SystemExit("FAILED must be true or false")
    failed = {"true": True, "false": False}.get(sys.argv[1])
    number = reconcile(failed, sys.argv[2], sys.argv[3], sys.argv[4])
    with Path(sys.argv[5]).open("a", encoding="utf-8") as output:
        if number is not None:
            print(f"monitor_failure_issue={number}", file=output)


if __name__ == "__main__":
    main()
