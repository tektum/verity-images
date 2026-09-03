#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
postgres='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-pgbouncer-postgres-$$"
pooler="verity-pgbouncer-pooler-$$"
network="verity-pgbouncer-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$pooler" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/pgbouncer","/etc/pgbouncer/pgbouncer.ini"]'
docker run --rm --entrypoint /usr/bin/pgbouncer "$image" --version |
  grep -F "PgBouncer $expected_version" >/dev/null

cat >"$tmp/pgbouncer.ini" <<'EOF'
[databases]
postgres = host=postgres port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
unix_socket_dir = /tmp/pgbouncer
auth_type = trust
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
pidfile = /tmp/pgbouncer/pgbouncer.pid
logfile = /var/log/pgbouncer/pgbouncer.log
EOF
printf '"smoke" ""\n' >"$tmp/userlist.txt"
chmod 644 "$tmp/pgbouncer.ini" "$tmp/userlist.txt"

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$postgres" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -U smoke -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    exit 1
  }
  sleep 1
done

docker run --name "$pooler" -d --network "$network" --network-alias pgbouncer \
  -v "$tmp/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
  -v "$tmp/userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
  "$image" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -h pgbouncer -p 6432 -U smoke -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$pooler" >&2
    exit 1
  }
  sleep 1
done

result=$(docker exec "$backend" psql -h pgbouncer -p 6432 -U smoke -d postgres -Atqc \
  "SELECT current_user || ':' || current_database() || ':' || 6 * 7")
test "$result" = 'smoke:postgres:42'
docker cp "$pooler:/var/log/pgbouncer/pgbouncer.log" "$tmp/pgbouncer.log" >/dev/null
test -s "$tmp/pgbouncer.log"

printf '%s\n' '[pgbouncer' >"$tmp/invalid.ini"
chmod 644 "$tmp/invalid.ini"
if docker run --rm -v "$tmp/invalid.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
  "$image" >/dev/null 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
