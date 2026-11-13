#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_catalog_discovery.py
#
# Runs the catalog "Discover build runs" step against a stub GitHub API that
# applies the runs endpoint's `created` filter and its 1000-result cap, and
# checks that bounded discovery consumes the same runs as an unbounded walk
# while skipping the per-run artifact calls for runs that cannot be consumed.

from __future__ import annotations

import io
import json
import os
import subprocess
import textwrap
from datetime import UTC, datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final
from zipfile import ZipFile

ROOT: Final = Path(__file__).resolve().parents[1]
REPOSITORY: Final = "owner/repo"
PUBLISHED: Final = datetime(2026, 11, 10, 12, tzinfo=UTC)

STUB_GH: Final = r'''#!/usr/bin/env python3
import json, os, sys
from urllib.parse import parse_qs, urlsplit

fixture = json.load(open(os.environ["FIXTURE"]))
arguments = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(" ".join(arguments) + "\n")
assert arguments[0] == "api", arguments
path = next(a for a in arguments[1:] if not a.startswith("-"))
url = urlsplit(path)
parts = url.path.split("/")
listing = os.environ.get("LISTED_ONCE") and os.path.exists(os.environ["LISTED_ONCE"])
if urlsplit(path).path.endswith("/actions/workflows/build.yaml/runs"):
    # Runs that complete between two listing queries.
    if listing:
        later = {run["id"]: run for run in fixture.get("later", [])}
        fixture["runs"] = [later.get(run["id"], run) for run in fixture["runs"]]
    open(os.environ["LISTED_ONCE"], "a").close()
runs = {str(run["id"]): run for run in fixture["runs"]}

def emit(value):
    sys.stdout.write(json.dumps(value))

if url.path.endswith("/actions/workflows/build.yaml/runs"):
    query = parse_qs(url.query)
    created = query.get("created", [""])[0]
    selected = sorted(fixture["runs"], key=lambda run: run["created_at"], reverse=True)
    if created.startswith(">="):
        selected = [run for run in selected if run["created_at"] >= created[2:]]
    elif ".." in created:
        low, high = created.split("..")
        selected = [run for run in selected if low <= run["created_at"] <= high]
    else:
        assert not created, created
    total = len(selected)
    visible = selected[:1000]  # The API returns at most 1000 filtered results.
    pages = [visible[i:i + 100] for i in range(0, len(visible), 100)] or [[]]
    emit([{"total_count": total, "workflow_runs": page} for page in pages])
elif url.path.endswith("/artifacts"):
    emit([{"total_count": 0, "artifacts": fixture["artifacts"].get(parts[-2], [])}])
elif url.path.endswith("/zip"):
    sys.stdout.buffer.write(bytes.fromhex(fixture["zip"]))
elif parts[-2] == "runs" and parts[-1] in runs:
    emit(runs[parts[-1]])
else:
    sys.exit(f"unexpected gh call: {arguments}")
'''


