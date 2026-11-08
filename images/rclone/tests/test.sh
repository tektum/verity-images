#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-rclone-test-$$"
volume="verity-rclone-data-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rclone"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["version"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected image user'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /data ] \
  || fail 'unexpected image working directory'

docker run --rm --network none "$image" version | grep -Fq 'rclone 1.74.' \
  || fail 'unexpected rclone version'

mkdir "$work/src"
printf 'rclone smoke test\n' >"$work/src/file.txt"
chmod 755 "$work" "$work/src"
chmod 644 "$work/src/file.txt"
docker volume create "$volume" >/dev/null

run_rclone() {
  docker run --rm --network none -v "$volume:/data" -v "$work/src:/src:ro" "$image" "$@"
}

run_rclone copy /src /data/dst >/dev/null || fail 'copy failed'
run_rclone check /src /data/dst >/dev/null 2>&1 || fail 'check reported a difference after copy'
[ "$(run_rclone cat /data/dst/file.txt)" = 'rclone smoke test' ] || fail 'copied content differs'

printf 'tampered\n' | docker run --rm -i --network none -v "$volume:/data" "$image" \
  rcat /data/dst/file.txt || fail 'tampering the copy failed'
if run_rclone check /src /data/dst >/dev/null 2>&1; then
  fail 'check did not detect a modified file'
fi

if run_rclone copy /src/missing /data/out >/dev/null 2>&1; then
  fail 'copy of a missing source succeeded'
fi

docker run --name "$container" -d -v "$volume:/data" -p 127.0.0.1::8080 "$image" \
  serve http /data/dst --addr :8080 >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'HTTP port was not published'
attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/file.txt" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'rclone serve http did not become ready'
  sleep 1
done
[ "$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/file.txt")" = tampered ] \
  || fail 'rclone serve http returned unexpected content'

printf 'SMOKE PASS image=%s\n' "$image"
