#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)




def test_smoke_versions(root: Path) -> None:
    binaries = root / "smoke-bin"
    binaries.mkdir()
    executable(
        binaries / "docker",
        """#!/bin/sh
set -eu
case "$*" in
  *argo-test*" image inspect "*) exit 2 ;;
  "image inspect --format {{.Config.User}} argo-test") printf '\n' ;;
  "image inspect --format {{.Config.WorkingDir}} argo-test") printf '/\n' ;;
  "image inspect --format {{json .Config.Entrypoint}} argo-test") printf '["argoexec"]\n' ;;
  "run --rm --cpus=4 --network none argo-test version")
    printf 'argoexec: v9.8.7+test\nGitTreeState: dirty\n' ;;
  "run --rm --cpus=4 --network none argo-test")
    printf 'argoexec is the executor sidecar to workflow containers\n' ;;
  "run --rm --cpus=4 --network none argo-test not-a-workflow-command")
    printf 'unknown command "not-a-workflow-command" for "argoexec"\n' >&2; exit 1 ;;
  "image inspect --format {{.Config.User}} trivy-test") printf '65532\n' ;;
  "run --rm trivy-test version --format json") printf '{"Version":"8.7.6"}\n' ;;
  *"trivy-test filesystem --scanners secret --format json /fixture")
    printf '{"SchemaVersion": 2, "ArtifactType": "filesystem"}\n' ;;
  "run --rm trivy-test filesystem --scanners secret /missing") exit 1 ;;
  *) printf 'unexpected docker arguments: %s\n' "$*" >&2; exit 2 ;;
esac
""",
    )
    environment = os.environ | {"PATH": f"{binaries}:{os.environ['PATH']}"}
    for image, version in (("argo-workflows", "9.8.7"), ("trivy", "8.7.6")):
        fixture = root / image
        shutil.copytree(ROOT / "images" / image, fixture)
        recipe = fixture / "melange.yaml"
        lines = recipe.read_text(encoding="utf-8").splitlines()
        lines[2] = f'  version: "{version}"'
        recipe.write_text("\n".join(lines) + "\n", encoding="utf-8")
        subprocess.run(
            [str(fixture / "tests/test.sh"), f"{image.split('-')[0]}-test"],
            check=True,
            env=environment,
        )


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        test_smoke_versions(Path(temporary))
    print("passed scripts/test_shared_ci.py")


if __name__ == "__main__":
    main()
