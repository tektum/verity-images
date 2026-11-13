#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - act=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned act version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/act"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# No Docker socket and no network: act must still parse and plan workflows.
run() {
  dir=$1
  shift
  docker run --rm --network none --read-only --tmpfs /tmp:rw,mode=1777 -e HOME=/tmp \
    -v "$dir:/work:ro" "$image" "$@"
}

mkdir -p "$work/good/.github/workflows" "$work/bad/.github/workflows" "$work/empty"
chmod -R a+rX "$work"

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Ex "act version $version(\+dirty)?" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

cat >"$work/good/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo test
YAML
cat >"$work/good/.github/workflows/release.yaml" <<'YAML'
name: release
on:
  workflow_dispatch:
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: echo publish
YAML
cat >"$work/bad/.github/workflows/bad.yaml" <<'YAML'
name: bad
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    stepz:
      - run: echo build
YAML
chmod -R a+rX "$work"

# --list prints every job with its stage, workflow and events.
run "$work/good" --list >"$work/list" 2>&1 || fail "list failed: $(cat "$work/list")"
grep -E '^0[[:space:]]+build[[:space:]]+build[[:space:]]+ci[[:space:]]+ci\.yaml[[:space:]]+push,pull_request' \
  "$work/list" >/dev/null || fail "build job is not listed at stage 0: $(cat "$work/list")"
grep -E '^1[[:space:]]+test[[:space:]]+test[[:space:]]+ci[[:space:]]+ci\.yaml' "$work/list" >/dev/null ||
  fail 'dependent test job is not listed at stage 1'
grep -E '^0[[:space:]]+publish[[:space:]]+publish[[:space:]]+release[[:space:]]+release\.yaml[[:space:]]+workflow_dispatch' \
  "$work/list" >/dev/null || fail 'workflow_dispatch job is not listed'

# Event filtering: only the push workflow is planned for push.
run "$work/good" push --list >"$work/push" 2>&1 || fail 'push list failed'
grep -F 'publish' "$work/push" >/dev/null && fail 'push list includes the workflow_dispatch job'
grep -F 'build' "$work/push" >/dev/null || fail 'push list is missing the build job'

# Dependency graph.
run "$work/good" --graph >"$work/graph" 2>&1 || fail 'graph failed'
grep -F 'build' "$work/graph" >/dev/null || fail 'graph is missing the build job'
grep -F 'test' "$work/graph" >/dev/null || fail 'graph is missing the test job'

# Strict schema validation accepts the good workflow and rejects the bad one.
run "$work/good" --validate --strict >"$work/valid" 2>&1 ||
  fail "valid workflows were rejected: $(cat "$work/valid")"
rc=0
run "$work/bad" --validate --strict >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid workflow passed validation'
grep -F 'Unknown Property stepz' "$work/invalid" >/dev/null ||
  fail "invalid workflow diagnostic does not name the property: $(cat "$work/invalid")"

# Without workflows act reports the missing directory and fails.
rc=0
run "$work/empty" --list >"$work/none" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'listing without workflows unexpectedly succeeded'

printf 'SMOKE PASS image=%s\n' "$image"
