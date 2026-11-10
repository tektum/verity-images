#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/actionlint"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work "$image" "$@"
}

run -version >"$work/version" 2>&1 || fail 'version failed'
test "$(sed -n 1p "$work/version")" = "$version" || fail 'version is not embedded'
grep -F 'built from pinned upstream source' "$work/version" >/dev/null ||
  fail 'install source is not reported'

run -h >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage: actionlint' "$work/help" >/dev/null || fail 'help is missing usage text'

rc=0
run -definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" = 2 || fail "invalid flag exit code $rc, expected 2"
grep -F 'definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

mkdir -p "$work/.github/workflows"

# Valid workflow: exit 0 and no output.
cat >"$work/.github/workflows/good.yaml" <<'YAML'
name: good
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "${{ github.sha }}"
YAML
run -no-color .github/workflows/good.yaml >"$work/good.out" 2>&1 ||
  fail 'valid workflow was rejected'
test ! -s "$work/good.out" || fail 'valid workflow produced output'

# Seeded expression error: undefined context property, exit 1 with file:line.
cat >"$work/.github/workflows/bad.yaml" <<'YAML'
name: bad
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ github.nosuchproperty }}"
YAML
rc=0
run -no-color .github/workflows/bad.yaml >"$work/bad.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "bad workflow exit code $rc, expected 1"
grep -F '.github/workflows/bad.yaml:7:' "$work/bad.out" >/dev/null ||
  fail 'finding does not name the file and line'
grep -F 'nosuchproperty' "$work/bad.out" >/dev/null ||
  fail 'finding does not name the property'
grep -F '[expression]' "$work/bad.out" >/dev/null ||
  fail 'finding is not an expression-rule error'

# Default discovery needs a project root: without .git it fails with exit 3.
rc=0
run -no-color >"$work/noproject.out" 2>&1 || rc=$?
test "$rc" = 3 || fail "discovery without a project exit code $rc, expected 3"
grep -F 'no project was found' "$work/noproject.out" >/dev/null ||
  fail 'missing-project diagnostic is missing'

# With a project root, discovery finds the workflow directory and reports the error.
mkdir "$work/.git"
rc=0
run -no-color >"$work/discover.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "discovery exit code $rc, expected 1"
grep -F 'bad.yaml' "$work/discover.out" >/dev/null ||
  fail 'discovery did not find the bad workflow'

# JSON output via -format carries the rule kind.
rc=0
run -no-color -format '{{json .}}' .github/workflows/bad.yaml >"$work/bad.json" 2>&1 || rc=$?
test "$rc" = 1 || fail "format exit code $rc, expected 1"
grep -F '"kind":"expression"' "$work/bad.json" >/dev/null ||
  fail 'json finding is missing the expression kind'

printf 'SMOKE PASS image=%s\n' "$image"
