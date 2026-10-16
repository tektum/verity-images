#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
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

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'helper image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null ||
  fail 'cannot pull helper image'

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
