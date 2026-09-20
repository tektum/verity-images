#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile


def gh(*arguments: str) -> bytes:
    """Run one GitHub CLI request and return its bytes."""
    return subprocess.run(
        ["gh", *arguments],
        check=True,
        capture_output=True,
    ).stdout


def latest_artifact(repository: str, run_id: str, name: str) -> int:
    """Return the newest live artifact ID for one run and logical name."""
    pages = json.loads(
        gh(
            "api",
            "--paginate",
            "--slurp",
            f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100",
        )
    )
    matches = [
        artifact
        for page in pages
        for artifact in page.get("artifacts", [])
        if artifact.get("name") == name and artifact.get("expired") is False
    ]
    if not matches:
        raise ValueError(f"run {run_id} has no live {name} artifact")
    selected = max(matches, key=lambda artifact: (artifact.get("created_at", ""), artifact.get("id", -1)))
    artifact_id = selected.get("id")
    if not isinstance(artifact_id, int) or artifact_id < 1:
        raise ValueError(f"run {run_id} has an invalid {name} artifact ID")
    return artifact_id


def extract_archive(data: bytes, destination: Path) -> None:
    """Replace destination with one path-safe GitHub artifact archive."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary)
        try:
            with ZipFile(io.BytesIO(data)) as archive:
                members = archive.infolist()
                if not members:
                    raise ValueError("artifact archive is empty")
                for member in members:
                    path = PurePosixPath(member.filename)
                    mode = member.external_attr >> 16
                    if path.is_absolute() or ".." in path.parts or (mode & 0o170000) == 0o120000:
                        raise ValueError("artifact archive contains an unsafe path")
                archive.extractall(staging)
        except BadZipFile as error:
            raise ValueError("artifact archive is not a ZIP file") from error
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(staging, destination)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: download_run_artifact.py REPOSITORY RUN_ID ARTIFACT DESTINATION")
    repository, run_id, name, destination_text = sys.argv[1:]
    if not repository or not run_id.isdecimal() or not name:
        raise SystemExit("repository, numeric run ID, and artifact name are required")
    try:
        artifact_id = latest_artifact(repository, run_id, name)
        archive = gh("api", f"repos/{repository}/actions/artifacts/{artifact_id}/zip")
        extract_archive(archive, Path(destination_text))
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"artifact download failed: {error}") from error


if __name__ == "__main__":
    main()
