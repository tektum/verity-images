#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/check_pages_size.py pages

from __future__ import annotations

import sys
from pathlib import Path
from typing import Final


MAX_PAGES_BYTES: Final = 900 * 1024 * 1024


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_pages_size.py DIRECTORY")
    pages = Path(sys.argv[1])
    size = sum(path.stat().st_size for path in pages.rglob("*") if path.is_file())
    if size >= MAX_PAGES_BYTES:
        raise SystemExit(f"Pages artifact is {size} bytes; must be below {MAX_PAGES_BYTES} bytes")


if __name__ == "__main__":
    main()
