#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-vminsert-test-$$"

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vminsert"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" -version 2>&1 | grep -F 'vminsert-tags-v1.' >/dev/null \
  || fail 'vminsert version check failed'

# vminsert has no storage of its own: point it at an unreachable vmstorage and
# assert it serves its API while retrying the connection with a readable error.
docker run --name "$container" -d --read-only -p 127.0.0.1::8480 "$image" \
  -storageNode=127.0.0.1:1 >/dev/null
port=$(docker port "$container" 8480/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 8480 was not published'
attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'vminsert did not become healthy'
  sleep 1
done
[ "$response" = OK ] || fail 'health response was not OK'
attempt=0
until docker logs "$container" 2>&1 | grep -F 'cannot dial storageNode "127.0.0.1:1"' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'vminsert did not log the storage node retry'
  sleep 1
done
curl --fail --silent --show-error "http://127.0.0.1:$port/metrics" \
  | grep -F 'vm_app_version{version="vminsert-tags-v1.' >/dev/null \
  || fail 'metrics did not report the vminsert version'
docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'vminsert did not stop cleanly'
docker rm "$container" >/dev/null

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
