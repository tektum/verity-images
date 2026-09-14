#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Open image-local, reviewed Melange epoch revision proposals."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Final

import classify_monitor_remediation

ROOT: Final = Path(__file__).resolve().parents[1]
BRANCH_PREFIX: Final = "local-package-revision/"


class ProposalError(ValueError):
    pass


def gh(*args: str, input: str | None = None) -> str:
    return subprocess.run(["gh", *args], cwd=ROOT, input=input, text=True, check=True, capture_output=True).stdout


def require_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ProposalError(f"{label} must be a non-empty string")
    return value


def require_epoch(value: object, label: str) -> int:
    if type(value) is not int or value < 0:
        raise ProposalError(f"{label} must be a non-negative integer")
    return value


def changed_recipe(proposal: dict[str, object]) -> tuple[str, bytes]:
    context = require_string(proposal.get("context"), "proposal.context")
    recipe = require_string(proposal.get("recipe"), "proposal.recipe")
    package = require_string(proposal.get("package"), "proposal.package")
    version = require_string(proposal.get("version"), "proposal.version")
    before = require_epoch(proposal.get("fromEpoch"), "proposal.fromEpoch")
    after = require_epoch(proposal.get("toEpoch"), "proposal.toEpoch")
    streams = proposal.get("streams")
    context_path = Path(context)
    if (
        after <= before
        or not context.startswith("images/")
        or any(part in {"", ".", ".."} for part in context_path.parts)
        or not isinstance(streams, list)
        or not streams
        or not all(isinstance(stream, str) and stream for stream in streams)
    ):
        raise ProposalError(f"{context}: unsafe local package revision proposal")
    if not recipe.startswith(f"{context}/"):
        raise ProposalError(f"{recipe}: not an image-local Melange recipe")
    path = ROOT / recipe
    try:
        path.resolve().relative_to((ROOT / context).resolve())
    except ValueError as error:
        raise ProposalError(f"{recipe}: not an image-local Melange recipe") from error
    if not path.is_file() or path.suffix != ".yaml" or (
        path.name != "melange.yaml" and not path.name.endswith(".melange.yaml")
    ):
        raise ProposalError(f"{recipe}: not an image-local Melange recipe")
    identity = classify_monitor_remediation.recipe_identity(path)
    if identity != classify_monitor_remediation.RecipeIdentity(package, version, before):
        raise ProposalError(f"{recipe}: current package identity does not match proposal")
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(rf"^(  epoch:\s*){before}(\s*(?:#.*)?)$", re.MULTILINE)
    rewritten, count = pattern.subn(rf"\g<1>{after}\2", text)
    if count != 1:
        raise ProposalError(f"{recipe}: expected exactly one package epoch line")
    return recipe, rewritten.encode()


def open_pr_count(repository: str, branch: str) -> int:
    return int(gh("pr", "list", "--repo", repository, "--head", branch, "--state", "open", "--json", "number", "--jq", "length").strip())


def create_pr(repository: str, base: str, branch: str, context: str, recipes: list[str], run_url: str) -> None:
    body = (
        f"Automated local-package revision proposal for `{context}`.\n\n"
        "This changes only the reviewed Melange package epoch after a monitor finding "
        "named the same local package at the same package version with a higher epoch. "
        "It does not infer an upstream version.\n\n"
        "Changed recipes:\n" + "".join(f"- `{recipe}`\n" for recipe in recipes) +
        "\nReview and merge only after the normal image validation passes.\n" +
        (f"\nProposed by {run_url}\n" if run_url else "")
    )
    gh("pr", "create", "--repo", repository, "--base", base, "--head", branch,
       "--title", f"fix({context}): revise local package epoch", "--body", body)

def propose(repository: str, base_sha: str, base: str, proposals: list[dict[str, object]], run_url: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", base_sha):
        raise ProposalError("BASE_SHA must be a full commit SHA")
    base_tree = gh("api", f"repos/{repository}/git/commits/{base_sha}", "--jq", ".tree.sha").strip()
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for proposal in proposals:
        grouped[require_string(proposal.get("context"), "proposal.context")].append(proposal)
    for context, group in sorted(grouped.items()):
        entries = []
        recipes = []
        for proposal in group:
            recipe, contents = changed_recipe(proposal)
            recipes.append(recipe)
            entries.append({"path": recipe, "mode": "100644", "type": "blob", "content": contents.decode()})
        if len({entry["path"] for entry in entries}) != len(entries):
            raise ProposalError(f"{context}: duplicate recipe proposal")
        branch = f"{BRANCH_PREFIX}{context.replace('/', '-')}"
        if branch == base:
            raise ProposalError(f"{context}: unusable proposal branch")
        try:
            head = gh("api", f"repos/{repository}/git/ref/heads/{branch}", "--jq", ".object.sha").strip()
        except subprocess.CalledProcessError:
            head = ""
        open_count = open_pr_count(repository, branch) if head else 0
        if open_count > 1:
            raise ProposalError(f"{context}: {open_count} open pull requests for {branch}")
        tree = gh("api", "--method", "POST", f"repos/{repository}/git/trees", "--input", "-", "--jq", ".sha",
                  input=json.dumps({"base_tree": base_tree, "tree": entries})).strip()
        commit = gh("api", "--method", "POST", f"repos/{repository}/git/commits",
                    "-f", f"message=fix({context}): revise local package epoch",
                    "-f", f"tree={tree}", "-f", f"parents[]={base_sha}", "--jq", ".sha").strip()
        if head:
            gh("api", "--method", "PATCH", f"repos/{repository}/git/refs/heads/{branch}", "-f", f"sha={commit}", "-F", "force=true", "--silent")
        else:
            gh("api", "--method", "POST", f"repos/{repository}/git/refs", "-f", f"ref=refs/heads/{branch}", "-f", f"sha={commit}", "--silent")
        if open_count == 0:
            create_pr(repository, base, branch, context, sorted(recipes), run_url)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: propose_local_package_revisions.py PROPOSALS_JSON")
    try:
        value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        if not isinstance(value, list) or not value or not all(isinstance(item, dict) for item in value):
            raise ProposalError("proposals must be a non-empty array")
        repository = os.environ["REPOSITORY"]
        base_sha = os.environ["BASE_SHA"]
        if not os.environ.get("GH_TOKEN"):
            raise ProposalError("GH_TOKEN must be a GitHub App installation token")
        propose(repository, base_sha, os.environ.get("BASE_BRANCH", "main"), value, os.environ.get("RUN_URL", ""))
    except (OSError, json.JSONDecodeError, KeyError, ProposalError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"local package revision proposal refused: {error}") from error


if __name__ == "__main__":
    main()