def iso(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def discovery_script() -> str:
    catalog = (ROOT / ".github/workflows/catalog.yaml").read_text(encoding="utf-8")
    step = catalog.split("      - name: Discover build runs\n", maxsplit=1)[1]
    step = step.split("\n      - name: ", maxsplit=1)[0]
    env, run = step.split("        run: |\n", maxsplit=1)
    constants = {
        key.strip(): value.strip().strip('"')
        for key, value in (
            line.split(":", maxsplit=1)
            for line in env.splitlines()
            if line.startswith("          ") and not line.strip().startswith("#")
        )
        if "${{" not in value
    }
    assert set(constants) >= {
        "DISCOVERY_LOOKBACK_SECONDS",
        "DISCOVERY_MARGIN_SECONDS",
        "GH_RATE_LIMIT_MAX_WAIT",
    }, constants
    exports = "".join(f"export {key}={value}\n" for key, value in constants.items())
    return exports + textwrap.dedent(run)


def run(
    number: int,
    *,
    created: datetime,
    updated: datetime,
    head_sha: str,
    conclusion: str = "success",
    attempt: int = 1,
) -> dict[str, object]:
    return {
        "id": number,
        "name": "Build images",
        "path": ".github/workflows/build.yaml",
        "head_branch": "main",
        "head_repository": {"full_name": REPOSITORY},
        "head_sha": head_sha,
        "event": "push",
        "status": "completed",
        "conclusion": conclusion,
        "run_attempt": attempt,
        "created_at": iso(created),
        "updated_at": iso(updated),
        "html_url": f"https://github.com/{REPOSITORY}/actions/runs/{number}",
    }


def report_zip() -> str:
    buffer = io.BytesIO()
    with ZipFile(buffer, "w") as archive:
        archive.writestr("build-report.json", json.dumps({"images": [{"name": "x", "version": "1"}]}))
    return buffer.getvalue().hex()


def consumable(number: int) -> list[dict[str, object]]:
    return [
        {"id": number * 10, "name": "build-report", "expired": False, "created_at": "2026-11-10T00:00:00Z"},
        {"id": number * 10 + 1, "name": "scan-x-1", "expired": False, "created_at": "2026-11-10T00:00:00Z"},
    ]


def discover(
    work: Path,
    runs: list[dict[str, object]],
    artifacts: dict[str, list[dict[str, object]]],
    *,
    previous: dict[str, object] | None,
    event_run: int,
    later: list[dict[str, object]] | None = None,
    succeed: bool = True,
) -> tuple[list[tuple[int, int]], list[str], str]:
    for name in ("input", "previous.json", "reconciliation.json", "catalog-source.json"):
        subprocess.run(["rm", "-rf", str(work / name)], check=True)
    if previous is not None:
        (work / "previous.json").write_text(json.dumps(previous), encoding="utf-8")
    fixture = work / "fixture.json"
    fixture.write_text(
        json.dumps({"runs": runs, "later": later or [], "artifacts": artifacts, "zip": report_zip()}),
        encoding="utf-8",
    )
    (work / "listed-once").unlink(missing_ok=True)
    calls = work / "calls.log"
    calls.write_text("", encoding="utf-8")
    output = work / "github-output"
    output.write_text("", encoding="utf-8")
    temp = work / "runner-temp"
    temp.mkdir(exist_ok=True)
    result = subprocess.run(
        ["bash", "-c", discovery_script()],
        cwd=work,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
            "FIXTURE": str(fixture),
            "CALL_LOG": str(calls),
            "LISTED_ONCE": str(work / "listed-once"),
            "GITHUB_OUTPUT": str(output),
            "RUNNER_TEMP": str(temp),
            "EVENT": "workflow_run",
            "EVENT_RUN_ID": str(event_run),
            "DISPATCH_RUN_ID": "",
            "MODE": "images",
            "REPOSITORY": REPOSITORY,
        },
    )
    assert (result.returncode == 0) == succeed, result.stdout + result.stderr
    consumed: list[tuple[int, int]] = []
    if "ready=true" in output.read_text(encoding="utf-8"):
        reconciliation = json.loads((work / "reconciliation.json").read_text(encoding="utf-8"))
        consumed = [(item["id"], item["run_attempt"]) for item in reconciliation]
    return consumed, calls.read_text(encoding="utf-8").splitlines(), result.stdout


