#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
postgres='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-pgweb-postgres-$$"
web="verity-pgweb-web-$$"
network="verity-pgweb-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$web" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/pgweb","--bind","0.0.0.0","--listen","8081","--skip-open"]'
docker run --rm --entrypoint /usr/bin/pgweb "$image" --version |
  grep -F "Pgweb v$expected_version" >/dev/null

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke \
  -e POSTGRES_DB=postgres \
  "$postgres" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -U postgres -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    exit 1
  }
  sleep 1
done

docker run --name "$web" -d --network "$network" --read-only \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -p 127.0.0.1::8081 \
  "$image" \
  --url 'postgres://postgres:smoke@postgres:5432/postgres?sslmode=disable' >/dev/null
port=$(docker port "$web" 8081/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/" >"$tmp/index.html" &&
  grep -F '<title>pgweb</title>' "$tmp/index.html" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$web" >&2
    exit 1
  }
  sleep 1
done

if docker run --rm "$image" --url barurl >"$tmp/invalid.log" 2>&1; then
  printf '%s\n' 'invalid DSN unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'Error: Invalid URL.' "$tmp/invalid.log" >/dev/null

printf 'SMOKE PASS image=%s\n' "$image"
