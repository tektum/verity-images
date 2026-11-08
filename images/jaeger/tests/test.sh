#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-jaeger-test-$$"
tmp=$(mktemp -d)
trace_id=5b8efff798038103d269b633813fc60c

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 10001 ] \
  || fail 'image user is not 10001'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/jaeger"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" version 2>&1 | grep -F '"gitVersion":"v2.' >/dev/null \
  || fail 'jaeger v2 version check failed'

docker run --name "$container" -d --read-only \
  -p 127.0.0.1::16686 -p 127.0.0.1::4318 \
  "$image" --set=receivers.otlp.protocols.http.endpoint=0.0.0.0:4318 >/dev/null
ui=$(docker port "$container" 16686/tcp | awk -F: 'NR == 1 { print $2 }')
otlp=$(docker port "$container" 4318/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$ui" ] && [ -n "$otlp" ] || fail 'jaeger ports were not published'

attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$ui/"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'jaeger UI did not become ready'
  sleep 1
done
printf '%s' "$response" | grep -Fi '<!doctype html>' >/dev/null || fail 'jaeger UI response was not HTML'

attempt=0
until curl --fail --silent --show-error -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:$otlp/v1/traces" \
  --data "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verity-smoke\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$trace_id\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"verity-span\",\"kind\":1,\"startTimeUnixNano\":\"1700000000000000000\",\"endTimeUnixNano\":\"1700000001000000000\"}]}]}]}" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || fail 'OTLP span was not accepted'
  sleep 1
done

attempt=0
until curl --fail --silent "http://127.0.0.1:$ui/api/traces/$trace_id" | grep -F 'verity-span' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || fail 'trace was not queryable through the Jaeger API'
  sleep 1
done

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'jaeger did not stop cleanly'
docker rm "$container" >/dev/null

printf '%s\n' 'not: [valid' >"$tmp/invalid.yaml"
chmod 644 "$tmp/invalid.yaml"
if invalid=$(docker run --rm -v "$tmp/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" --config /tmp/invalid.yaml 2>&1); then
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Fi 'yaml' >/dev/null \
  || fail 'invalid configuration did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
