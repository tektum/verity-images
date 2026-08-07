#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
# How to run:
#   uv run scripts/test_apk_replacement_inputs.py

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Final


ROOT: Final = Path(__file__).resolve().parents[1]
WORKFLOW: Final = ROOT / ".github/workflows/apk-repository.yaml"
PACKAGES: Final = (("openssl-fips-provider", "3.1.2-r3"), ("gosu", "1.19-r0"))
ARCHITECTURES: Final = ("aarch64", "x86_64")


def sign(replacement: str, package: str, version: str) -> None:
    apk = f"{package}-{version}.apk"
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        binaries = root / "bin"
        binaries.mkdir()
        for name, body in (("gh", "#!/bin/sh\nprintf '1\\n'\n"), ("melange", "#!/bin/sh\nexit 0\n")):
            binary = binaries / name
            binary.write_text(body, encoding="utf-8")
            binary.chmod(0o755)
        packages = []
        source_bytes = {}
        for architecture in ARCHITECTURES:
            content = f"{package}-{architecture}".encode()
            source = root / "input" / f"apk-build-{package}-{architecture}" / apk
            source.parent.mkdir(parents=True)
            source.write_bytes(content)
            source_bytes[architecture] = content
            packages.append(
                {
                    "architecture": architecture,
                    "name": package,
                    "path": f"{architecture}/{apk}",
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "origin": {
                        "sourceCommit": "1" * 40,
                        "runId": 2,
                        "artifactId": 3,
                        "artifactSha256": "sha256:" + "4" * 64,
                        "unsignedSha256": hashlib.sha256(content).hexdigest(),
                    },
                }
            )
        (root / "release").mkdir()
        (root / "release" / "reservation.json").write_text(
            json.dumps({"unsignedPackages": packages}), encoding="utf-8"
        )
        work_dir = root / "work"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", "work_dir=$WORK_DIR\nprivate_key=$PRIVATE_KEY\n" + replacement],
            check=False,
            capture_output=True,
            cwd=root,
            env={
                **os.environ,
                "GITHUB_REPOSITORY": "tektum/verity-images",
                "GITHUB_RUN_ID": "7",
                "GITHUB_SHA": "5" * 40,
                "PACKAGE": package,
                "PATH": f"{binaries}:{os.environ['PATH']}",
                "PRIVATE_KEY": str(root / "private-key"),
                "RELEASE_TAG": "apk-repo-v0003",
                "WORK_DIR": str(work_dir),
            },
        )
        assert result.returncode == 0, result.stderr.decode()
        composition = json.loads((work_dir / "composition.json").read_text(encoding="utf-8"))
        assert composition["replacement"]["name"] == package
        assert {entry["path"] for entry in composition["replacement"]["packages"]} == {
            f"{architecture}/{apk}" for architecture in ARCHITECTURES
        }
        for architecture in ARCHITECTURES:
            assert (work_dir / "signed" / architecture / apk).read_bytes() == source_bytes[architecture]

        # A reservation naming another package must not be signed under this run.
        foreign = json.loads((root / "release" / "reservation.json").read_text(encoding="utf-8"))
        foreign["unsignedPackages"][0]["name"] = "unexpected"
        (root / "release" / "reservation.json").write_text(json.dumps(foreign), encoding="utf-8")
        mismatch = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", "work_dir=$WORK_DIR\nprivate_key=$PRIVATE_KEY\n" + replacement],
            check=False,
            capture_output=True,
            cwd=root,
            env={
                **os.environ,
                "GITHUB_REPOSITORY": "tektum/verity-images",
                "GITHUB_RUN_ID": "7",
                "GITHUB_SHA": "5" * 40,
                "PACKAGE": package,
                "PATH": f"{binaries}:{os.environ['PATH']}",
                "PRIVATE_KEY": str(root / "private-key"),
                "RELEASE_TAG": "apk-repo-v0003",
                "WORK_DIR": str(root / "mismatch"),
            },
        )
        assert mismatch.returncode != 0


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    signing = workflow.split("      - name: Sign APK repositories\n", maxsplit=1)[1]
    shell = signing.split("        run: |\n", maxsplit=1)[1].split("      - name: Attest final repository archive\n", maxsplit=1)[0]
    replacement = shell.split("          else\n", maxsplit=1)[1].split("          fi\n          python3", maxsplit=1)[0]
    for package, version in PACKAGES:
        sign(replacement, package, version)


if __name__ == "__main__":
    main()
