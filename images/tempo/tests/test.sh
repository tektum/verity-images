#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-tempo-test-$$"
volume="verity-tempo-data-$$"
tmp=$(mktemp -d)
trace_id=5b8efff798038103d269b633813fc60c

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/tempo"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'version 3.0.' >/dev/null \
  || fail 'tempo version check failed'

cat >"$tmp/config.yaml" <<'EOF'
server:
  http_listen_port: 3200
distributor:
  receivers:
    otlp:
      protocols:
        http:
          endpoint: 0.0.0.0:4318
storage:
  trace:
    backend: local
    wal:
      path: /var/tempo/wal
    local:
      path: /var/tempo/blocks
usage_report:
  reporting_enabled: false
EOF
chmod 644 "$tmp/config.yaml"

start() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --name "$container" -d --read-only \
    -v "$volume:/var/tempo" -v "$tmp/config.yaml:/tmp/tempo.yaml:ro" \
    -p 127.0.0.1::3200 -p 127.0.0.1::4318 \
    "$image" -target=all -backend-worker.finish-on-shutdown-timeout=1s \
    -config.file=/tmp/tempo.yaml >/dev/null
  http=$(docker port "$container" 3200/tcp | awk -F: 'NR == 1 { print $2 }')
  otlp=$(docker port "$container" 4318/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$http" ] && [ -n "$otlp" ] || fail 'tempo ports were not published'

  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$http/ready"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || fail 'tempo did not become ready'
    sleep 1
  done
  printf '%s' "$response" | grep -F ready >/dev/null || fail 'tempo readiness response was unexpected'
}

push_trace() {
  curl --fail --silent --show-error -H 'Content-Type: application/json' \
    -X POST "http://127.0.0.1:$otlp/v1/traces" \
    --data "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verity-smoke\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$trace_id\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"verity-span\",\"kind\":1,\"startTimeUnixNano\":\"1700000000000000000\",\"endTimeUnixNano\":\"1700000001000000000\"}]}]}]}" >/dev/null \
    || fail 'OTLP span was not accepted'
}

docker volume create "$volume" >/dev/null

# Push a trace and read it back by id. Tempo does not exit on SIGTERM once the
# query path has been used, so this container is removed instead of stopped.
start
push_trace
attempt=0
until curl --fail --silent "http://127.0.0.1:$http/api/traces/$trace_id" | grep -F 'verity-smoke' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'trace was not queryable by id'
  sleep 1
done

# A fresh instance must handle SIGTERM with exit status 0 after ingesting data.
start
push_trace
docker stop --time 30 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
[ "$code" = 0 ] || fail "tempo did not stop cleanly (exit $code)"
docker rm "$container" >/dev/null

printf '%s\n' 'not: [valid' >"$tmp/invalid.yaml"
chmod 644 "$tmp/invalid.yaml"
if invalid=$(docker run --rm -v "$tmp/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" -config.file=/tmp/invalid.yaml 2>&1); then
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Ei 'yaml|parse' >/dev/null \
  || fail 'invalid configuration did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
