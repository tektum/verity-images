#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'fixture\n' > "$work/input.txt"

docker run --rm -v "$work:/fixture:ro" "$image" filesystem --scanners secret --format json /fixture > "$work/report.json"
grep -q '"SchemaVersion": 2' "$work/report.json"
grep -q '"ArtifactType": "filesystem"' "$work/report.json"

if docker run --rm "$image" filesystem --scanners secret /missing >/dev/null 2>&1; then
  printf 'invalid target unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
