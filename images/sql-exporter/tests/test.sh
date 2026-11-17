#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-sql-exporter-postgres-$$"
exporter="verity-sql-exporter-exporter-$$"
denied="verity-sql-exporter-denied-$$"
network="verity-sql-exporter-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" "$denied" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

psql_exec() {
  docker exec "$backend" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U exporter -d inventory -tAc "$1" >/dev/null ||
    fail "fixture SQL failed: $1"
}

wait_metrics() {
  # $1 container, $2 host port, $3 output file, $4 required line (fixed, whole line)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 10 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -Fx "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      docker logs "$1" >&2
      cat "$3" >&2 || true
      fail "metrics did not contain: $4"
    }
    sleep 1
  done
}

write_config() {
  # $1 output file, $2 data source name
  cat >"$1" <<EOF
global:
  scrape_timeout: 10s
  scrape_timeout_offset: 500ms
  min_interval: 0s
  max_connections: 2
  max_idle_connections: 2
target:
  data_source_name: '$2'
  collectors: [verity_inventory]
collectors:
  - collector_name: verity_inventory
    metrics:
      - metric_name: verity_inventory_quantity
        type: gauge
        help: Units in stock per color, summed by a SQL query.
        key_labels: [color]
        values: [total]
        query: |
          SELECT color, SUM(quantity)::bigint AS total
          FROM widgets
          GROUP BY color
EOF
  chmod 0644 "$1"
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/sql_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm --network none "$image" -version >"$tmp/version" 2>&1 ||
  fail 'version command failed'
grep -F "sql_exporter, version $expected_version " "$tmp/version" >/dev/null || {
  cat "$tmp/version" >&2
  fail "version output does not report $expected_version"
}

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$postgres_index"
postgres=$helper

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=exporter -e POSTGRES_PASSWORD=exporter-secret -e POSTGRES_DB=inventory \
  "$postgres" >/dev/null
attempts=0
until docker exec "$backend" pg_isready -h 127.0.0.1 -U exporter -d inventory >/dev/null 2>&1 &&
  docker exec "$backend" psql -h 127.0.0.1 -U exporter -d inventory -tAc 'select 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$backend" >&2; fail 'postgres fixture did not become ready'; }
  sleep 1
done
psql_exec 'CREATE TABLE widgets (color text NOT NULL, quantity integer NOT NULL)'
psql_exec "INSERT INTO widgets VALUES ('red', 3), ('red', 4), ('blue', 11)"

mkdir "$tmp/config" "$tmp/denied"
chmod 0755 "$tmp/config" "$tmp/denied"
write_config "$tmp/config/sql_exporter.yml" \
  'postgres://exporter:exporter-secret@postgres:5432/inventory?sslmode=disable'
write_config "$tmp/denied/sql_exporter.yml" \
  'postgres://exporter:wrong-password@postgres:5432/inventory?sslmode=disable'

docker run --rm --network none -v "$tmp/config:/etc/sql_exporter:ro" "$image" \
  -config.file=/etc/sql_exporter/sql_exporter.yml -config.check >"$tmp/check.log" 2>&1 || {
  cat "$tmp/check.log" >&2
  fail 'valid configuration failed -config.check'
}

docker run --name "$exporter" -d --network "$network" --read-only \
  -v "$tmp/config:/etc/sql_exporter:ro" -p 127.0.0.1::9399 "$image" \
  -config.file=/etc/sql_exporter/sql_exporter.yml >/dev/null
port=$(docker port "$exporter" 9399/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" || fail 'exporter port 9399 is not published'

# Values come from the SUM() query, so they prove a live PostgreSQL round trip.
wait_metrics "$exporter" "$port" "$tmp/metrics" 'verity_inventory_quantity{color="red"} 7'
grep -Fx 'verity_inventory_quantity{color="blue"} 11' "$tmp/metrics" >/dev/null ||
  fail 'blue quantity metric missing or wrong'
grep -Fx '# TYPE verity_inventory_quantity gauge' "$tmp/metrics" >/dev/null ||
  fail 'quantity metric is not a gauge'

# min_interval is 0s, so a data change must show on the next scrape.
psql_exec "INSERT INTO widgets VALUES ('red', 5), ('green', 2)"
wait_metrics "$exporter" "$port" "$tmp/metrics.updated" 'verity_inventory_quantity{color="red"} 12'
grep -Fx 'verity_inventory_quantity{color="green"} 2' "$tmp/metrics.updated" >/dev/null ||
  fail 'new green row did not appear in metrics'

# Rejected credentials must fail the scrape with HTTP 500 and the server's
# authentication error, never stale or partial query metrics.
docker run --name "$denied" -d --network "$network" --read-only \
  -v "$tmp/denied:/etc/sql_exporter:ro" -p 127.0.0.1::9399 "$image" \
  -config.file=/etc/sql_exporter/sql_exporter.yml >/dev/null
denied_port=$(docker port "$denied" 9399/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$denied_port" || fail 'denied exporter port 9399 is not published'
attempts=0
until denied_status=$(curl --silent --connect-timeout 1 --max-time 10 --output "$tmp/denied.metrics" \
  --write-out '%{http_code}' "http://127.0.0.1:$denied_port/metrics" 2>/dev/null) &&
  [ "$denied_status" != 000 ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$denied" >&2; fail 'denied exporter never answered'; }
  sleep 1
done
[ "$denied_status" = 500 ] || fail "rejected credentials returned HTTP $denied_status, want 500"
grep -F 'password authentication failed for user "exporter"' "$tmp/denied.metrics" >/dev/null || {
  cat "$tmp/denied.metrics" >&2
  fail 'rejected credentials error does not report the authentication failure'
}
if grep -F 'verity_inventory_quantity' "$tmp/denied.metrics" >/dev/null; then
  fail 'rejected credentials still produced query metrics'
fi
[ "$(docker inspect --format '{{.State.Running}}' "$denied")" = true ] ||
  fail 'exporter exited after a failed scrape'

printf 'global:\n  no_such_option: true\n' >"$tmp/config/invalid.yml"
chmod 0644 "$tmp/config/invalid.yml"
if docker run --rm --network none -v "$tmp/config:/etc/sql_exporter:ro" "$image" \
  -config.file=/etc/sql_exporter/invalid.yml -config.check >"$tmp/invalid.log" 2>&1; then
  fail 'invalid configuration unexpectedly passed -config.check'
fi
grep -F 'no_such_option' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid configuration error does not name the unknown key'
}

# A handler-less Go binary exits with status 2 on SIGTERM as PID 1; 137 would
# mean the signal was ignored.
docker stop --time 30 "$exporter" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$exporter") in
  0|2) ;;
  *) fail 'SIGTERM did not stop the exporter' ;;
esac
# Exit 2 is also the Go runtime's status for a panic or fatal error, so only
# accept it when the log shows no crash.
shutdown_log=$(docker logs "$exporter" 2>&1) || fail 'could not read the sql-exporter log after SIGTERM'
if printf '%s\n' "$shutdown_log" | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)'; then
  printf '%s\n' "$shutdown_log" | tail -n 40 >&2
  fail 'sql-exporter crashed (Go panic or fatal error) instead of stopping on SIGTERM'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
