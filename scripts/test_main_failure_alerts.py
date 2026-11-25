#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import main_failure_alerts as alerts

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "tektum/verity-images"
NOW = datetime(2026, 11, 25, 12, tzinfo=UTC)


def iso(when: datetime) -> str:
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def run(run_id: int, when: datetime, **overrides: object) -> dict:
    return {
        "id": run_id,
        "event": "push",
        "head_branch": "main",
        "status": "completed",
        "conclusion": "success",
        "created_at": iso(when - timedelta(hours=1)),
        "updated_at": iso(when),
        "html_url": f"https://github.com/{REPOSITORY}/actions/runs/{run_id}",
        "head_repository": {"full_name": REPOSITORY},
    } | overrides


def job(name: str, conclusion: str | None, when: datetime, status: str = "completed") -> dict:
    return {"name": name, "status": status, "conclusion": conclusion, "completed_at": iso(when) if conclusion else None}


def publish(build_name: str, conclusion: str | None, when: datetime) -> dict:
    # GitHub truncates long default matrix job names, sometimes before the closing parenthesis.
    return job(f"publish / publish ({build_name}, Languages & Build Tools, images/{build_name}, A long descr...",
               conclusion, when)


def native(build_name: str, conclusion: str | None, when: datetime) -> dict:
    return job(f"native-arm64 ({build_name}, images/{build_name}, Source built image from pinned sou...",
               conclusion, when)


def outcome(image: str, succeeded: bool, hours_ago: float, run_id: int) -> alerts.Outcome:
    return alerts.Outcome(
        image=image,
        succeeded=succeeded,
        completed_at=NOW - timedelta(hours=hours_ago),
        run_id=run_id,
        run_url=f"https://github.com/{REPOSITORY}/actions/runs/{run_id}",
        event="push",
        conclusions=("success",) if succeeded else ("failure",),
    )


def issue(number: int, image: str, state: str = "open", body: str = "") -> dict:
    return {"number": number, "title": alerts.title(image), "state": state, "body": body}


def test_main_runs_only() -> None:
    when = NOW - timedelta(hours=2)
    pages = [{"workflow_runs": [
        run(1, when),
        run(2, when, event="workflow_dispatch"),
        run(3, when, event="pull_request", head_branch="feature"),
        run(4, when, event="pull_request"),  # a fork branch named main
        run(5, when, event="merge_group", head_branch="gh-readonly-queue/main/pr-1"),
        run(6, when, event="workflow_dispatch", head_branch="feature"),
        run(7, when, status="in_progress", conclusion=None),
        run(8, when, head_repository={"full_name": "someone/verity-images"}),
    ]}, {"workflow_runs": [run(9, when + timedelta(minutes=1))]}]
    assert [item["id"] for item in alerts.main_runs(pages, REPOSITORY)] == [9, 2, 1]


def test_job_level_outcomes() -> None:
    when = NOW - timedelta(hours=1)
    jobs = [
        job("matrix", "success", when),
        job("stall-guard", "success", when),
        job("validate", "skipped", when),
        job("build-gate", "success", when),
        # Native succeeded but publish failed: the run concluded, the image did not publish.
        native("loki", "success", when - timedelta(minutes=30)),
        publish("loki", "failure", when),
        # Two streams of one image: one success does not hide the other's failure.
        publish("go-fips", "success", when),
        publish("go-fips", "timed_out", when),
        # A cancelled matrix leg is never a publication.
        publish("temporal", "cancelled", when),
        publish("poetry", "success", when),
        native("zookeeper", "success", when),
        publish("zookeeper", "success", when + timedelta(minutes=5)),
        # No evidence: skipped everywhere, or not completed.
        publish("skipped-only", "skipped", when),
        publish("pending", None, when),
        job("publish / publish (untruncated)", "success", when),
        job("publish / publish", "skipped", when),
    ]
    outcomes = {item.image: item for item in alerts.run_outcomes(run(77, when), jobs)}
    assert sorted(outcomes) == ["go-fips", "loki", "poetry", "temporal", "untruncated", "zookeeper"]
    assert [image for image, item in sorted(outcomes.items()) if item.succeeded] == [
        "poetry", "untruncated", "zookeeper",
    ]
    assert outcomes["loki"].conclusions == ("failure", "success")
    assert outcomes["temporal"].conclusions == ("cancelled",)
    assert outcomes["zookeeper"].completed_at == when + timedelta(minutes=5)
    assert outcomes["loki"].run_id == 77 and outcomes["loki"].run_url.endswith("/77")


