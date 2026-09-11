#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/validate_security_floor_pr.py PR COMMIT FILES OUTPUT

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPOSITORY = "tektum/verity-images"
RENOVATE_LOGIN = "renovate[bot]"
RECIPE = re.compile(r"^(?:images|packages|patched)/.+/[^/]*melange\.ya?ml$")
ANNOTATED_VERSION = re.compile(
    r"^(?P<prefix>.*?)(?P<version>v?[0-9][0-9A-Za-z.+_-]*)"
    r"(?P<suffix>[\"']?,?[ \t]+#[ \t]*renovate:[ \t]*"
    r"datasource=(?P<datasource>\S+)[ \t]+depName=\S+"
    r"(?:[ \t]+versioning=(?P<versioning>\S+))?[ \t]*)$"
)
SEMVER = re.compile(
    r"^v?(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\."
    r"(?P<patch>0|[1-9][0-9]*)(?:-(?P<pre>[0-9A-Za-z.-]+))?"
    r"(?:\+[0-9A-Za-z.-]+)?$"
)
MAVEN = re.compile(r"^(?P<numbers>[0-9]+(?:\.[0-9]+)*)(?P<qualifier>[.-][0-9A-Za-z.-]+)?$")


class ValidationError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def change_blocks(patch: str) -> list[tuple[list[str], list[str]]]:
    blocks: list[tuple[list[str], list[str]]] = []
    removed: list[str] = []
    added: list[str] = []

    def flush() -> None:
        if removed or added:
            blocks.append((removed.copy(), added.copy()))
            removed.clear()
            added.clear()

    for line in patch.splitlines():
        if line.startswith(("@@", "\\")):
            flush()
        elif line.startswith("-") and not line.startswith("---"):
            removed.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:])
        else:
            flush()
    flush()
    return blocks


def prerelease_key(value: str) -> tuple[tuple[int, object], ...]:
    return tuple(
        (0, int(part)) if part.isdecimal() else (1, part)
        for part in value.split(".")
    )


def is_upgrade(old: str, new: str, scheme: str) -> bool:
    if scheme in {"go", "semver", "semver-coerced"}:
        before = SEMVER.fullmatch(old)
        after = SEMVER.fullmatch(new)
        if before is None or after is None:
            return False
        old_core = tuple(int(before[name]) for name in ("major", "minor", "patch"))
        new_core = tuple(int(after[name]) for name in ("major", "minor", "patch"))
        if old_core != new_core:
            return new_core > old_core
        old_pre = before["pre"]
        new_pre = after["pre"]
        if old_pre is None or new_pre is None:
            return old_pre is not None and new_pre is None
        return prerelease_key(new_pre) > prerelease_key(old_pre)
    if scheme == "maven":
        before = MAVEN.fullmatch(old)
        after = MAVEN.fullmatch(new)
        if before is None or after is None:
            return False
        if (before["qualifier"] or "").lower() != (after["qualifier"] or "").lower():
            return False
        old_numbers = tuple(int(part) for part in before["numbers"].split("."))
        new_numbers = tuple(int(part) for part in after["numbers"].split("."))
        return new_numbers > old_numbers
    return False


def validate_patch(path: str, patch: object) -> None:
    require(isinstance(patch, str) and patch, f"{path}: diff patch is unavailable")
    blocks = change_blocks(str(patch))
    require(bool(blocks), f"{path}: diff has no changed lines")
    for removed, added in blocks:
        require(removed and len(removed) == len(added), f"{path}: diff block is not paired")
        for before, after in zip(removed, added, strict=True):
            old = ANNOTATED_VERSION.fullmatch(before)
            new = ANNOTATED_VERSION.fullmatch(after)
            require(old is not None and new is not None, f"{path}: non-floor line changed")
            require(old["prefix"] == new["prefix"], f"{path}: floor location changed")
            require(old["suffix"] == new["suffix"], f"{path}: Renovate annotation changed")
            scheme = new["versioning"] or new["datasource"]
            require(is_upgrade(old["version"], new["version"], scheme), f"{path}: floor version is not an upgrade")


