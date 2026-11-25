#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# How to run:
#   REPOSITORY=owner/repo GH_TOKEN=... uv run scripts/main_failure_alerts.py
"""Keep one main-failure issue per image in step with trusted main builds.

The image outcome of a main Build run is read from its job conclusions, never from
the run conclusion: build-gate only warns on a partial main publication, so one
image can fail run after run while everything else publishes. An image fails a
run when any of its native-arm64 or publish jobs ends in anything but success,
including cancelled and timed out jobs. An issue opens once an image has failed
THRESHOLD consecutive runs or has kept failing for longer than MAX_AGE, and closes
on the image's next successful main run. Pull request and merge queue runs never
count. The issue is the durable state: an open issue stays open until a success
is observed, so LOOKBACK only needs to cover MAX_AGE plus the schedule interval.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Final

LABEL: Final = "main-failure"
THRESHOLD: Final = 3
MAX_AGE: Final = timedelta(hours=24)
LOOKBACK: Final = timedelta(hours=72)
MAIN_EVENTS: Final = frozenset({"push", "workflow_dispatch"})
# Matrix jobs keep GitHub's default name, "<job> (<values>)", whose values follow the
# matrix row's sorted keys. build_name sorts first, so it is the first value even when
# GitHub truncates the rest of the name. scripts/cancel_stalled_jobs.sh relies on the
# same job names.
IMAGE_JOB: Final = re.compile(r"^(?:native-arm64|publish / publish) \(([^,()]+)[,)]")
HISTORY_ROWS: Final = 10
GH_API: Final = str(Path(__file__).with_name("gh_api_backoff.sh"))


@dataclass(frozen=True)
class Outcome:
    image: str
    succeeded: bool
    completed_at: datetime
    run_id: int
    run_url: str
    event: str
    conclusions: tuple[str, ...]


@dataclass(frozen=True)
class Action:
    kind: str  # create, update, reopen, close
    image: str
    issue: int | None = None
    body: str = ""
    comment: str = ""


def timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main_runs(pages: list[dict], repository: str) -> list[dict]:
    """Completed Build runs of this repository's main branch, newest first."""
    runs = []
    for page in pages:
        for run in page["workflow_runs"]:
            if (
                run["event"] in MAIN_EVENTS
                and run["head_branch"] == "main"
                and run["status"] == "completed"
                and (run.get("head_repository") or {}).get("full_name") == repository
            ):
                runs.append(run)
    return sorted(runs, key=lambda run: (run["created_at"], run["id"]), reverse=True)


def run_outcomes(run: dict, jobs: list[dict]) -> list[Outcome]:
    """One outcome per image built by the run's latest attempt.

    An image whose jobs were all skipped or are not yet completed carries no
    evidence either way. Every other non-success conclusion is a failure, so a
    cancelled or timed out matrix leg never reads as a publication.
    """
    by_image: dict[str, list[dict]] = {}
    for job in jobs:
        match = IMAGE_JOB.match(job["name"])
        if match:
            by_image.setdefault(match.group(1).strip(), []).append(job)
    outcomes = []
    for image, image_jobs in sorted(by_image.items()):
        conclusions = tuple(sorted(str(job.get("conclusion")) for job in image_jobs))
        if any(job.get("status") != "completed" or not job.get("conclusion") for job in image_jobs):
            continue
        if set(conclusions) == {"skipped"}:
            continue
        completed = max(timestamp(job.get("completed_at") or run["updated_at"]) for job in image_jobs)
        outcomes.append(
            Outcome(
                image=image,
                succeeded=set(conclusions) == {"success"},
                completed_at=completed,
                run_id=run["id"],
                run_url=run["html_url"],
                event=run["event"],
                conclusions=conclusions,
            )
        )
    return outcomes


def failure_streaks(outcomes: list[Outcome]) -> dict[str, list[Outcome] | None]:
    """Per image, the failures since its latest success, or None if its latest run succeeded."""
    by_image: dict[str, list[Outcome]] = {}
    for outcome in sorted(outcomes, key=lambda item: (item.completed_at, item.run_id)):
        by_image.setdefault(outcome.image, []).append(outcome)
    streaks: dict[str, list[Outcome] | None] = {}
    for image, history in by_image.items():
        if history[-1].succeeded:
            streaks[image] = None
            continue
        streak: list[Outcome] = []
        for outcome in reversed(history):
            if outcome.succeeded:
                break
            streak.append(outcome)
        streaks[image] = list(reversed(streak))
    return streaks


def alerting(streak: list[Outcome], now: datetime) -> bool:
    return len(streak) >= THRESHOLD or now - streak[0].completed_at > MAX_AGE


def title(image: str) -> str:
    return f"Main build failing: {image}"


