#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container=postgres-18-trixie-smoke-$$
volume=$container-data
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' smoke-password > "$tmp/password"
cat > "$tmp/init.sql" <<'EOF'
CREATE TABLE smoke_marker (value text);
INSERT INTO smoke_marker VALUES ('initialized');
EOF
docker volume create "$volume" >/dev/null

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["docker-entrypoint.sh"]'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["postgres"]'
test "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGINT
test -z "$(docker image inspect --format '{{.Config.User}}' "$image")"
docker image inspect --format '{{range $path, $_ := .Config.Volumes}}{{println $path}}{{end}}' "$image" \
  | grep -qx /var/lib/postgresql

# Without a superuser password the entrypoint must refuse to initialize.
if docker run --rm "$image" >"$tmp/negative.log" 2>&1; then
  cat "$tmp/negative.log"
  printf 'image started without POSTGRES_PASSWORD\n' >&2
  exit 1
fi
grep -q 'Database is uninitialized and superuser password is not specified' "$tmp/negative.log"

start() {
  docker run -d --name "$container" \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/password \
    -v "$volume":/var/lib/postgresql \
    -v "$tmp/password":/run/secrets/password:ro \
    -v "$tmp/init.sql":/docker-entrypoint-initdb.d/10-marker.sql:ro \
    "$image" >/dev/null
}

ready() {
  attempts=0
  while ! docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      docker logs "$container"
      return 1
    fi
    sleep 1
  done
}

marker() {
  docker exec "$container" sh -c \
    'PGPASSWORD=smoke-password psql -h 127.0.0.1 -U postgres -d postgres -Atqc "$1"' \
    sh "$1"
}

start
ready
docker top "$container" -eo pid,uid,comm | awk '$3 == "postgres" { found = 1; if ($2 != 999) exit 1 } END { exit !found }'
docker exec "$container" sh -c \
  'test "$PGDATA" = /var/lib/postgresql/18/docker'
docker exec "$container" sh -c \
  'PGPASSWORD=smoke-password psql -h 127.0.0.1 -U postgres -d postgres -Atqc "SHOW server_version_num"' \
  | grep -q '^18'
test "$(marker 'SELECT value FROM smoke_marker')" = initialized
test "$(marker "SELECT datcollate FROM pg_database WHERE datname = 'postgres'")" = en_US.utf8
marker 'CREATE EXTENSION pgcrypto' >/dev/null
test "$(marker "SELECT length(encode(digest('x', 'sha256'), 'hex'))")" = 64
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null

start
ready
test "$(marker 'SELECT count(*) FROM smoke_marker WHERE value = '\''initialized'\''')" = 1
