#!/usr/bin/env python3
"""Prove the real omnibump Rust CLI contract that pipelines/cargo/remediate.yaml relies on.

The shared pipeline treats omnibump as the only dependency graph mutation engine,
so its flags and failure semantics are load-bearing. This runs the real binary
from the same Wolfi package the pipeline depends on, inside an ephemeral
container, and never installs anything globally.

The container registry and crates.io are external, so the fixture reports
SKIPPED and exits 0 when either is unavailable locally. Under CI it must prove
the contract: every skip becomes a failure.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPELINE = ROOT / "pipelines/cargo/remediate.yaml"
# Ephemeral test fixture, not a published artifact: wolfi-base only supplies
# `apk`, and the contract subject (omnibump) is resolved from the same Wolfi
# package repository a melange build environment uses. The runtime is pinned by
# digest so the contract cannot silently change underneath a green test.
IMAGE = (
    "cgr.dev/chainguard/wolfi-base@sha256:"
    "7e62cecd3c5712dba6e52c5260afb8f9d7a23b9bbcdd26ad7508a811e74b766d"
)
PACKAGES = ("omnibump", "rust-1.94")
# Zero-dependency crates with stable published versions.
OLD_ITOA = "1.0.9"
NEW_ITOA = "1.0.18"
# Two versions on the crate's older 0.4 compatibility line.
OLD_LINE_ITOA = "0.4.8"
OLDER_LINE_ITOA = "0.4.6"
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

run() {
  name=$1
  directory=$2
  pins=$3
  shift 3
  set +e
  omnibump --language rust --dir "$directory" --packages "$pins" \
    --fail-on-unapplied-pins "$@" >"/work/$name.log" 2>&1
  status=$?
  set -e
  emit "$name.status" "$status"
}

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
run a /work/a "itoa@%(old_line)s=%(new)s" --features default
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
run b /work/b "itoa@%(old)s=%(new)s"
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
run c /work/c "itoa@%(old)s=%(new)s"
emit c.after "$(locked c itoa)"

# Scenario D: two unsatisfied compatibility lines updated in one invocation,
# exactly matching the production handoff for duplicate vulnerable crates.
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
(cd d && cargo generate-lockfile -q && cargo update -p itoa@%(old_line)s --precise %(older_line)s -q)
new_current=$(locked d itoa | awk '$1 !~ /^0\.4\./ { print; exit }')
(cd d && cargo update -p "itoa@$new_current" --precise %(old)s -q)
emit d.before "$(locked d itoa | tr '\n' ',')"
run d /work/d "itoa@%(older_line)s=%(old_line)s itoa@%(old)s=%(new)s"
emit d.after "$(locked d itoa | tr '\n' ',')"

# Scenario E: Cargo itself resolves feature, dependency-kind, and target scope.
make_lib() {
  directory=$1
  name=$2
  version=${3:-0.1.0}
  mkdir -p "$directory/src"
  cat >"$directory/Cargo.toml" <<EOF
[package]
name = "$name"
version = "$version"
edition = "2021"
EOF
  printf 'pub fn value() {}\n' >"$directory/src/lib.rs"
}

rm -rf e && mkdir -p e/src
for spec in 'always always-dep' 'optional optional-dep' 'build build-dep' 'dev dev-dep' \
  'unix unix-dep' 'windows windows-dep'; do
  set -- $spec
  make_lib "e/$1" "$2"
done
cat >e/Cargo.toml <<'EOF'
[package]
name = "fixture-e"
version = "0.1.0"
edition = "2021"

[features]
default = ["dep:optional"]
selected = ["dep:optional"]

[dependencies]
always = { package = "always-dep", path = "always" }
optional = { package = "optional-dep", path = "optional", optional = true }

[build-dependencies]
build = { package = "build-dep", path = "build" }

[dev-dependencies]
dev = { package = "dev-dep", path = "dev" }

[target.'cfg(unix)'.dependencies]
unix = { package = "unix-dep", path = "unix" }

[target.'cfg(windows)'.dependencies]
windows = { package = "windows-dep", path = "windows" }
EOF
printf 'fn main() {}\n' >e/src/main.rs
(cd e && cargo generate-lockfile -q)
(cd e && cargo metadata --format-version 1 --locked --filter-platform host-tuple >default.json)
printf 'fn main() {}\n' >e/build.rs
(cd e && cargo metadata --format-version 1 --locked --filter-platform host-tuple \
  --no-default-features >none.json)
(cd e && cargo metadata --format-version 1 --locked --filter-platform host-tuple \
  --no-default-features --features selected >selected.json)
(cd e && cargo metadata --format-version 1 --locked --filter-platform x86_64-pc-windows-msvc \
  --no-default-features >windows.json)

# Scenario F: a virtual workspace builds only its configured default member.
rm -rf f f-deps
make_lib f-deps/dep-a dep-a
make_lib f-deps/dep-b dep-b
make_lib f/a member-a
make_lib f/b member-b
cat >>f/a/Cargo.toml <<'EOF'

[dependencies]
dep-a = { path = "../../f-deps/dep-a" }
EOF
cat >>f/b/Cargo.toml <<'EOF'

[dependencies]
dep-b = { path = "../../f-deps/dep-b" }
EOF
cat >f/Cargo.toml <<'EOF'
[workspace]
members = ["a", "b"]
default-members = ["a"]
resolver = "2"
EOF
(cd f && cargo generate-lockfile -q)
(cd f && cargo metadata --format-version 1 --locked --filter-platform host-tuple >default.json)

# Scenario V: Vector's build flags exclude the default-only hyper-proxy/h2 0.3 line.
rm -rf v v-deps && mkdir -p v/src
make_lib v-deps/h2-old h2 0.3.26
make_lib v-deps/h2-new h2 0.4.15
make_lib v-deps/eligible eligible 1.0.0
make_lib v-deps/hyper-proxy hyper-proxy 0.9.1
cat >>v-deps/hyper-proxy/Cargo.toml <<'EOF'

[dependencies]
h2-old = { package = "h2", path = "../h2-old" }
EOF
make_lib v-deps/console-core console-core 0.1.0
cat >>v-deps/console-core/Cargo.toml <<'EOF'

[dependencies]
h2-new = { package = "h2", path = "../h2-new" }
eligible = { path = "../eligible" }
EOF
cat >v/Cargo.toml <<'EOF'
[package]
name = "vector"
version = "0.57.0"
edition = "2021"

[features]
default = ["http"]
http = ["dep:hyper-proxy"]
sources-stdin = []
sinks-console = ["dep:console-core"]

[dependencies]
hyper-proxy = { path = "../v-deps/hyper-proxy", optional = true }
console-core = { path = "../v-deps/console-core", optional = true }
EOF
printf 'fn main() {}\n' >v/src/main.rs
(cd v && cargo generate-lockfile -q)
(cd v && cargo metadata --format-version 1 --locked --filter-platform host-tuple \
  --no-default-features --features sources-stdin,sinks-console >vector.json)
"""


