#!/bin/sh
set -eu

# Every container in this test runs with --network none and without a GitHub
# token: the smoke test never reaches the GitHub API or any other service.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$recipe")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  # docker run does not inherit the caller's environment, so no token is set.
  docker run --rm --network none --read-only "$@"
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/scorecard"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run "$image" version >"$work/version" 2>&1 || fail 'version failed'
grep -Ex "GitVersion: +v$version(\+dirty)?" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
run "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# A remote repository needs a GitHub token. Without one and without a
# network, scorecard reports the documented credential error and produces no
# results.
run "$image" --repo=github.com/ossf/scorecard --format json \
  >"$work/remote.out" 2>"$work/remote.err" || true
grep -F 'GitHub token env var is not set' "$work/remote.err" >/dev/null ||
  fail "missing token diagnostic: $(cat "$work/remote.err")"
grep -F 'repo unreachable' "$work/remote.err" >/dev/null ||
  fail "offline remote run did not report the repository as unreachable: $(cat "$work/remote.err")"
! grep -F '"checks"' "$work/remote.out" >/dev/null ||
  fail "offline remote run unexpectedly produced results: $(cat "$work/remote.out")"

# Local fixture repositories analysed with --local; these checks need only the
# file tree, so no token and no network are involved.
checks=Dangerous-Workflow,License,Pinned-Dependencies,Token-Permissions
mkdir -p "$work/bad/.github/workflows" "$work/good/.github/workflows"
cat >"$work/bad/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: make
YAML
cat >"$work/good/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: pull_request
permissions: read-all
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
      - run: make
YAML
printf 'MIT License\n\nCopyright (c) 2026 Verity\n\nPermission is hereby granted, free of charge.\n' \
  >"$work/good/LICENSE"
chmod -R a+rX "$work"

score() {
  jq -r --arg c "$2" '.checks[] | select(.name == $c) | .score' "$1"
}

for repo in bad good; do
  run -v "$work/$repo:/repo:ro" "$image" --local=/repo --checks="$checks" --format json \
    >"$work/$repo.json" 2>"$work/$repo.err" || fail "local $repo run failed: $(cat "$work/$repo.err")"
  jq -e '.repo.name == "file:///repo"' "$work/$repo.json" >/dev/null ||
    fail "unexpected repository in $repo result: $(jq -c .repo "$work/$repo.json")"
  jq -e --arg v "v$version" '.scorecard.version | startswith($v)' "$work/$repo.json" >/dev/null ||
    fail "result does not report scorecard v$version"
  test "$(jq '.checks | length' "$work/$repo.json")" -eq 4 ||
    fail "unexpected check count in $repo result: $(jq -c '[.checks[].name]' "$work/$repo.json")"
done

test "$(score "$work/bad.json" Dangerous-Workflow)" = 0 ||
  fail 'the pull_request_target checkout was not flagged as a dangerous workflow'
test "$(score "$work/bad.json" Pinned-Dependencies)" = 0 ||
  fail 'the unpinned action was not flagged'
test "$(score "$work/bad.json" Token-Permissions)" = 0 ||
  fail 'the missing token permissions were not flagged'
test "$(score "$work/bad.json" License)" = 0 ||
  fail 'a repository without a license file scored above 0'

test "$(score "$work/good.json" Dangerous-Workflow)" = 10 ||
  fail "the safe workflow scored $(score "$work/good.json" Dangerous-Workflow) for Dangerous-Workflow"
test "$(score "$work/good.json" Pinned-Dependencies)" = 10 ||
  fail "the pinned action scored $(score "$work/good.json" Pinned-Dependencies) for Pinned-Dependencies"
test "$(score "$work/good.json" Token-Permissions)" = 10 ||
  fail "read-all permissions scored $(score "$work/good.json" Token-Permissions) for Token-Permissions"
test "$(score "$work/good.json" License)" -ge 9 ||
  fail "the license file scored $(score "$work/good.json" License) for License"

run "$image" --local=/does-not-exist --checks=License --format json \
  >"$work/missing.out" 2>"$work/missing.err" || true
grep -F 'Skipping /does-not-exist: localdir: error in IsValid' "$work/missing.err" >/dev/null ||
  fail "a missing local repository was not rejected: $(cat "$work/missing.err")"
! grep -F '"checks"' "$work/missing.out" >/dev/null ||
  fail 'a missing local repository unexpectedly produced results'

printf 'SMOKE PASS\n'
