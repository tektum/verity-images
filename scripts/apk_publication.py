from __future__ import annotations

import shutil
from pathlib import Path


def publish(stage: Path, output: Path) -> None:
    succeeded = False
    try:
        stage.rename(output)
        succeeded = True
    finally:
        if not succeeded and not stage.exists() and output.exists():
            shutil.rmtree(output)