def skip(reason: str) -> None:
    """Local runs may lack docker or a registry; CI must prove the contract."""
    message = f"scripts/test_cargo_omnibump_contract.py: {reason}"
    if os.environ.get("CI"):
        raise SystemExit(f"error: {message}")
    print(f"SKIPPED {message}")
    raise SystemExit(0)


def image(work: Path, run_process=subprocess.run) -> str:
    if run_process(
        ["docker", "image", "inspect", IMAGE], capture_output=True, cwd=work, timeout=TIMEOUT
    ).returncode == 0:
        return IMAGE
    if run_process(
        ["docker", "pull", "-q", IMAGE], capture_output=True, text=True, cwd=work, timeout=TIMEOUT
    ).returncode == 0:
        return IMAGE
    skip(f"cannot pull pinned image {IMAGE}")
    raise AssertionError("unreachable")


def test_image_timeouts(work: Path) -> None:
    calls = []

    def run_process(arguments, **options):
        calls.append((arguments, options))
        return subprocess.CompletedProcess(arguments, 1 if arguments[2] == "inspect" else 0)

    assert image(work, run_process) == IMAGE
    assert [arguments[1:3] for arguments, _ in calls] == [["image", "inspect"], ["pull", "-q"]]
    assert [options["timeout"] for _, options in calls] == [TIMEOUT, TIMEOUT]


