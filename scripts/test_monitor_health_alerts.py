#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import Mock

from monitor_health_alerts import LABEL, MARKER, reconcile

REPOSITORY = "tektum/verity-images"
RUN_URL = f"https://github.com/{REPOSITORY}/actions/runs/12345"


def issue(*, number: int = 99, body: str | None = None, state: str = "open") -> dict:
    return {"number": number, "body": body or MARKER + "\nOld failure\n", "state": state}


def failing_monitor_creates_owned_issue() -> None:
    created: dict = {}

    def lookup(method: str, path: str, **values: object) -> object:
        if method == "POST":
            assert path == f"repos/{REPOSITORY}/issues"
            created.update(values)
            return {"number": 45}
        assert (method, path) == ("GET", f"repos/{REPOSITORY}/issues?labels={LABEL}&state=all")
        if created:
            return [issue(number=45, body=str(created["body"]))]
        return []

    assert reconcile(True, RUN_URL, "monitor: failure", REPOSITORY, lookup) == 45
    assert created["labels"] == [LABEL]
    assert RUN_URL in str(created["body"])
    assert reconcile(True, RUN_URL, "monitor: failure", REPOSITORY, lookup) == 45
    assert "Old failure" not in str(created["body"])


def recovery_closes_matching_issue() -> None:
    lookup = Mock(return_value=[issue()])
    assert reconcile(False, RUN_URL, "monitor: success", REPOSITORY, lookup) == 99
    method, path = lookup.call_args.args[:2]
    assert (method, path) == ("PATCH", f"repos/{REPOSITORY}/issues/99")
    body = lookup.call_args.kwargs["body"]
    assert lookup.call_args.kwargs["state"] == "closed"
    assert "completed successfully" in body
    lookup = Mock(return_value=[{"number": 99, "body": body, "state": "closed"}])
    reconcile(False, RUN_URL, "monitor: success", REPOSITORY, lookup)
    assert lookup.call_count == 1


def failure_reopens_and_updates_only_owned_issue() -> None:
    foreign = issue(number=4, body="<!-- another monitor -->\n")
    pr_foreign = issue(number=5, body=MARKER + "\nPull request\n")
    pr_foreign["pull_request"] = {}
    lookup = Mock(return_value=[foreign, pr_foreign, issue(state="closed")])
    assert reconcile(True, RUN_URL, "monitor: cancelled", REPOSITORY, lookup) == 99
    method, path = lookup.call_args.args[:2]
    assert (method, path) == ("PATCH", f"repos/{REPOSITORY}/issues/99")
    assert lookup.call_args.kwargs["state"] == "open"
    assert "monitor: cancelled" in lookup.call_args.kwargs["body"]


def clean_without_prior_failure_is_quiet() -> None:
    lookup = Mock(return_value=[])
    assert reconcile(False, RUN_URL, "monitor: success", REPOSITORY, lookup) is None
    lookup.assert_called_once_with("GET", f"repos/{REPOSITORY}/issues?labels={LABEL}&state=all")


def duplicates_fail_closed() -> None:
    lookup = Mock(return_value=[issue(number=1), issue(number=2)])
    try:
        reconcile(True, RUN_URL, "monitor: failure", REPOSITORY, lookup)
    except ValueError as error:
        assert "multiple monitor failure issues" in str(error)
    else:
        raise AssertionError("duplicate owned alerts were accepted")


def real_cli_serializes_commands() -> None:
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        scratch = Path(temporary)
        stub = scratch / "gh"
        log = scratch / "calls.json"
        stub.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['CALL_LOG'], 'a') as calls:\n"
            "  calls.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "if sys.argv[1] == 'api':\n"
            "  print(json.dumps({'number': 73}))\n"
            "else:\n"
            "  print('[]')\n"
        )
        stub.chmod(0o755)
        output = scratch / "output"
        env = os.environ.copy()
        env.update(PATH=f"{scratch}:{env['PATH']}", CALL_LOG=str(log))
        subprocess.run(
            [sys.executable, str(root / "scripts/monitor_health_alerts.py"),
             "true", RUN_URL, "monitor: failure", REPOSITORY, str(output)],
            cwd=root, env=env, check=True,
        )
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        assert calls[0] == [
            "exec", "scripts/gh_api_backoff.sh", "api", "--method", "GET",
            f"repos/{REPOSITORY}/issues?labels={LABEL}&state=all",
        ]
        assert calls[1][0:4] == ["api", "--method", "POST", f"repos/{REPOSITORY}/issues"]
        assert any("monitor: failure" in field for field in calls[1])
        assert output.read_text() == "monitor_failure_issue=73\n"
    invalid_cli = subprocess.run(
        [sys.executable, str(root / "scripts/monitor_health_alerts.py"),
         "False", RUN_URL, "monitor: success", REPOSITORY, str(scratch / "invalid")],
        cwd=root, capture_output=True, text=True,
    )
    assert invalid_cli.returncode != 0
    assert "FAILED must be true or false" in invalid_cli.stderr
    try:
        reconcile("False", RUN_URL, "monitor: success", REPOSITORY, Mock())
    except ValueError as error:
        assert str(error) == "monitor failed must be a boolean"
    else:
        raise AssertionError("non-boolean failure state was accepted")

def main() -> None:
    failing_monitor_creates_owned_issue()
    recovery_closes_matching_issue()
    failure_reopens_and_updates_only_owned_issue()
    clean_without_prior_failure_is_quiet()
    duplicates_fail_closed()
    real_cli_serializes_commands()
    print("passed scripts/test_monitor_health_alerts.py")


if __name__ == "__main__":
    main()
