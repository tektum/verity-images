#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/cache"
chmod 0777 "$work/cache"
printf 'fixture\n' > "$work/input.txt"

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]
docker run --rm "$image" version --format json | grep -Fq "\"Version\":\"$expected_version\""
docker run --rm -v "$work:/fixture:ro" -v "$work/cache:/home/nonroot/.cache/trivy" "$image" filesystem --scanners secret --format json /fixture > "$work/report.json"
grep -q '"SchemaVersion": 2' "$work/report.json"
grep -q '"ArtifactType": "filesystem"' "$work/report.json"

if docker run --rm "$image" filesystem --scanners secret /missing >/dev/null 2>&1; then
  printf 'invalid target unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
