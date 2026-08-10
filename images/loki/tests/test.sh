#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-loki-test-$$"
volume="verity-loki-data-$$"
config=$(mktemp)
invalid_config=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid_config"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 10001 || fail 'image user is not 10001'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/loki"]' || fail 'unexpected image entrypoint'
test "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["-config.file=/etc/loki/local-config.yaml"]' || fail 'unexpected image command'

cat > "$config" <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2020-05-15
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  filesystem:
    directory: /loki/chunks
EOF
chmod 644 "$config"

docker volume create "$volume" >/dev/null

start() {
  docker run --name "$container" -d --read-only \
    -v "$volume:/loki" -v "$config:/etc/loki/verity.yaml:ro" \
    -p 127.0.0.1::3100 "$image" -config.file=/etc/loki/verity.yaml >/dev/null
  port=$(docker port "$container" 3100/tcp | awk -F: 'NR == 1 { print $2 }')
  test -n "$port" || fail 'Loki port 3100 was not published'

  attempt=0
  until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/ready"); do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || fail 'Loki did not become ready'
    sleep 1
  done
  printf '%s' "$response" | grep -Fq ready || fail 'Loki readiness response was unexpected'
}

query_log() {
  curl --fail --silent --show-error --get "http://127.0.0.1:$port/loki/api/v1/query_range" \
    --data-urlencode 'query={job="verity"}' | grep -Fq 'loki works'
}

start

timestamp="$(date +%s)000000000"
curl --fail --silent --show-error -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:$port/loki/api/v1/push" \
  --data "{\"streams\":[{\"stream\":{\"job\":\"verity\"},\"values\":[[\"$timestamp\",\"loki works\"]]}]}" >/dev/null
query_log || fail 'Loki push/query roundtrip failed'

docker stop --time 30 "$container" >/dev/null
test "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 || fail 'Loki did not stop cleanly'
docker rm "$container" >/dev/null
start
query_log || fail 'Loki log did not survive restart'

if missing=$(docker run --rm "$image" -config.file=/tmp/missing.yaml -verify-config 2>&1); then
  fail 'missing config unexpectedly succeeded'
fi
printf '%s' "$missing" | grep -Eqi 'does not exist|no such file|error loading config' || fail 'missing config did not return a file error'

printf 'not: [valid\n' > "$invalid_config"
chmod 644 "$invalid_config"
if invalid=$(docker run --rm -v "$invalid_config:/tmp/invalid.yaml:ro" \
  "$image" -config.file=/tmp/invalid.yaml -verify-config 2>&1); then
  fail 'invalid config unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -Eqi 'yaml|unmarshal|parse' || fail 'invalid config did not return a parse error'

printf 'SMOKE PASS image=%s\n' "$image"
