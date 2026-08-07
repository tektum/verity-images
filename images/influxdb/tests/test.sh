#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-influxdb-test-$$"
volume="verity-influxdb-data-$$"
rootfs=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$rootfs"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/influxd"]'
docker create --name "$container" "$image" >/dev/null
docker export "$container" >"$rootfs"
docker rm "$container" >/dev/null
for path in etc/influxdb2 var/lib/influxdb2; do
  tar --numeric-owner -tvf "$rootfs" "$path" | awk '$2 == "65532/65532" { found = 1 } END { exit !found }'
done
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d \
    -v "$volume:/var/lib/influxdb2" \
    -p 127.0.0.1::8181 \
    "$image" serve --node-id verity --object-store file --data-dir /var/lib/influxdb2 >/dev/null
  port=$(docker port "$container" 8181/tcp | awk -F: 'NR == 1 { print $2 }')

  i=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port/ready" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      docker logs "$container" >&2
      exit 1
    }
    sleep 1
  done
}

start_server
curl --fail --silent --show-error \
  "http://127.0.0.1:$port/api/v3/write_lp?db=verity&precision=second&no_sync=false" \
  --data-raw 'cpu,host=test usage=42.0 1735545600' >/dev/null
curl --fail --silent --show-error "http://127.0.0.1:$port/api/v3/query_sql" \
  -H 'Content-Type: application/json' \
  --data '{"db":"verity","q":"SELECT * FROM cpu LIMIT 1","format":"json"}' | grep -q '42'
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null

start_server
curl --fail --silent --show-error "http://127.0.0.1:$port/api/v3/query_sql" \
  -H 'Content-Type: application/json' \
  --data '{"db":"verity","q":"SELECT * FROM cpu LIMIT 1","format":"json"}' | grep -q '42'
if curl --fail --silent --show-error \
  "http://127.0.0.1:$port/api/v3/write_lp?db=verity&accept_partial=false" \
  --data-raw 'cpu,host=test usage=not-a-float 1735545600' >/dev/null 2>&1; then
  printf '%s\n' 'invalid API request unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