def main() -> None:
    with TemporaryDirectory() as temporary_directory:
        work = Path(temporary_directory)
        (work / "bin").mkdir()
        (work / "bin/gh").write_text(STUB_GH, encoding="utf-8")
        (work / "bin/gh").chmod(0o755)
        (work / "scripts").symlink_to(ROOT / "scripts")
        git = ["git", "-c", "user.email=test@example.com", "-c", "user.name=test", "-C", str(work)]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "base"], check=True)
        head = subprocess.run(
            [*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()

        hours = lambda value: timedelta(hours=value)  # noqa: E731
        consumed_run = run(100, created=PUBLISHED - hours(1), updated=PUBLISHED, head_sha=head)
        # Failed long before the published catalog without a build report: it
        # can never be consumed, so bounded discovery must not keep asking.
        dead = run(101, created=PUBLISHED - hours(48), updated=PUBLISHED - hours(47), head_sha=head,
                   conclusion="failure")
        # Queued for a day before it completed after the published catalog.
        slow = run(102, created=PUBLISHED - hours(30), updated=PUBLISHED + hours(2), head_sha=head)
        fresh = run(103, created=PUBLISHED + hours(1), updated=PUBLISHED + hours(2), head_sha=head)
        # A report that landed just before publication but whose artifacts were
        # not yet listed then: inside the completion margin, still consumed.
        lagging = run(104, created=PUBLISHED - hours(2), updated=PUBLISHED - hours(1), head_sha=head)
        # A re-run of a run created before the lookback. Behind 1000 newer runs
        # only its own workflow_run event delivers it; otherwise the first,
        # unfiltered query still lists it as it did before.
        rerun = run(105, created=PUBLISHED - hours(24 * 5), updated=PUBLISHED + hours(3), head_sha=head,
                    attempt=2)
        # More cancelled runs than one runs query returns, all newer than the
        # slow run, so it is only reachable through a second created slice.
        fillers = [
            run(1000 + index, created=PUBLISHED - hours(29) + timedelta(minutes=index),
                updated=PUBLISHED - hours(29) + timedelta(minutes=index + 5), head_sha=head,
                conclusion="cancelled")
            for index in range(1100)
        ]
        assert all(filler["updated_at"] < iso(PUBLISHED - hours(6)) for filler in fillers)
        # The oldest run in the first (newest 1000) query is listed again by the
        # inclusive created slice. It completes between the two queries, and
        # the completed snapshot must win over the in-progress one.
        boundary = fillers[103]
        assert boundary["id"] == 1103
        fillers[103] = {
            **boundary, "status": "in_progress", "conclusion": None, "updated_at": iso(PUBLISHED + hours(3))
        }
        boundary_done = {**boundary, "conclusion": "success", "updated_at": iso(PUBLISHED + hours(4))}
        runs = [consumed_run, dead, slow, fresh, lagging, rerun, *fillers]
        artifacts = {str(number): consumable(number) for number in (100, 102, 103, 104, 105, 1103)}
        previous = {
            "publishedAt": iso(PUBLISHED),
            "source": {"runId": "100", "consumedRuns": {"100": 1}},
        }

        consumed, calls, stdout = discover(
            work, runs, artifacts, previous=previous, event_run=103, later=[boundary_done]
        )
        assert consumed == [(104, 1), (102, 1), (103, 1), (1103, 1)], consumed
        listings = [call for call in calls if "/workflows/build.yaml/runs" in call]
        assert len(listings) == 2, listings
        assert "created=" not in listings[0], listings
        assert "created=2026-11-07T12%3A00%3A00Z..2026-11-09" in listings[1], listings
        artifact_runs = {call.split("/runs/")[1].split("/")[0] for call in calls if "/artifacts?" in call}
        assert artifact_runs == {"102", "103", "104", "1103"}, artifact_runs
        assert "created since 2026-11-07T12:00:00Z, completed since 2026-11-10T06:00:00Z" in stdout

        # The re-run of an old run is outside the listing but consumed through
        # its own event.
        consumed, _, _ = discover(work, runs, artifacts, previous=previous, event_run=105)
        assert consumed == [(104, 1), (102, 1), (103, 1), (105, 2)], consumed
        consumed, _, _ = discover(
            work, [consumed_run, dead, slow, fresh, lagging, rerun], artifacts, previous=previous, event_run=103
        )
        assert consumed == [(104, 1), (102, 1), (103, 1), (105, 2)], consumed

        # Without a published catalog every page is listed in one query and the
        # result matches the bounded walk for the same ledger (reference walk:
        # no lookback, no completion filter, no 1000 cap on this small set).
        small = [consumed_run, dead, slow, fresh, lagging]
        unbounded = {**previous, "publishedAt": "1970-01-04T00:00:00Z"}
        reference, _, _ = discover(work, small, artifacts, previous=unbounded, event_run=103)
        bounded, _, _ = discover(work, small, artifacts, previous=previous, event_run=103)
        assert reference == bounded == [(104, 1), (102, 1), (103, 1)], (reference, bounded)
        consumed, calls, stdout = discover(work, small, artifacts, previous=None, event_run=103)
        assert consumed == [(104, 1), (100, 1), (102, 1), (103, 1)], consumed
        listings = [call for call in calls if "/workflows/build.yaml/runs" in call]
        assert len(listings) == 1 and "created=" not in listings[0], listings
        assert "created since any time, completed since any time" in stdout

        # Queued-catalog race: this catalog run checked out `head`, but a build
        # of a newer main commit completed before it started discovering. That
        # candidate is deferred (its own completion triggers a later catalog
        # run) and the ledger leaves it unconsumed. One newer commit was fetched
        # into the checkout; the other is not in it at all.
        newer = subprocess.run(
            [*git, "commit-tree", "-p", head, "-m", "newer", f"{head}^{{tree}}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        queued = run(106, created=PUBLISHED + hours(1), updated=PUBLISHED + hours(5), head_sha=newer)
        unfetched = run(107, created=PUBLISHED + hours(2), updated=PUBLISHED + hours(6), head_sha="f" * 40)
        race_artifacts = {**artifacts, "106": consumable(106), "107": consumable(107)}
        consumed, calls, stdout = discover(
            work, [*small, queued, unfetched], race_artifacts, previous=previous, event_run=103
        )
        assert consumed == [(104, 1), (102, 1), (103, 1)], consumed
        for deferred in ("106", "107"):
            assert f"::notice title=Build run deferred::Run {deferred}: commit " in stdout, stdout
            assert not any(f"/runs/{deferred}/" in call for call in calls), calls
        assert f"{newer} is not an ancestor of HEAD {head}" in stdout, stdout
        assert f"{'f' * 40} is not in the checkout at HEAD {head}" in stdout, stdout
        ledger = json.loads((work / "catalog-source.json").read_text(encoding="utf-8"))
        assert ledger["consumedRuns"] == {"100": 1, "102": 1, "103": 1, "104": 1}, ledger

        # The explicit run is never deferred: a run newer than the checkout that
        # triggered this catalog run fails it.
        _, _, stdout = discover(
            work, [*small, queued], race_artifacts, previous=previous, event_run=106, succeed=False
        )
        assert f"::error title=Catalog not updated::Run 106 failed identity validation: commit {newer}" in stdout

        # The later catalog run triggered by the deferred build's completion
        # checks out its commit and consumes it from the ledger left above.
        subprocess.run([*git, "reset", "-q", newer], check=True)
        follow_up = {"publishedAt": iso(PUBLISHED + hours(2)), "source": ledger}
        consumed, _, stdout = discover(
            work, [*small, queued], race_artifacts, previous=follow_up, event_run=106
        )
        assert consumed == [(106, 1)], consumed
        assert "deferred" not in stdout, stdout
        subprocess.run([*git, "reset", "-q", head], check=True)

        # Every other identity condition stays fatal, for candidates as well as
        # the explicit run, and names the run and the reason.
        branch = {**run(108, created=PUBLISHED + hours(1), updated=PUBLISHED + hours(3), head_sha=head),
                  "head_branch": "feature"}
        _, _, stdout = discover(
            work, [*small, branch], {**artifacts, "108": consumable(108)}, previous=previous,
            event_run=103, succeed=False,
        )
        assert ('::error title=Catalog not updated::Run 108 failed identity validation: '
                'head branch is "feature", expected "main".') in stdout, stdout
        foreign = {**run(109, created=PUBLISHED + hours(1), updated=PUBLISHED + hours(3), head_sha=head),
                   "head_repository": {"full_name": "fork/repo"}}
        _, _, stdout = discover(
            work, [*small, foreign], {**artifacts, "109": consumable(109)}, previous=previous,
            event_run=109, succeed=False,
        )
        assert ('::error title=Catalog not updated::Run 109 failed identity validation: '
                'head repository is "fork/repo", expected "owner/repo".') in stdout, stdout
        renamed = {**run(110, created=PUBLISHED + hours(1), updated=PUBLISHED + hours(3), head_sha=newer),
                   "path": ".github/workflows/other.yaml"}
        _, _, stdout = discover(
            work, [*small, renamed], {**artifacts, "110": consumable(110)}, previous=previous,
            event_run=103, succeed=False,
        )
        assert "Run 110 failed identity validation: workflow path is" in stdout, stdout

    print("passed scripts/test_catalog_discovery.py")


if __name__ == "__main__":
    main()
