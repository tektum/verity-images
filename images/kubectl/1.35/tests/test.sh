#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

client_version=$(docker run --rm "$image" version --client --output=yaml |
  awk '$1 == "gitVersion:" { print $2 }')
test "$client_version" = v1.35.7
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
