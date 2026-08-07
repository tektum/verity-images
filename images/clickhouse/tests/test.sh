#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-clickhouse-test-$$"
volume="verity-clickhouse-data-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/clickhouse-server"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /var/lib/clickhouse ] || fail 'unexpected image working directory'
docker run --rm --entrypoint /usr/bin/clickhouse-server "$image" --version >/dev/null || fail 'ClickHouse server is missing'
docker run --rm --entrypoint /usr/bin/clickhouse-client "$image" --version >/dev/null || fail 'ClickHouse client is missing'
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d -v "$volume:/var/lib/clickhouse" \
    -p 127.0.0.1::8123 -p 127.0.0.1::9000 "$image" >/dev/null
  http_port=$(docker port "$container" 8123/tcp | awk -F: 'NR == 1 { print $2 }')
  native_port=$(docker port "$container" 9000/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$http_port" ] && [ -n "$native_port" ] || fail 'ClickHouse ports were not mapped'

  i=0
  until docker exec "$container" clickhouse-client --query 'SELECT 1' 2>/dev/null | grep -Fx 1 >/dev/null; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'ClickHouse exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 60 ] || {
      docker logs "$container" >&2
      fail 'ClickHouse did not become ready on native port 9000'
    }
    sleep 1
  done
}

start_server
# CI runs Docker on Linux; host networking validates the mapped-port boundary.
http_error=$(docker run --rm --network host "$fixture" --fail --silent --show-error \
  --data-binary 'SELECT 1' "http://127.0.0.1:$http_port/" 2>&1) \
  && fail 'unauthenticated HTTP access escaped the container'
printf '%s\n' "$http_error" | grep -qiE 'failed to connect|connection reset|recv failure' || \
  fail "expected connection refusal on host HTTP port, got: $http_error"
native_error=$(docker run --rm --network host --entrypoint /usr/bin/clickhouse-client "$image" \
  --host 127.0.0.1 --port "$native_port" --query 'SELECT 1' 2>&1) \
  && fail 'unauthenticated native access escaped the container'
printf '%s\n' "$native_error" | grep -qiE 'connection refused|connection reset|cannot connect' || \
  fail "expected connection refusal on host native port, got: $native_error"
[ "$(docker run --rm --network "container:$container" "$fixture" --fail --silent --show-error \
  --data-binary 'SELECT 42' http://127.0.0.1:8123/)" = 42 ] || fail 'HTTP query on port 8123 failed'
[ "$(docker exec "$container" clickhouse-client --query 'SELECT 40 + 2')" = 42 ] || fail 'native query on port 9000 failed'
docker exec "$container" clickhouse-client --multiquery --query \
  "CREATE TABLE verity (value UInt8) ENGINE = MergeTree ORDER BY tuple(); INSERT INTO verity VALUES (42)"
docker stop --time 30 "$container" >/dev/null
docker rm "$container" >/dev/null

start_server
[ "$(docker exec "$container" clickhouse-client --query 'SELECT value FROM verity')" = 42 ] || fail 'persisted table was not restored'
if error=$(docker exec "$container" clickhouse-client --query 'NOT VALID SQL' 2>&1); then
  fail 'invalid SQL unexpectedly succeeded'
fi
printf '%s\n' "$error" | grep -qi 'syntax error' || fail 'invalid SQL did not report a syntax error'

printf 'SMOKE PASS image=%s\n' "$image"