def test_threshold_and_age() -> None:
    two = [outcome("temporal", False, 6, 1), outcome("temporal", False, 3, 2)]
    streaks = alerts.failure_streaks(two)
    assert len(streaks["temporal"]) == 2
    assert alerts.plan(streaks, {}, NOW) == []

    three = [*two, outcome("temporal", False, 1, 3)]
    actions = alerts.plan(alerts.failure_streaks(three), {}, NOW)
    assert [(action.kind, action.image, action.issue) for action in actions] == [("create", "temporal", None)]
    assert "3 consecutive trusted main Build runs" in actions[0].body
    assert actions[0].body.startswith("<!-- verity-main-failure:temporal -->\n")
    assert actions[0].body.index("/runs/3)") < actions[0].body.index("/runs/1)")

    # One failure older than 24 hours with no later run alerts; one at exactly 24 hours does not.
    stale = alerts.failure_streaks([outcome("temporal", False, 25, 1)])
    assert [action.kind for action in alerts.plan(stale, {}, NOW)] == ["create"]
    assert "1 consecutive trusted main Build run since" in alerts.plan(stale, {}, NOW)[0].body
    boundary = alerts.failure_streaks([outcome("temporal", False, 24, 1)])
    assert alerts.plan(boundary, {}, NOW) == []


def test_success_resets_streak() -> None:
    history = [
        outcome("temporal", False, 60, 1),
        outcome("temporal", False, 50, 2),
        outcome("temporal", False, 40, 3),
        outcome("temporal", True, 20, 4),
        outcome("temporal", False, 10, 5),
        outcome("temporal", False, 5, 6),
    ]
    streaks = alerts.failure_streaks(list(reversed(history)))
    assert [item.run_id for item in streaks["temporal"]] == [5, 6]
    assert alerts.plan(streaks, {}, NOW) == []
    assert alerts.plan(streaks, {"temporal": issue(9, "temporal")}, NOW) == []


def test_issue_dedupe() -> None:
    failing = alerts.failure_streaks([outcome("loki", False, hours, hours) for hours in (3, 2, 1)])
    body = alerts.issue_body("loki", failing["loki"])
    pages = [[
        issue(10, "loki", "closed"),
        issue(12, "loki", "closed"),
        {"number": 13, "title": alerts.title("loki"), "state": "open", "body": "", "pull_request": {}},
        issue(14, "other", "closed"),
        {"number": 15, "title": "Image Dashboard", "state": "open", "body": ""},
    ]]
    owners = alerts.image_issues(pages)
    assert {image: item["number"] for image, item in owners.items()} == {"loki": 12, "other": 14}
    reopen = alerts.plan(failing, owners, NOW)
    assert [(action.kind, action.issue, action.body) for action in reopen] == [("reopen", 12, body)]

    owners = alerts.image_issues([*pages, [issue(11, "loki", "open", "stale body")]])
    assert owners["loki"]["number"] == 11
    update = alerts.plan(failing, owners, NOW)
    assert [(action.kind, action.issue, action.body) for action in update] == [("update", 11, body)]

    current = {"loki": issue(11, "loki", "open", body)}
    assert alerts.plan(failing, current, NOW) == []


def test_success_closes_issue() -> None:
    history = [outcome("loki", False, hours, hours) for hours in (9, 8, 7)] + [outcome("loki", True, 1, 99)]
    streaks = alerts.failure_streaks(history)
    assert streaks == {"loki": None}
    closes = alerts.plan(streaks, {"loki": issue(11, "loki")}, NOW)
    assert [(action.kind, action.issue) for action in closes] == [("close", 11)]
    assert alerts.plan(streaks, {"loki": issue(11, "loki", "closed")}, NOW) == []
    assert alerts.plan(streaks, {}, NOW) == []
    assert "/runs/99" in alerts.recovery_comment(history[-1])


def test_apply_calls() -> None:
    latest = {"loki": outcome("loki", True, 1, 99)}
    actions = [
        alerts.Action("create", "temporal", body="new body"),
        alerts.Action("reopen", "go-fips", 12, "reopen body"),
        alerts.Action("update", "nats", 13, "update body"),
        alerts.Action("close", "loki", 11),
    ]
    with patch.object(alerts.subprocess, "run") as runner:
        runner.return_value = subprocess.CompletedProcess([], 0, stdout="{}", stderr="")
        alerts.apply(actions, REPOSITORY, latest)
    calls = [call.args[0] for call in runner.call_args_list]
    api = alerts.GH_API
    assert calls[0][:6] == ["gh", "label", "create", "main-failure", "--repo", REPOSITORY]
    assert calls[1] == [api, f"repos/{REPOSITORY}/issues", "--method", "POST", "-f",
                        "title=Main build failing: temporal", "-f", "body=new body", "-f", "labels[]=main-failure"]
    assert calls[2] == [api, f"repos/{REPOSITORY}/issues/12", "--method", "PATCH", "-f", "state=open",
                        "-f", "body=reopen body"]
    assert calls[3] == [api, f"repos/{REPOSITORY}/issues/13", "--method", "PATCH", "-f", "state=open",
                        "-f", "body=update body"]
    assert calls[4][:4] == [api, f"repos/{REPOSITORY}/issues/11/comments", "--method", "POST"]
    assert "/runs/99" in calls[4][5]
    assert calls[5] == [api, f"repos/{REPOSITORY}/issues/11", "--method", "PATCH", "-f", "state=closed",
                        "-f", "state_reason=completed"]
    assert len(calls) == 6


