#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - wasmedge=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
label="verity-test=wasmedge-$$"
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned wasmedge version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/wasmedge"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --label "$label" --network none --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work:/work" "$image" "$@"
}

# Fixture: a hand-assembled WASI module. _start writes a line through
# wasi_snapshot_preview1.fd_write; add(i32, i32) is a pure export for reactor mode.
printf '%s' 'AGFzbQEAAAABEgNgBH9/f38Bf2AAAGACf38BfwIjARZ3YXNpX3NuYXBzaG90X3ByZXZpZXcxCGZkX3dyaXRlAAADAwIBAgUDAQABBxkDBm1lbW9yeQIABl9zdGFydAABA2FkZAACCiUCGwBBAEEINgIAQQRBEDYCAEEBQQBBAUEgEAAaCwcAIAAgAWoLCxYBAEEICxBoZWxsbyBmcm9tIHdhc2kK' |
  base64 -d >"$work/hello.wasm"
printf 'not a wasm module\n' >"$work/bad.wasm"
chmod 777 "$work"
chmod 644 "$work/hello.wasm" "$work/bad.wasm"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
run --version >"$work/version.log" || fail 'version failed'
out=$(sed -n 1p "$work/version.log")
test "$out" = "/usr/bin/wasmedge version $version" || fail "version does not report $version: $out"
grep -q 'plugin "wasi_logging"' "$work/version.log" ||
  fail "bundled wasi_logging plugin not loaded: $(cat "$work/version.log")"

# Command mode: WASI stdout reaches the container output.
out=$(run hello.wasm) || fail 'running the WASI module failed'
test "$out" = 'hello from wasi' || fail "unexpected WASI output: $out"

# Reactor mode: call an exported function with arguments.
out=$(run --reactor hello.wasm add 2 40) || fail 'reactor call failed'
test "$out" = 42 || fail "add(2, 40) returned $out"

# AOT: compile with the bundled LLVM backend, then run the native artifact.
run compile hello.wasm hello_aot.wasm >"$work/compile.log" 2>&1 ||
  fail "AOT compile failed: $(cat "$work/compile.log")"
test -s "$work/hello_aot.wasm" || fail 'AOT compile wrote no output'
out=$(run hello_aot.wasm) || fail 'running the AOT module failed'
test "$out" = 'hello from wasi' || fail "unexpected AOT output: $out"

# Negative: an unknown flag and a malformed module both fail.
if run --definitely-not-a-flag >"$work/flag.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
if run bad.wasm >"$work/bad.log" 2>&1; then
  fail 'a malformed module was accepted'
fi
grep -q 'magic header not detected' "$work/bad.log" ||
  fail "unexpected malformed-module error: $(cat "$work/bad.log")"

# Negative: a missing export in reactor mode fails.
if run --reactor hello.wasm missing >"$work/missing.log" 2>&1; then
  fail 'a missing export was accepted'
fi

printf 'SMOKE PASS\n'
