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
PACKAGE: Final = "openssl-fips-provider"
APK: Final = "openssl-fips-provider-3.1.2-r3.apk"
ARCHITECTURES: Final = ("aarch64", "x86_64")


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    signing = workflow.split("      - name: Sign APK repositories\n", maxsplit=1)[1]
    shell = signing.split("        run: |\n", maxsplit=1)[1].split("      - name: Attest final repository archive\n", maxsplit=1)[0]
    replacement = shell.split("          else\n", maxsplit=1)[1].split("          fi\n          python3", maxsplit=1)[0]

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
            content = f"{PACKAGE}-{architecture}".encode()
            source = root / "input" / f"apk-build-{PACKAGE}-{architecture}" / APK
            source.parent.mkdir(parents=True)
            source.write_bytes(content)
            source_bytes[architecture] = content
            packages.append(
                {
                    "architecture": architecture,
                    "name": PACKAGE,
                    "path": f"{architecture}/{APK}",
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
                "PATH": f"{binaries}:{os.environ['PATH']}",
                "PRIVATE_KEY": str(root / "private-key"),
                "RELEASE_TAG": "apk-repo-v0003",
                "WORK_DIR": str(work_dir),
            },
        )
        assert result.returncode == 0, result.stderr.decode()
        assert {(package["name"], package["architecture"]) for package in packages} == {
            (PACKAGE, architecture) for architecture in ARCHITECTURES
        }
        for architecture in ARCHITECTURES:
            assert (work_dir / "signed" / architecture / APK).read_bytes() == source_bytes[architecture]


if __name__ == "__main__":
    main()
