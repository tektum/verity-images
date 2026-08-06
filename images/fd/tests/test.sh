#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
workdir=$(mktemp -d)

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

touch "$workdir/verity-marker"
chmod 755 "$workdir"
chmod 644 "$workdir/verity-marker"

[ "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")" = '["/usr/bin/fd"] null' ]
[ "$(docker run --rm -v "$workdir:/work:ro" "$image" '^verity-marker$' /work)" = '/work/verity-marker' ]

if docker run --rm -v "$workdir:/work:ro" "$image" '[' /work >/dev/null 2>&1; then
  exit 1
fi

printf '%s\n' verity
