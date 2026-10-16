#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-pgcat-postgres-$$"
pooler="verity-pgcat-pooler-$$"
network="verity-pgcat-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$pooler" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || {
  printf '%s\n' 'image user is not 65532' >&2
  exit 1
}
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/pgcat"]' || {
  printf '%s\n' 'unexpected image entrypoint' >&2
  exit 1
}
docker run --rm --entrypoint /usr/bin/pgcat "$image" --version | grep -q '^pgcat 1\.' || {
  printf '%s\n' 'unexpected PgCat version' >&2
  exit 1
}

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect postgres image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'postgres image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve postgres image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch postgres image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null ||
  fail 'cannot pull postgres image'

cat >"$tmp/pgcat.toml" <<'EOF'
[general]
host = "0.0.0.0"
port = 6432
admin_username = "admin"
admin_password = "admin-password"

[pools.postgres]
pool_mode = "transaction"
default_role = "primary"
query_parser_enabled = false

[pools.postgres.users.0]
username = "smoke"
password = "smoke-password"
server_username = "smoke"
server_password = "smoke-password"
pool_size = 2

[pools.postgres.shards.0]
servers = [["postgres", 5432, "primary"]]
database = "postgres"
EOF
chmod 644 "$tmp/pgcat.toml"

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke \
  -e POSTGRES_PASSWORD=smoke-password \
  -e POSTGRES_DB=postgres \
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

docker run --name "$pooler" -d --network "$network" --network-alias pgcat \
  -v "$tmp/pgcat.toml:/etc/pgcat/pgcat.toml:ro" \
  "$image" /etc/pgcat/pgcat.toml >/dev/null

attempts=0
until docker exec "$backend" pg_isready -h pgcat -p 6432 -U smoke -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$pooler" >&2
    exit 1
  }
  sleep 1
done

result=$(docker exec -e PGPASSWORD=smoke-password "$backend" \
  psql -h pgcat -p 6432 -U smoke -d postgres -Atqc \
  "SELECT current_user || ':' || current_database() || ':' || 6 * 7")
test "$result" = 'smoke:postgres:42' || {
  printf 'unexpected pooled query result: %s\n' "$result" >&2
  exit 1
}

printf '%s\n' '[general' >"$tmp/invalid.toml"
chmod 644 "$tmp/invalid.toml"
if docker run --rm -v "$tmp/invalid.toml:/etc/pgcat/invalid.toml:ro" \
  "$image" /etc/pgcat/invalid.toml >/dev/null 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