def test_main_wiring() -> None:
    hours = lambda value: NOW - timedelta(hours=value)  # noqa: E731
    runs = [{"workflow_runs": [
        run(1, hours(30)), run(2, hours(20)), run(3, hours(10)), run(4, hours(2)),
        run(5, hours(1), event="pull_request", head_branch="fix"),
    ]}]
    jobs = {
        1: [publish("temporal", "failure", hours(30)), publish("loki", "failure", hours(30))],
        2: [publish("temporal", "failure", hours(20))],
        3: [publish("temporal", "cancelled", hours(10)), publish("nats", "failure", hours(10))],
        4: [publish("loki", "success", hours(2))],
        5: [publish("nats", "success", hours(1))],
    }
    issues = [[issue(11, "loki"), issue(12, "temporal", "closed")]]
    requested: list[str] = []

    def fake_api(*arguments: str) -> object:
        path = arguments[-1]
        requested.append(path)
        if "/actions/workflows/build.yaml/runs?" in path:
            assert "branch=main&status=completed&created=%3E%3D2026-11-22T12:00:00Z" in path
            return runs
        if match := re.search(r"/actions/runs/(\d+)/jobs\?filter=latest", path):
            return [{"jobs": jobs[int(match.group(1))]}]
        if "/issues?labels=main-failure&state=all" in path:
            return issues
        raise AssertionError(path)

    class FrozenDatetime(datetime):
        @classmethod
        def now(cls, tz: object = None) -> datetime:
            return NOW

    with (
        patch.dict(alerts.os.environ, {"REPOSITORY": REPOSITORY}),
        patch.object(alerts, "datetime", FrozenDatetime),
        patch.object(alerts, "api", fake_api),
        patch.object(alerts, "apply") as applied,
    ):
        alerts.main()
    assert not any("/runs/5/" in path for path in requested)
    actions, repository, latest = applied.call_args.args
    assert repository == REPOSITORY
    assert [(action.kind, action.image, action.issue) for action in actions] == [
        ("close", "loki", 11),
        ("reopen", "temporal", 12),
    ]
    assert latest["loki"].run_id == 4


def test_read_retries() -> None:
    transient = subprocess.CalledProcessError(1, ["gh"])
    with patch.object(alerts, "api", side_effect=[transient, transient, ["page"]]) as api, \
            patch.object(alerts.time, "sleep") as sleep:
        assert alerts.read_pages("repos/x") == ["page"]
    assert api.call_count == 3 and sleep.call_count == 2
    for failures in ([subprocess.CalledProcessError(75, ["gh"])], [transient] * 3):
        with patch.object(alerts, "api", side_effect=failures) as api, patch.object(alerts.time, "sleep"):
            try:
                alerts.read_pages("repos/x")
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError("a failed read was accepted")
        assert api.call_count == len(failures)


def test_job_names_stay_parseable() -> None:
    # The parser reads build_name as the first default matrix job name value.
    matrix = json.loads(subprocess.run(
        [sys.executable, str(ROOT / "scripts/gen_matrix.py"), "--all"], check=True, capture_output=True, text=True,
    ).stdout)
    assert matrix["include"]
    for row in matrix["include"]:
        assert next(iter(row)) == "build_name", row
        assert not re.search(r"[,()]", row["build_name"]), row
    build = (ROOT / ".github/workflows/build.yaml").read_text(encoding="utf-8")
    publish_workflow = (ROOT / ".github/workflows/publish.yaml").read_text(encoding="utf-8")
    assert "\n  native-arm64:\n" in build and "\n  publish:\n" in build and "\n  publish:\n" in publish_workflow
    assert not re.search(r"^    name:", build + publish_workflow, re.MULTILINE)


def test_workflow() -> None:
    workflow = (ROOT / ".github/workflows/main-failures.yaml").read_text(encoding="utf-8")
    assert "\n  schedule:\n" in workflow and "\n  workflow_dispatch:\n" in workflow
    for trigger in ("pull_request", "push:", "workflow_run", "merge_group"):
        assert trigger not in workflow, trigger
    assert "\npermissions: {}\n" in workflow
    assert "    permissions:\n      actions: read\n      contents: read\n      issues: write\n    steps:" in workflow
    assert "persist-credentials: false" in workflow
    assert "run: python3 scripts/main_failure_alerts.py" in workflow


def main() -> None:
    test_main_runs_only()
    test_job_level_outcomes()
    test_threshold_and_age()
    test_success_resets_streak()
    test_issue_dedupe()
    test_success_closes_issue()
    test_apply_calls()
    test_main_wiring()
    test_job_names_stay_parseable()
    test_read_retries()
    test_workflow()
    print("passed scripts/test_main_failure_alerts.py")


if __name__ == "__main__":
    main()