def load_resolver(work: Path):
    pipeline = PIPELINE.read_text(encoding="utf-8")
    script = pipeline.split("      cat >\"$tool_dir/remediate.py\" <<'PYTHON'\n", 1)[1].split(
        "      PYTHON\n", 1
    )[0]
    path = work / "remediate.py"
    path.write_text(
        "\n".join(line.removeprefix("      ") for line in script.splitlines()) + "\n",
        encoding="utf-8",
    )
    spec = importlib.util.spec_from_file_location("cargo_remediate_contract", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_metadata_graph_contract(work: Path) -> None:
    module = load_resolver(work)

    def shipped(project: str, report: str) -> set[tuple[str, str, str]]:
        root = work / project
        locked = module.locked_instances(root / "Cargo.lock")
        raw = root.joinpath(report).read_text(encoding="utf-8")
        return module.parse_shipped_graph(raw, locked)

    default = shipped("e", "default.json")
    no_defaults = shipped("e", "none.json")
    selected = shipped("e", "selected.json")
    windows = shipped("e", "windows.json")
    assert ("optional-dep", "0.1.0", "") in default
    assert ("optional-dep", "0.1.0", "") not in no_defaults
    assert ("optional-dep", "0.1.0", "") in selected
    for identity in (
        ("always-dep", "0.1.0", ""),
        ("build-dep", "0.1.0", ""),
        ("unix-dep", "0.1.0", ""),
    ):
        assert identity in no_defaults
    assert ("dev-dep", "0.1.0", "") not in no_defaults
    assert ("windows-dep", "0.1.0", "") not in no_defaults
    assert ("windows-dep", "0.1.0", "") in windows
    assert ("unix-dep", "0.1.0", "") not in windows

    workspace = shipped("f", "default.json")
    workspace_metadata = json.loads(work.joinpath("f/default.json").read_text(encoding="utf-8"))
    assert workspace_metadata["resolve"]["root"] is None
    assert ("member-a", "0.1.0", "") in workspace
    assert ("dep-a", "0.1.0", "") in workspace
    assert ("member-b", "0.1.0", "") not in workspace
    assert ("dep-b", "0.1.0", "") not in workspace

    vector = shipped("v", "vector.json")
    vector_metadata = json.loads(work.joinpath("v/vector.json").read_text(encoding="utf-8"))
    assert vector_metadata["resolve"]["root"] is not None
    assert ("h2", "0.3.26", "") not in vector
    assert ("h2", "0.4.15", "") in vector
    assert ("eligible", "1.0.0", "") in vector


def run(work: Path) -> dict[str, str]:
    script = work / "contract.sh"
    script.write_text(
        SCRIPT % {
            "packages": " ".join(PACKAGES),
            "old": OLD_ITOA,
            "new": NEW_ITOA,
            "old_line": OLD_LINE_ITOA,
            "older_line": OLDER_LINE_ITOA,
        },
        encoding="utf-8",
    )
    completed = subprocess.run(
        [
            "docker", "run", "--rm",
            "-e", f"HOST_UID={os.getuid()}", "-e", f"HOST_GID={os.getgid()}",
            "-v", f"{work}:/work", image(work), "sh", "/work/contract.sh",
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
    test_image_timeouts(ROOT)
    assert "@sha256:" in IMAGE and ":latest" not in IMAGE
    if not shutil.which("docker"):
        skip("docker is unavailable")
    if os.environ.get("CARGO_OMNIBUMP_CONTRACT") == "0":
        skip("disabled by CARGO_OMNIBUMP_CONTRACT=0")
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        work.chmod(0o755)
        results = run(work)
        assert_metadata_graph_contract(work)
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

        # D: production sends both unsatisfied lines in one --packages value;
        # the real CLI must keep the repeated crate names distinct and land both.
        assert results["d.status"] == "0", work.joinpath("d.log").read_text(encoding="utf-8")
        assert sorted(version for version in results["d.before"].split(",") if version) == sorted(
            {OLDER_LINE_ITOA, OLD_ITOA}
        ), results
        assert sorted(version for version in results["d.after"].split(",") if version) == sorted(
            {OLD_LINE_ITOA, NEW_ITOA}
        ), results
        assert 'f"{crate}@{current}={fixed}"' in pipeline

    print("passed scripts/test_cargo_omnibump_contract.py")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit(f"error: contract fixture exceeded {TIMEOUT}s") from None
