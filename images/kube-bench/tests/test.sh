#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test -z "$(docker image inspect --format '{{.Config.User}}' "$image")"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kube-bench"]'
version=$(docker run --rm --network none "$image" version)
test "$version" = "v$expected_version"

docker run --rm --network none "$image" run \
  --benchmark cis-1.24 --targets node --check 4.1.2 \
  >"$work/result.log"
grep -F '[PASS] 4.1.2' "$work/result.log" >/dev/null

if docker run --rm --network none "$image" run \
  --benchmark cis-1.24 --targets missing >"$work/invalid.log" 2>&1; then
  printf '%s\n' 'invalid target unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'are not configured for the CIS Benchmark cis-1.24' \
  "$work/invalid.log" >/dev/null

printf 'SMOKE PASS image=%s\n' "$image"
