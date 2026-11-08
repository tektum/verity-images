#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-otel-collector-contrib-test-$$"
tmp=$(mktemp -d)

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
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/otelcol-contrib"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'otelcontribcol version 0.164.' >/dev/null \
  || fail 'collector version check failed'
docker run --rm "$image" components 2>&1 | grep -F 'filelogreceiver' >/dev/null \
  || fail 'contrib components are missing'

cat >"$tmp/config.yaml" <<'EOF'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
EOF
chmod 644 "$tmp/config.yaml"

docker run --name "$container" -d --read-only \
  -v "$tmp/config.yaml:/tmp/config.yaml:ro" \
  -p 127.0.0.1::4318 -p 127.0.0.1::13133 \
  "$image" --config /tmp/config.yaml >/dev/null
health=$(docker port "$container" 13133/tcp | awk -F: 'NR == 1 { print $2 }')
otlp=$(docker port "$container" 4318/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$health" ] && [ -n "$otlp" ] || fail 'collector ports were not published'

attempt=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$health/"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'collector did not become healthy'
  sleep 1
done
printf '%s' "$response" | grep -F 'Server available' >/dev/null || fail 'health_check response was unexpected'

curl --fail --silent --show-error -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:$otlp/v1/traces" \
  --data '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"verity-smoke"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"verity-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000"}]}]}]}' >/dev/null

attempt=0
until docker logs "$container" 2>&1 | grep -F 'verity-span' >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || fail 'OTLP span did not reach the debug exporter'
  sleep 1
done

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] \
  || fail 'collector did not stop cleanly'
docker rm "$container" >/dev/null

if docker run --rm "$image" --config /tmp/missing.yaml >/dev/null 2>&1; then
  fail 'missing configuration unexpectedly succeeded'
fi

printf '%s\n' 'not: [valid' >"$tmp/invalid.yaml"
chmod 644 "$tmp/invalid.yaml"
if invalid=$(docker run --rm -v "$tmp/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" --config /tmp/invalid.yaml 2>&1); then
  fail 'invalid configuration unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Eqi 'yaml|unmarshal|parse|invalid' \
  || fail 'invalid configuration did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
