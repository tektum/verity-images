#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_workflow_policy.py

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def job(workflow: str, name: str) -> str:
    start = f"  {name}:\n"
    tail = workflow.split(start, maxsplit=1)[1]
    return re.split(r"\n  [a-z-]+:\n", tail, maxsplit=1)[0]


def main() -> None:
    workflow = (ROOT / ".github/workflows/apk-repository.yaml").read_text(encoding="utf-8")
    for name, requirement in (
        ("package-build", "runs-on: ubuntu-24.04-arm"),
        ("package-qa", "needs: package-build"),
        ("fips-runtime", "needs: package-qa"),
    ):
        block = job(workflow, name)
        assert "runs-on: ubuntu-24.04-arm" in block
        assert "uname -m | grep -qx aarch64" in block
        assert "setup-qemu" not in block
        assert requirement in block
    assert "package-build, package-qa, fips-runtime" in job(workflow, "package-gate")


if __name__ == "__main__":
    main()
