#!/usr/bin/env python3
"""Prove the real omnibump Rust CLI contract that pipelines/cargo/remediate.yaml relies on.

The shared pipeline treats omnibump as the only dependency graph mutation engine,
so its flags and failure semantics are load-bearing. This runs the real binary
from the same Wolfi package the pipeline depends on, inside an ephemeral
container, and never installs anything globally.

The container and crates.io are external, so the fixture reports SKIPPED and
exits 0 when either is unavailable; CI has both and therefore always proves the
contract.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "pipelines/cargo/remediate.yaml"
# Ephemeral test fixture, not a published artifact: wolfi-base only supplies
# `apk`, and the contract subject (omnibump) is resolved from the same Wolfi
# package repository a melange build environment uses.
IMAGE = "cgr.dev/chainguard/wolfi-base:latest"
PACKAGES = ("omnibump", "rust-1.94")
# Zero-dependency crates with stable published versions.
OLD_ITOA = "1.0.9"
NEW_ITOA = "1.0.18"
TIMEOUT = 1800

SCRIPT = r"""#!/bin/sh
set -eu
# The container runs as root; hand /work back so the host can clean it up.
trap 'chown -R "$HOST_UID:$HOST_GID" /work 2>/dev/null || true' EXIT INT TERM
apk add -q %(packages)s
export CARGO_HOME=/work/cargo-home
cd /work

