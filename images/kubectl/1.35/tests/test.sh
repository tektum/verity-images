#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

expected_version=$(sed -n 's/^[[:space:]]*version: "\([^\"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
client_version=$(docker run --rm "$image" version --client --output=yaml |
  awk '$1 == "gitVersion:" { print $2 }')
test "$client_version" = "v$expected_version"
printf 'CLIENT VERSION %s\n' "$client_version"

manifest_output=$(printf '%s\n' \
  'apiVersion: v1' \
  'kind: ConfigMap' \
  'metadata:' \
  '  name: verity-smoke' |
  docker run --rm -i "$image" label --local --dry-run=client -f - verity-smoke=true -o name)
test "$manifest_output" = configmap/verity-smoke
printf 'DRY RUN %s\n' "$manifest_output"

if docker run --rm "$image" version --client --not-a-real-flag >/dev/null 2>&1; then
  printf 'invalid flag unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS\n'
