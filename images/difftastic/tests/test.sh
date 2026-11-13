#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
version=$(sed -n 's/^    - difftastic=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
esc=$(printf '\033')

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

difft() {
  docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$here:/fixtures:ro" "$image" "$@"
}

[ -n "$version" ] || fail 'could not read the pinned difftastic version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/difft"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

difft --version >"$work/version" 2>&1 || fail 'version failed'
grep -Fx "Difftastic $version" "$work/version" >/dev/null ||
  fail "version does not report Difftastic $version: $(cat "$work/version")"

rc=0
difft --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
sed "s/${esc}\[[0-9;]*m//g" "$work/invalid" |
  grep -F "unexpected argument '--definitely-invalid'" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

rc=0
difft /fixtures/missing-a.rs /fixtures/missing-b.rs >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing inputs unexpectedly succeeded'
grep -F 'No such file' "$work/missing" >/dev/null || fail 'missing file diagnostic is missing'

# A real change: the Rust parser is selected and only the changed literal is
# reported, with --exit-code returning 1 for a difference.
rc=0
difft --color=never --display=inline --exit-code \
  /fixtures/old.rs /fixtures/new.rs >"$work/changed" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "changed files exit code $rc, want 1: $(cat "$work/changed")"
grep -F -- '--- Rust' "$work/changed" >/dev/null || fail 'Rust language was not detected'
grep -E '^ *2 +let total = add\(1, 2\);$' "$work/changed" >/dev/null ||
  fail 'removed line is missing'
grep -E '^ +2 +let total = add\(1, 3\);$' "$work/changed" >/dev/null ||
  fail 'added line is missing'
grep -F 'a + b' "$work/changed" >/dev/null && fail 'unchanged function body was reported'

# Structural diff: a layout-only rewrite has the same syntax tree, so there are
# no syntactic changes and --exit-code returns 0.
difft --color=never --exit-code /fixtures/old.rs /fixtures/reformatted.rs \
  >"$work/layout" 2>&1 || fail "layout-only change reported a difference: $(cat "$work/layout")"
grep -F 'No syntactic changes' "$work/layout" >/dev/null ||
  fail "layout-only change was not recognized: $(cat "$work/layout")"

# A line-oriented tool would flag every line of the rewrite; check-only mode
# agrees with the full diff.
difft --check-only --exit-code /fixtures/old.rs /fixtures/reformatted.rs >/dev/null 2>&1 ||
  fail 'check-only reported a difference for a layout-only change'
rc=0
difft --check-only --exit-code /fixtures/old.rs /fixtures/new.rs >/dev/null 2>&1 || rc=$?
test "$rc" -eq 1 || fail "check-only exit code $rc for a real change, want 1"

printf 'SMOKE PASS image=%s\n' "$image"
