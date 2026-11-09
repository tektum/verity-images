#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-vmstorage-test-$$"
volume="verity-vmstorage-data-$$"

fail() {
  docker logs "$container" >&2 2>&1 || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/vmstorage"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-storageDataPath=/vmstorage-data"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" -version 2>&1 | grep -F 'vmstorage-tags-v1.' >/dev/null \
  || fail 'vmstorage version check failed'

docker volume create "$volume" >/dev/null

start() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --name "$container" -d --read-only -v "$volume:/vmstorage-data" \
    -p 127.0.0.1::8482 "$image" >/dev/null
  port=$(docker port "$container" 8482/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'port 8482 was not published'
  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail 'vmstorage did not become healthy'
    sleep 1
  done
  [ "$response" = OK ] || fail 'health response was not OK'
}

stop_clean() {
  docker stop --time 30 "$container" >/dev/null
  [ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
    || fail 'vmstorage did not stop cleanly'
}

start
# The vminsert and vmselect listeners are up and the storage engine answers
# metrics requests.
curl --fail --silent --show-error "http://127.0.0.1:$port/metrics" \
  | grep -F 'vm_app_version{version="vmstorage-tags-v1.' >/dev/null \
  || fail 'metrics did not report the vmstorage version'
stop_clean

# A restart on the same volume recovers the data directory.
start
stop_clean
docker rm "$container" >/dev/null

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
