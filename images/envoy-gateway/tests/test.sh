#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
commit=$(sed -n 's/^ *expected-commit: //p' "$recipe")

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/local/bin/envoy-gateway"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only "$image" version >"$work/version" 2>&1 ||
  fail 'version command failed'
grep -Fx "ENVOY_GATEWAY_VERSION: v${version}" "$work/version" >/dev/null ||
  fail 'controller version is not embedded'
grep -Fx "GIT_COMMIT_ID: ${commit}" "$work/version" >/dev/null ||
  fail 'controller commit is not embedded'

docker run --rm --network none --read-only --entrypoint /usr/local/bin/egctl \
  "$image" --help >"$work/egctl" 2>&1 || fail 'egctl help failed'
grep -F 'Usage:' "$work/egctl" >/dev/null || fail 'egctl usage text is missing'

docker run --rm --network none --read-only --entrypoint /bin/sh "$image" \
  -c 'test -w /var/lib/eg' >/dev/null 2>&1 ||
  fail '/var/lib/eg is not writable'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" server \
  --config-path=/definitely-missing >"$work/startup" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'open /definitely-missing: no such file or directory' "$work/startup" >/dev/null ||
  fail 'missing config diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
