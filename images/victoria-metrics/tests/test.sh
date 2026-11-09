#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-victoria-metrics-test-$$"
volume="verity-victoria-metrics-data-$$"

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
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/victoria-metrics"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-storageDataPath=/victoria-metrics-data"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" -version 2>&1 | grep -F 'victoria-metrics-tags-v1.' >/dev/null \
  || fail 'victoria-metrics version check failed'

docker volume create "$volume" >/dev/null

start() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --name "$container" -d --read-only -v "$volume:/victoria-metrics-data" \
    -p 127.0.0.1::8428 "$image" >/dev/null
  port=$(docker port "$container" 8428/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'port 8428 was not published'
  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail 'victoria-metrics did not become healthy'
    sleep 1
  done
  [ "$response" = OK ] || fail 'health response was not OK'
}

query() {
  curl --fail --silent --show-error --get "http://127.0.0.1:$port/api/v1/query" \
    --data-urlencode 'query=verity_smoke_metric' | grep -F '"42"' >/dev/null
}

stop_clean() {
  docker stop --time 30 "$container" >/dev/null
  [ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
    || fail 'victoria-metrics did not stop cleanly'
}

start
curl --fail --silent --show-error -X POST \
  "http://127.0.0.1:$port/api/v1/import/prometheus" \
  --data-binary "verity_smoke_metric{job=\"verity\"} 42 $(( $(date +%s) - 120 ))000" >/dev/null \
  || fail 'sample import failed'
attempt=0
until query; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail 'imported sample was not queryable'
  sleep 1
done

stop_clean
start
query || fail 'sample did not survive restart'
stop_clean
docker rm "$container" >/dev/null

if invalid=$(docker run --rm "$image" -no-such-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'flag provided but not defined' >/dev/null \
  || fail 'invalid flag did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
