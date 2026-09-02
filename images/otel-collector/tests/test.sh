#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
tmp=$(mktemp -d)
container="verity-otel-collector-test-$$"

fail() {
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
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/otelcol"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--config","/etc/otelcol/config.yaml"]' ] \
  || fail 'unexpected image command'
docker run --rm "$image" --version 2>&1 \
  | grep -F "otelcol version $expected_version" >/dev/null \
  || fail 'collector version check failed'

wait_ready() {
  i=0
  until docker logs "$container" 2>&1 | grep -F 'Everything is ready. Begin running and processing data.' >/dev/null; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'collector exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      docker logs "$container" >&2
      fail 'collector did not become ready'
    }
    sleep 1
  done
}

docker run --name "$container" -d --read-only "$image" >/dev/null
wait_ready
docker stop --time 10 "$container" >/dev/null
docker rm "$container" >/dev/null

cat >"$tmp/config.yaml" <<'EOF'
receivers:
  nop:
exporters:
  nop:
service:
  pipelines:
    traces:
      receivers: [nop]
      exporters: [nop]
EOF

docker run --name "$container" -d --read-only \
  -v "$tmp/config.yaml:/tmp/config.yaml:ro" \
  "$image" --config /tmp/config.yaml >/dev/null
wait_ready
docker stop --time 10 "$container" >/dev/null
docker rm "$container" >/dev/null

if docker run --rm "$image" --config /tmp/missing.yaml >/dev/null 2>&1; then
  fail 'missing configuration unexpectedly succeeded'
fi

printf '%s\n' 'not: [valid' >"$tmp/invalid.yaml"
if docker run --rm -v "$tmp/invalid.yaml:/tmp/invalid.yaml:ro" \
  "$image" --config /tmp/invalid.yaml >/dev/null 2>&1; then
  fail 'invalid configuration unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