def validate(
    pull: object, commit: object, files: object
) -> tuple[int, str]:
    require(isinstance(pull, dict), "pull request metadata must be an object")
    require(isinstance(commit, dict), "commit metadata must be an object")
    require(isinstance(files, list) and files, "pull request files must be a non-empty array")

    user = pull.get("user") or {}
    head = pull.get("head") or {}
    base = pull.get("base") or {}
    labels = {
        label.get("name")
        for label in pull.get("labels") or []
        if isinstance(label, dict)
    }
    number = pull.get("number")
    sha = head.get("sha") if isinstance(head, dict) else None
    title = pull.get("title")
    body = pull.get("body")

    require(pull.get("state") == "open" and pull.get("draft") is False, "PR is not open and ready")
    require(isinstance(user, dict) and user.get("login") == RENOVATE_LOGIN, "PR author is not Renovate")
    require(user.get("type") == "Bot", "Renovate author is not a bot identity")
    require(isinstance(base, dict) and base.get("ref") == "main", "PR base is not main")
    require(isinstance(head, dict) and head.get("repo", {}).get("full_name") == REPOSITORY, "PR head is not in the trusted repository")
    require(isinstance(head.get("ref"), str) and head["ref"].startswith("renovate/"), "PR head is not a Renovate branch")
    require(labels >= {"security-floor", "review-required"}, "PR lacks security-floor labels")
    require(isinstance(title, str) and title.endswith("[security]"), "PR title is not a security update")
    require(isinstance(body, str) and "<!--renovate-debug:" in body, "PR lacks Renovate metadata")
    require(isinstance(number, int) and number > 0, "PR number is invalid")
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "PR head SHA is invalid")
    require(pull.get("changed_files") == len(files), "PR file list is incomplete")

    commit_author = commit.get("author") or {}
    commit_committer = commit.get("committer") or {}
    commit_record = commit.get("commit") or {}
    git_author = commit_record.get("author") or {}
    git_committer = commit_record.get("committer") or {}
    verification = commit_record.get("verification") or {}
    require(commit.get("sha") == sha, "commit metadata does not match PR head")
    require(isinstance(commit_author, dict) and commit_author.get("login") == RENOVATE_LOGIN, "head commit author is not Renovate")
    require(isinstance(commit_committer, dict) and commit_committer.get("login") == "web-flow", "head commit was not pushed through GitHub's trusted flow")
    require(git_author == {"name": RENOVATE_LOGIN, "email": "29139614+renovate[bot]@users.noreply.github.com", "date": git_author.get("date")}, "Git author identity is not Renovate")
    require(git_committer == {"name": "GitHub", "email": "noreply@github.com", "date": git_committer.get("date")}, "Git committer identity is not GitHub")
    require(verification.get("verified") is True and verification.get("reason") == "valid", "Renovate head commit lacks a valid GitHub signature")
    require(len(commit.get("parents") or []) == 1, "Renovate head is not a single-parent commit")

    for file in files:
        require(isinstance(file, dict), "PR file entry must be an object")
        path = file.get("filename")
        require(isinstance(path, str) and RECIPE.fullmatch(path) is not None, "PR changes a non-Melange file")
        require(file.get("status") == "modified", f"{path}: file was not modified in place")
        validate_patch(path, file.get("patch"))
    return number, sha


def load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"{path}: {error}") from error


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: validate_security_floor_pr.py PR COMMIT FILES OUTPUT")
    pull_path, commit_path, files_path, output_path = map(Path, sys.argv[1:])
    try:
        number, sha = validate(load(pull_path), load(commit_path), load(files_path))
    except ValidationError as error:
        raise SystemExit(f"untrusted security-floor PR: {error}") from error
    with output_path.open("a", encoding="utf-8") as output:
        output.write(f"pr-number={number}\nhead-sha={sha}\n")


if __name__ == "__main__":
    main()
