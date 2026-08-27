#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def test_go_bump_cap(root: Path) -> None:
    pipeline = (ROOT / "pipelines/go/bump.yaml").read_text(encoding="utf-8")
    script = textwrap.dedent(pipeline.split("  - runs: |\n", 1)[1])
    module = root / "module"
    binaries = root / "bin"
    module.mkdir()
    binaries.mkdir()
    log = root / "omnibump.log"
    executable(
        binaries / "go",
        """#!/bin/sh
set -eu
if [ "$1 $2" = 'env GOVERSION' ]; then
  printf 'go1.26.7\\n'
elif [ "$1 $2 ${3:-}" = 'work edit -json' ]; then
  printf '{"Use":[\n{"DiskPath":"one"},\n{"DiskPath":"two"}\n]}\n'
elif [ "$1 $2" = 'work edit' ] || [ "$1 $2" = 'work sync' ] || [ "$1 $2" = 'work vendor' ]; then
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$OMNIBUMP_LOG"
elif [ "$1" = -C ]; then
  [ -f "$2/go.mod" ] || exit 1
  printf '%s %s %s %s %s\\n' "$1" "$2" "$3" "$4" "${5:-}" >>"$OMNIBUMP_LOG"
else
  [ -f go.mod ] || exit 1
  printf '%s\\n' "$*" >>"$OMNIBUMP_LOG"
fi
""",
    )
    executable(
        binaries / "omnibump",
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$OMNIBUMP_LOG\"\n",
    )

    replacements = {
        "${{inputs.modroot}}": str(module),
        "${{inputs.deps}}": "example.com/module@v1.2.3",
        "${{inputs.replaces}}": "",
        "${{inputs.tidy}}": "true",
        "${{inputs.show-diff}}": "false",
        "${{inputs.tidy-compat}}": "",
        "${{inputs.work}}": "false",
    }
    environment = os.environ | {
        "PATH": f"{binaries}:{os.environ['PATH']}",
        "OMNIBUMP_LOG": str(log),
    }
    module.joinpath("go.mod").write_text("module example.com/root\n", encoding="utf-8")
    for requested, expected in (("", "1.26.7"), ("1.27.0", "1.26.7"), ("1.25.0", "1.25.0")):
        log.write_text("", encoding="utf-8")
        rendered = script.replace("${{inputs.go-version}}", requested)
        for source, target in replacements.items():
            rendered = rendered.replace(source, target)
        subprocess.run(["sh", "-eu", "-c", rendered], check=True, env=environment)
        calls = log.read_text(encoding="utf-8")
        assert f"mod edit -go={expected}" in calls
        assert "--language go --dir . --packages example.com/module@v1.2.3" in calls

    module.joinpath("go.mod").unlink()
    for name in ("one", "two"):
        child = module / name
        child.mkdir()
        child.joinpath("go.mod").write_text(f"module example.com/{name}\\n", encoding="utf-8")
    module.joinpath("go.work").write_text("go 1.26\\nuse ./one\\nuse ./two\\n", encoding="utf-8")
    log.write_text("", encoding="utf-8")
    rendered = script.replace("${{inputs.go-version}}", "1.27.0")
    for source, target in replacements.items():
        rendered = rendered.replace(source, target)
    subprocess.run(["sh", "-eu", "-c", rendered], check=True, env=environment)
    calls = log.read_text(encoding="utf-8")
    assert "work edit -go=1.26.7\n" in calls
    for name in ("one", "two"):
        assert f"-C {name} mod edit -go=1.26.7" in calls
    assert "gobump" not in pipeline


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
        root = Path(temporary)
        test_go_bump_cap(root)
        test_smoke_versions(root)
    print("passed scripts/test_shared_ci.py")


if __name__ == "__main__":
    main()
