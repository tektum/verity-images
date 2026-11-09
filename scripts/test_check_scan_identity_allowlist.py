#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_check_scan_identity_allowlist.py

import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

import check_scan_identity_allowlist as check

DIRECTORY = check.DIRECTORY


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def commit(root: Path, message: str) -> str:
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)
    return git(root, "rev-parse", "HEAD")


def write(root: Path, name: str, text: str = "identity\nreason\n") -> None:
    path = root / DIRECTORY / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> None:
    with TemporaryDirectory() as directory:
        root = Path(directory)
        git(root, "init", "-q", "-b", "main")
        write(root, "README.md", "notes\n")
        write(root, "images__a")
        write(root, "images__b")
        base = commit(root, "base")

        git(root, "checkout", "-q", "-b", "change")
        (root / DIRECTORY / "images__a").unlink()
        write(root, "images__b", "go-version\nchanged reason\n")
        commit(root, "delete one, edit one")
        assert check.added_entries(root, base) == [], "deleting or editing an entry must pass"

        # A main that moved on does not make the pull request look like it added anything.
        git(root, "checkout", "-q", "main")
        write(root, "images__c")
        moved = commit(root, "main adds c")
        git(root, "checkout", "-q", "change")
        assert check.added_entries(root, moved) == [], "entries added on the base are not this change's"

        write(root, "images__e")
        commit(root, "add e")
        assert check.added_entries(root, base) == [f"{DIRECTORY}/images__e"], "a new entry must fail"
        git(root, "mv", f"{DIRECTORY}/images__b", f"{DIRECTORY}/images__d")
        commit(root, "rename b")
        assert check.added_entries(root, base) == [f"{DIRECTORY}/images__d", f"{DIRECTORY}/images__e"], "a rename adds"

        assert check.added_entries(root, "0" * 40) is None, "no base and no origin/main must skip"
        try:
            check.added_entries(root, "1" * 40)
        except SystemExit:
            pass
        else:
            raise AssertionError("a base missing from the clone was accepted")

    with TemporaryDirectory() as directory:
        root = Path(directory)
        git(root, "init", "-q", "-b", "main")
        (root / "file").write_text("x\n", encoding="utf-8")
        base = commit(root, "base without the directory")
        write(root, "README.md", "notes\n")
        write(root, "images__a")
        commit(root, "introduce the directory")
        assert check.added_entries(root, base) == [], "the introducing change adds every entry once"
    print("passed scripts/test_check_scan_identity_allowlist.py")


if __name__ == "__main__":
    main()
