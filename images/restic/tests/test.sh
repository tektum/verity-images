#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
repo=$(docker volume create)
helper=docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0

cleanup() {
  docker volume rm -f "$repo" >/dev/null
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/restic"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["version"]' ] ||
  fail 'unexpected default command'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /data ] ||
  fail 'unexpected OCI working directory'

version=$(docker run --rm --network none "$image" version)
printf '%s\n' "$version" | grep -Fq 'restic 0.18.1' || fail 'unexpected Restic version'

mkdir "$work/input"
printf 'restic smoke test\n' > "$work/input/file.txt"
chmod 755 "$work" "$work/input"
docker run --rm --network none --user 0:0 --entrypoint sh \
  -v "$repo:/data" "$helper" -c 'chown 65532:65532 /data'

run_restic() {
  docker run --rm --network none \
    -e RESTIC_PASSWORD=restic-smoke-password \
    -v "$repo:/data" -v "$work/input:/data/input:ro" \
    "$image" --no-cache -r /data/repo "$@"
}

run_restic init >/dev/null || fail 'repository initialization failed'
run_restic backup /data/input >/dev/null || fail 'backup failed'
snapshots=$(run_restic snapshots)
printf '%s\n' "$snapshots" | grep -Fq '/data/input' || fail 'snapshot does not contain the input path'
run_restic restore latest --target /data/restore >/dev/null || fail 'restore failed'
docker run --rm --network none -v "$repo:/data" -v "$work/input:/input:ro" \
  "$helper" cmp /input/file.txt /data/restore/data/input/file.txt ||
  fail 'restored content differs'

set +e
missing=$(docker run --rm --network none \
  -e RESTIC_PASSWORD=restic-smoke-password \
  "$image" --no-cache -r /data/missing cat config 2>&1)
status=$?
set -e
[ "$status" -eq 10 ] || {
  printf '%s\n' "$missing" >&2
  fail 'missing repository did not return exit code 10'
}
printf '%s\n' "$missing" | grep -Fq 'Is there a repository at the following location?' ||
  fail 'missing repository diagnostic not found'

printf 'SMOKE PASS image=%s\n' "$image"
