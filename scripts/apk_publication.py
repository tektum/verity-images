from __future__ import annotations

import shutil
from pathlib import Path


def publish(stage: Path, output: Path) -> None:
    published = False
    succeeded = False
    try:
        published = True
        stage.rename(output)
        succeeded = True
    finally:
        if published and not succeeded and output.exists():
            shutil.rmtree(output)