locked() {
  awk -v crate="$2" '
    $0 == "name = \"" crate "\"" { found = 1; next }
    found && /^version/ { gsub(/[",]/, "", $3); print $3; found = 0 }
  ' "$1/Cargo.lock"
}

emit() { printf '%%s %%s\n' "$1" "$2" >>/work/result; }

: >/work/result
omnibump --help >/work/help.txt 2>&1
omnibump supported >/work/supported.txt 2>&1

# Scenario A: a direct dependency crossing a SemVer boundary.
rm -rf a && mkdir -p a/src
cat >a/Cargo.toml <<'EOF'
[package]
name = "fixture-a"
version = "0.1.0"
edition = "2021"

[dependencies]
itoa = "0.4"
EOF
printf 'fn main() { println!("{}", itoa::Buffer::new().format(42u32)); }\n' >a/src/main.rs
(cd a && cargo generate-lockfile -q)
emit a.before "$(locked a itoa)"
emit a.manifest_before "$(grep '^itoa' a/Cargo.toml | tr -d ' ')"
omnibump --language rust --dir /work/a --packages "itoa@%(new)s" \
  --fail-on-unapplied-pins --features default >/work/a.log 2>&1
emit a.status "$?"
emit a.after "$(locked a itoa)"
emit a.manifest_after "$(grep '^itoa' a/Cargo.toml | tr -d ' ')"

# Scenario B: a transitive dependency updated in the lock only.
rm -rf b && mkdir -p b/src
cat >b/Cargo.toml <<'EOF'
[package]
name = "fixture-b"
version = "0.1.0"
edition = "2021"

[dependencies]
serde_json = "1.0.100"
EOF
printf 'fn main() { println!("{}", serde_json::json!({"a": 1})); }\n' >b/src/main.rs
(cd b && cargo generate-lockfile -q && cargo update -p itoa --precise %(old)s -q)
emit b.before "$(locked b itoa)"
omnibump --language rust --dir /work/b --packages "itoa@%(new)s" \
  --fail-on-unapplied-pins >/work/b.log 2>&1
emit b.status "$?"
emit b.after "$(locked b itoa)"
emit b.manifest_mentions "$(grep -c itoa b/Cargo.toml || true)"

# Scenario C: a pin the graph cannot land must fail loudly.
rm -rf c && mkdir -p c/src c/blocker/src
cat >c/Cargo.toml <<'EOF'
[package]
name = "fixture-c"
version = "0.1.0"
edition = "2021"

[dependencies]
blocker = { path = "blocker" }
EOF
cat >c/blocker/Cargo.toml <<EOF
[package]
name = "blocker"
version = "0.1.0"
edition = "2021"

[dependencies]
itoa = "=%(old)s"
EOF
printf 'fn main() { println!("{}", blocker::value()); }\n' >c/src/main.rs
printf 'pub fn value() -> String { itoa::Buffer::new().format(7u32).to_string() }\n' >c/blocker/src/lib.rs
(cd c && cargo generate-lockfile -q)
emit c.before "$(locked c itoa)"
set +e
omnibump --language rust --dir /work/c --packages "itoa@%(new)s" \
  --fail-on-unapplied-pins >/work/c.log 2>&1
emit c.status "$?"
set -e
emit c.after "$(locked c itoa)"

# Scenario D: omnibump treats a pin as landed once any instance satisfies it, so
# a stranded lower duplicate stays behind. The pipeline rescan must catch that.
rm -rf d && mkdir -p d/src
cat >d/Cargo.toml <<'EOF'
[package]
name = "fixture-d"
version = "0.1.0"
edition = "2021"

[dependencies]
itoa = "0.4"
serde_json = "1.0.100"
EOF
printf 'fn main() { println!("{} {}", itoa::Buffer::new().format(1u32), serde_json::json!(1)); }\n' >d/src/main.rs
(cd d && cargo generate-lockfile -q)
emit d.before "$(locked d itoa | tr '\n' ',')"
set +e
omnibump --language rust --dir /work/d --packages "itoa@%(new)s" \
  --fail-on-unapplied-pins >/work/d.log 2>&1
emit d.status "$?"
set -e
emit d.after "$(locked d itoa | tr '\n' ',')"
"""


def skip(reason: str) -> None:
    print(f"SKIPPED scripts/test_cargo_omnibump_contract.py: {reason}")
    raise SystemExit(0)


def pull(work: Path) -> None:
    if subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True, cwd=work).returncode == 0:
        return
    completed = subprocess.run(["docker", "pull", "-q", IMAGE], capture_output=True, text=True, cwd=work)
    if completed.returncode != 0:
        skip(f"cannot pull {IMAGE}: {completed.stderr.strip() or 'no stderr'}")


def run(work: Path) -> dict[str, str]:
    script = work / "contract.sh"
    script.write_text(
        SCRIPT % {"packages": " ".join(PACKAGES), "old": OLD_ITOA, "new": NEW_ITOA},
        encoding="utf-8",
    )
    pull(work)
    completed = subprocess.run(
        [
            "docker", "run", "--rm", "--network", "host",
            "-e", f"HOST_UID={os.getuid()}", "-e", f"HOST_GID={os.getgid()}",
            "-v", f"{work}:/work", IMAGE, "sh", "/work/contract.sh",
        ],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
        cwd=work,
    )
    results = work / "result"
    if completed.returncode != 0 or not results.is_file():
        detail = (completed.stderr or completed.stdout).strip()
        if "network" in detail.lower() or "resolve" in detail.lower():
            skip(f"container has no network access: {detail[-200:]}")
        raise AssertionError(f"contract fixture failed ({completed.returncode}): {detail[-2000:]}")
    return dict(
        line.split(" ", 1) if " " in line else (line, "")
        for line in results.read_text(encoding="utf-8").splitlines()
        if line
    )


def main() -> None:
    if not shutil.which("docker"):
        skip("docker is unavailable")
    if os.environ.get("CARGO_OMNIBUMP_CONTRACT") == "0":
        skip("disabled by CARGO_OMNIBUMP_CONTRACT=0")
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        work.chmod(0o755)
        results = run(work)
        help_text = work.joinpath("help.txt").read_text(encoding="utf-8")
        supported = work.joinpath("supported.txt").read_text(encoding="utf-8")
        pipeline = PIPELINE.read_text(encoding="utf-8")

        # Every flag the shared pipeline passes must exist in the real CLI.
        for flag in ("--language", "--dir", "--packages", "--fail-on-unapplied-pins", "--features"):
            assert flag in help_text, flag
            assert flag in pipeline, flag
        assert "Language: rust" in supported, supported

        # A: direct SemVer-boundary update rewrites the manifest and the lock.
        assert results["a.status"] == "0", results
        assert results["a.before"].startswith("0.4."), results
        assert results["a.after"] == NEW_ITOA, results
        assert results["a.manifest_before"] == 'itoa="0.4"', results
        assert results["a.manifest_after"] != results["a.manifest_before"], results
        assert results["a.manifest_after"].startswith('itoa="1'), results

        # B: transitive update touches the lock only.
        assert results["b.status"] == "0", results
        assert results["b.before"] == OLD_ITOA and results["b.after"] == NEW_ITOA, results
        assert results["b.manifest_mentions"] == "0", results

        # C: a pin the graph refuses fails loudly and changes nothing.
        assert results["c.status"] != "0", results
        assert results["c.before"] == OLD_ITOA and results["c.after"] == OLD_ITOA, results
        failure = work.joinpath("c.log").read_text(encoding="utf-8")
        assert "itoa" in failure and "cannot satisfy" in failure, failure

        # D: a satisfied duplicate lets omnibump skip, stranding the lower
        # instance with exit 0. The pipeline rescan and persistence check own
        # this case; see the duplicate-stranded test in test_cargo_remediation.py.
        assert results["d.status"] == "0", results
        stranded = [version for version in results["d.after"].split(",") if version]
        assert any(version.startswith("0.4.") for version in stranded), results
        assert "already satisfies" in work.joinpath("d.log").read_text(encoding="utf-8")
        assert "vulnerable crate versions remain after remediation" in pipeline

    print("passed scripts/test_cargo_omnibump_contract.py")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        print("SKIPPED scripts/test_cargo_omnibump_contract.py: contract fixture timed out", file=sys.stderr)
        raise SystemExit(1) from None
    except json.JSONDecodeError as error:
        raise SystemExit(f"error: {error}") from error
