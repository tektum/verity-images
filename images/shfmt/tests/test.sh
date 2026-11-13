#!/bin/sh
# shellcheck disable=SC2016 # Shell fixtures are written literally, not expanded.
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - shfmt=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned shfmt version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/shfmt"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm -i --network none --read-only -v "$work/src:/work:ro" "$image" "$@"
}

mkdir -p "$work/src"
printf 'if [ -n "$x" ];then\necho   yes\nfi\n' >"$work/src/messy.sh"
printf 'if [ -n "$x" ]; then\n\techo yes\nfi\n' >"$work/src/clean.sh"
printf 'if true; then\necho missing fi\n' >"$work/src/broken.sh"
chmod -R a+rX "$work"

out=$(run --version) || fail 'version failed'
test "$out" = "v$version" || fail "version does not report v$version: $out"

# Formatting from stdin, with default tabs and with -i 2 indentation.
out=$(run <"$work/src/messy.sh") || fail 'stdin formatting failed'
test "$out" = "$(cat "$work/src/clean.sh")" || fail "unexpected formatting: $out"

out=$(run -i 2 messy.sh) || fail 'file formatting failed'
test "$out" = "$(printf 'if [ -n "$x" ]; then\n  echo yes\nfi')" ||
  fail "unexpected two-space formatting: $out"

# -l lists only the unformatted files and exits 1 when it lists any.
rc=0
out=$(run -l messy.sh clean.sh) || rc=$?
test "$rc" -eq 1 || fail "-l exited $rc, expected 1"
test "$out" = 'messy.sh' || fail "unexpected -l listing: $out"
run -l clean.sh >/dev/null || fail '-l on a clean file failed'

# -d prints a diff and exits non-zero for unformatted input, zero when clean.
rc=0
run -d messy.sh >"$work/diff" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "diff on unformatted file exited $rc, expected 1"
grep -F '+	echo yes' "$work/diff" >/dev/null || fail "diff is missing the fix: $(cat "$work/diff")"
run -d clean.sh >/dev/null || fail 'diff on a clean file failed'

# Negative: a syntax error exits non-zero with a positioned diagnostic.
rc=0
run broken.sh >"$work/err" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'syntax error unexpectedly succeeded'
grep -E 'broken\.sh:1:1: .*must end with .fi.' "$work/err" >/dev/null ||
  fail "syntax diagnostic is missing: $(cat "$work/err")"

rc=0
run --no-such-flag >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -no-such-flag' "$work/flag" >/dev/null ||
  fail "unknown flag diagnostic is missing: $(cat "$work/flag")"

printf 'SMOKE PASS\n'
