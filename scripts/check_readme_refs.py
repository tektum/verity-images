#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/check_readme_refs.py

from __future__ import annotations

import re
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).resolve().parents[1]
REFERENCE: Final[re.Pattern[str]] = re.compile(
    r"`((?:\.github|docs|images|patched|scripts)/[^`\s]+|(?:README|CONTRIBUTING|SECURITY)\.md|LICENSE)`"
)


def main() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    references: list[str] = REFERENCE.findall(readme)
    missing = sorted(reference for reference in references if not (ROOT / reference).exists())
    if missing:
        raise SystemExit("README references missing paths: " + ", ".join(missing))


if __name__ == "__main__":
    main()