def issue_body(image: str, streak: list[Outcome]) -> str:
    first = streak[0]
    lines = [
        f"<!-- verity-main-failure:{image} -->",
        f"`{image}` has failed {len(streak)} consecutive trusted main Build "
        f"run{'s' if len(streak) != 1 else ''} since "
        f"{first.completed_at.strftime('%Y-%m-%d %H:%M UTC')}.",
        "",
        "Its native-arm64 or publish job did not succeed, so the published image and "
        "catalog entry are stale. build-gate only warns on a partial main publication, "
        "so this does not fail the run on its own.",
        "",
        "| Run | Event | Completed | Job conclusions |",
        "|---|---|---|---|",
    ]
    for outcome in reversed(streak[-HISTORY_ROWS:]):
        lines.append(
            f"| [{outcome.run_id}]({outcome.run_url}) | {outcome.event} | "
            f"{outcome.completed_at.strftime('%Y-%m-%d %H:%M UTC')} | {', '.join(outcome.conclusions)} |"
        )
    if len(streak) > HISTORY_ROWS:
        lines.append(f"\n{len(streak) - HISTORY_ROWS} older failed runs are not listed.")
    lines += [
        "",
        "This issue closes automatically after the next successful main build of this image.",
        "",
    ]
    return "\n".join(lines)


def image_issues(pages: list[list[dict]]) -> dict[str, dict]:
    """The issue that owns each image: its open issue, else its newest closed one."""
    owners: dict[str, dict] = {}
    for page in pages:
        for issue in page:
            if "pull_request" in issue or not issue["title"].startswith(title("")):
                continue
            image = issue["title"].removeprefix(title(""))
            current = owners.get(image)
            rank = (issue["state"] == "open", issue["number"])
            if current is None or rank > (current["state"] == "open", current["number"]):
                owners[image] = issue
    return owners


def plan(streaks: dict[str, list[Outcome] | None], issues: dict[str, dict], now: datetime) -> list[Action]:
    actions = []
    for image, streak in sorted(streaks.items()):
        issue = issues.get(image)
        if streak is None:
            if issue is not None and issue["state"] == "open":
                actions.append(Action("close", image, issue["number"]))
            continue
        if not alerting(streak, now):
            continue
        body = issue_body(image, streak)
        if issue is None:
            actions.append(Action("create", image, body=body))
        elif issue["state"] != "open":
            actions.append(Action("reopen", image, issue["number"], body))
        elif (issue.get("body") or "") != body:
            actions.append(Action("update", image, issue["number"], body))
    return actions


def recovery_comment(outcome: Outcome) -> str:
    return (
        f"Recovered: main Build run [{outcome.run_id}]({outcome.run_url}) published this image "
        f"at {outcome.completed_at.strftime('%Y-%m-%d %H:%M UTC')}. Closing."
    )


def api(*arguments: str) -> object:
    result = subprocess.run([GH_API, *arguments], check=True, stdout=subprocess.PIPE, text=True, timeout=1800)
    return json.loads(result.stdout) if result.stdout.strip() else None


def read_pages(path: str, attempts: int = 3) -> list:
    """GET every page, retrying a transient failure. Writes are never retried."""
    for attempt in range(1, attempts + 1):
        try:
            return api("--paginate", "--slurp", path)
        except subprocess.CalledProcessError as error:
            # 75: gh_api_backoff.sh already waited out its rate-limit budget.
            if error.returncode == 75 or attempt == attempts:
                raise
            time.sleep(10)
    raise AssertionError("unreachable")


def apply(actions: list[Action], repository: str, latest: dict[str, Outcome]) -> None:
    for action in actions:
        if action.kind == "create":
            subprocess.run(
                ["gh", "label", "create", LABEL, "--repo", repository, "--force", "--color", "B60205",
                 "--description", "An image keeps failing its trusted main build"],
                check=True,
                timeout=120,
            )
            api(f"repos/{repository}/issues", "--method", "POST", "-f", f"title={title(action.image)}",
                "-f", f"body={action.body}", "-f", f"labels[]={LABEL}")
        elif action.kind in {"update", "reopen"}:
            api(f"repos/{repository}/issues/{action.issue}", "--method", "PATCH", "-f", "state=open",
                "-f", f"body={action.body}")
        elif action.kind == "close":
            api(f"repos/{repository}/issues/{action.issue}/comments", "--method", "POST",
                "-f", f"body={recovery_comment(latest[action.image])}")
            api(f"repos/{repository}/issues/{action.issue}", "--method", "PATCH", "-f", "state=closed",
                "-f", "state_reason=completed")
        print(f"{action.kind} {title(action.image)}" + (f" (#{action.issue})" if action.issue else ""))


def main() -> None:
    repository = os.environ["REPOSITORY"]
    now = datetime.now(UTC)
    since = (now - LOOKBACK).strftime("%Y-%m-%dT%H:%M:%SZ")
    pages = read_pages(f"repos/{repository}/actions/workflows/build.yaml/runs"
                       f"?branch=main&status=completed&created=%3E%3D{since}&per_page=100")
    outcomes = []
    for run in main_runs(pages, repository):
        jobs = read_pages(f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
        outcomes += run_outcomes(run, [job for page in jobs for job in page["jobs"]])
    streaks = failure_streaks(outcomes)
    latest = {outcome.image: outcome for outcome in sorted(outcomes, key=lambda item: (item.completed_at, item.run_id))}
    issues = image_issues(read_pages(f"repos/{repository}/issues?labels={LABEL}&state=all&per_page=100"))
    actions = plan(streaks, issues, now)
    failing = sorted(image for image, streak in streaks.items() if streak)
    print(f"{len(outcomes)} image outcomes from main runs since {since}; failing now: {', '.join(failing) or 'none'}")
    apply(actions, repository, latest)


if __name__ == "__main__":
    main()
