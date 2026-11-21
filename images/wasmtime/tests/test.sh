#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=wasmtime-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/wasmtime"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Modules run from a read-only fixture mount with no network, no capabilities
# and a read-only root filesystem. The compilation cache lives under $HOME, so
# the home directory is a tmpfs; /out is the only other writable path.
mkdir -p "$work/fixtures" "$work/out"
chmod 0777 "$work/out"

# WASI preview1 module: fd_write a fixed string to stdout and exit 0.
cat >"$work/fixtures/hello.wat" <<'WAT'
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "verity wasmtime smoke\n")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 16))
    (i32.store (i32.const 4) (i32.const 22))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
WAT
cat >"$work/fixtures/add.wat" <<'WAT'
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1))))
WAT
# Executes an unreachable instruction.
cat >"$work/fixtures/trap.wat" <<'WAT'
(module (func (export "_start") unreachable))
WAT
# A file with the Wasm magic number but a corrupt body.
printf '\000asm\001\000\000\000\377\377\377' >"$work/fixtures/invalid.wasm"
printf 'not a module\n' >"$work/fixtures/garbage.wasm"
chmod -R a+rX "$work/fixtures"

hardened() {
  docker run --rm --label "$label" --network none --read-only \
    --tmpfs /home/nonroot:uid=65532,gid=65532,mode=0755 --cap-drop ALL \
    --security-opt no-new-privileges "$@"
}

run() {
  hardened -v "$work/fixtures:/work:ro" -v "$work/out:/out" "$image" "$@"
}

# stdout only: docker may print a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run --version) || fail 'version failed'
reported=$(printf '%s\n' "$out" | awk 'NR == 1 && $1 == "wasmtime" {print $2}')
test "$reported" = "$version" || fail "version does not report $version: $out"

out=$(run run hello.wat) || fail 'WASI module failed'
test "$out" = 'verity wasmtime smoke' || fail "unexpected WASI module output: $out"

out=$(run run --invoke add add.wat 40 2) || fail 'exported function invocation failed'
test "$out" = 42 || fail "unexpected add result: $out"

# Ahead-of-time Cranelift compile, then run the precompiled artifact.
run compile hello.wat -o /out/hello.cwasm >"$work/compile.log" 2>&1 ||
  fail "compile failed: $(cat "$work/compile.log")"
[ -s "$work/out/hello.cwasm" ] || fail 'compile produced no artifact'
out=$(hardened -v "$work/out:/work:ro" "$image" run --allow-precompiled hello.cwasm) ||
  fail 'precompiled module failed'
test "$out" = 'verity wasmtime smoke' || fail "unexpected precompiled output: $out"

# Negative: an unknown flag is rejected.
if run --definitely-not-a-flag >"$work/flag.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q "unexpected argument '--definitely-not-a-flag'" "$work/flag.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/flag.log")"

# Negative: invalid modules fail to load.
for module in invalid.wasm garbage.wasm; do
  if run run "$module" >"$work/invalid.log" 2>&1; then
    fail "invalid module $module was accepted"
  fi
  grep -qi 'error' "$work/invalid.log" ||
    fail "unexpected invalid-module error for $module: $(cat "$work/invalid.log")"
done

# Negative: a trap exits non-zero and is reported.
if run run trap.wat >"$work/trap.log" 2>&1; then
  fail 'trapping module exited zero'
fi
grep -q 'unreachable' "$work/trap.log" ||
  fail "unexpected trap report: $(cat "$work/trap.log")"

# Negative: the WASI sandbox grants no filesystem access without --dir.
cat >"$work/out/read.wat" <<'WAT'
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 64) "hello.wat")
  (func (export "_start")
    (call $proc_exit
      (call $path_open (i32.const 3) (i32.const 0) (i32.const 64) (i32.const 9)
        (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 0)))))
WAT
chmod a+r "$work/out/read.wat"
# The module exits with the path_open errno; 8 is WASI EBADF (no preopen).
status=0
hardened -v "$work/out:/work:ro" "$image" run read.wat >/dev/null 2>&1 || status=$?
test "$status" -eq 8 || fail "path_open without a preopened directory exited $status, want 8"
hardened -v "$work/out:/work:ro" -v "$work/fixtures:/data:ro" "$image" \
  run --dir /data::. read.wat >"$work/read.log" 2>&1 ||
  fail "path_open failed with a preopened directory: $(cat "$work/read.log")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$version"
