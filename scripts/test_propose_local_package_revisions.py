#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

from __future__ import annotations

from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import propose_local_package_revisions


def proposal(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "context": "images/example",
        "recipe": "images/example/melange.yaml",
        "package": "example",
        "version": "1.0.0",
        "fromEpoch": 2,
        "toEpoch": 3,
        "streams": ["example@1"],
    }
    value.update(overrides)
    return value


def rejects(value: dict[str, object], expected: str) -> None:
    try:
        propose_local_package_revisions.changed_recipe(value)
    except propose_local_package_revisions.ProposalError as error:
        assert expected in str(error)
    else:
        raise AssertionError("unsafe local package proposal was accepted")


def test_published_proposal_is_idempotent() -> None:
    entries = [{"path": "images/example/melange.yaml", "content": "epoch: 3\n"}]
    blob = propose_local_package_revisions.blob_sha(entries[0]["content"])

    def gh(*args: str, input: str | None = None) -> str:
        del input
        if "/compare/" in args[1]:
            return "images/example/melange.yaml\n"
        if "/contents/" in args[1]:
            return f"{blob}\n"
        raise AssertionError(args)

    with patch.object(propose_local_package_revisions, "gh", gh):
        assert propose_local_package_revisions.proposal_published(
            "owner/repo", "0" * 40, "local-package-revision/images-example", entries
        )
        assert not propose_local_package_revisions.proposal_published(
            "owner/repo", "0" * 40, "local-package-revision/images-example",
            [{"path": "images/example/other.melange.yaml", "content": "epoch: 3\n"}],
        )


def main() -> None:
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        recipe = root / "images/example/melange.yaml"
        recipe.parent.mkdir(parents=True)
        original = (
            'package:\n  name: example\n  version: "1.0.0"\n  epoch: 2  # current\n'
            "pipeline:\n  - runs: true\n"
        )
        recipe.write_text(original, encoding="utf-8")
        with patch.object(propose_local_package_revisions, "ROOT", root):
            path, changed = propose_local_package_revisions.changed_recipe(proposal())
            assert path == "images/example/melange.yaml"
            assert changed.decode() == original.replace("epoch: 2", "epoch: 3")
            rejects(proposal(toEpoch=2), "unsafe local package revision")
            rejects(proposal(version="1.0.1"), "current package identity")
            rejects(proposal(package="other"), "current package identity")
            rejects(proposal(recipe="images/example/not-a-recipe.yaml"), "not an image-local Melange recipe")
    test_published_proposal_is_idempotent()
    print("passed scripts/test_propose_local_package_revisions.py")


if __name__ == "__main__":
    main()
