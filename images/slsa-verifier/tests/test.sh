#!/bin/bash
set -eu

# Real verification needs tuf-repo-cdn.sigstore.dev; upstream has no offline trust root option (v2.7.1).
# slsa-verifier always refreshes the Sigstore TUF root before it parses provenance, and
# offline that refresh retries for minutes instead of failing. This test therefore covers
# the CLI contract offline: version, help, and argument and input errors that are rejected
# before any trust root fetch. Every run is bounded so a network wait fails the test.

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- slsa-verifier=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
label="verity-test=slsa-verifier-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'slsa-verifier package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/slsa-verifier"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

printf 'artifact\n' >"$work/artifact"
printf '{}\n' >"$work/provenance.intoto.jsonl"
chmod -R a+rX "$work"

# run EXPECTED_STATUS_KIND ARGS...; prints combined output. A timeout (124) always fails.
run() {
  local status=0 output
  output=$(timeout 30 docker run --rm --label "$label" --network none -v "$work:/f:ro" \
    "$image" "$@" 2>&1) || status=$?
  [ "$status" != 124 ] || fail "timed out (network wait?): slsa-verifier $*"
  RUN_STATUS=$status
  RUN_OUTPUT=$output
}

run version
[ "$RUN_STATUS" = 0 ] || fail "version exited $RUN_STATUS: $RUN_OUTPUT"
printf '%s\n' "$RUN_OUTPUT" | grep -Eq "^GitVersion:[[:space:]]+v${expected_version}([+-].*)?$" ||
  fail "unexpected version output: $RUN_OUTPUT"

run verify-artifact --help
[ "$RUN_STATUS" = 0 ] || fail "verify-artifact --help exited $RUN_STATUS"
for flag in --provenance-path --source-uri --builder-id --source-tag; do
  printf '%s\n' "$RUN_OUTPUT" | grep -q -- "$flag" || fail "help is missing $flag"
done

expect_failure() {
  local message=$1
  shift
  run "$@"
  [ "$RUN_STATUS" != 0 ] || fail "unexpectedly succeeded: slsa-verifier $*"
  printf '%s\n' "$RUN_OUTPUT" | grep -qF "$message" ||
    fail "missing '$message' for slsa-verifier $*: $RUN_OUTPUT"
}

expect_failure 'required flag(s) "provenance-path" not set' \
  verify-artifact /f/artifact --source-uri github.com/example/repo
expect_failure 'required flag(s) "source-uri" not set' \
  verify-artifact /f/artifact --provenance-path /f/provenance.intoto.jsonl
expect_failure 'open /f/missing: no such file or directory' \
  verify-artifact /f/missing --provenance-path /f/provenance.intoto.jsonl --source-uri github.com/example/repo
expect_failure 'open /f/missing.intoto.jsonl: no such file or directory' \
  verify-artifact /f/artifact --provenance-path /f/missing.intoto.jsonl --source-uri github.com/example/repo
expect_failure 'unknown command "verify-everything"' verify-everything
expect_failure 'unknown flag: --no-such-flag' verify-artifact --no-such-flag

printf 'SMOKE PASS version=%s\n' "$expected_version"
