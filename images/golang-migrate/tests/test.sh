#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$(dirname "$0")/../melange.yaml")
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-golang-migrate-postgres-$$"
network="verity-golang-migrate-network-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/migrate"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["--help"]' ||
  fail 'unexpected command'

docker run --rm --network none "$image" -version >"$work/version" 2>&1 ||
  fail 'version failed'
test "$(cat "$work/version")" = "$version" ||
  fail "version is $(cat "$work/version"), expected $version"
docker run --rm --network none --entrypoint /migrate "$image" -version >"$work/compat" 2>&1 ||
  fail '/migrate compatibility path failed'
test "$(cat "$work/compat")" = "$version" || fail '/migrate reports another version'

# Default command prints usage with the upstream release driver set.
docker run --rm --network none "$image" >"$work/help" 2>&1 || fail 'default help failed'
for driver in postgres pgx5 mysql sqlserver mongodb clickhouse spanner cassandra; do
  grep -F 'Database drivers:' "$work/help" | grep -Fw "$driver" >/dev/null ||
    fail "database driver $driver is not compiled in"
done
for source in file github s3 gcs gitlab; do
  grep -F 'Source drivers:' "$work/help" | grep -Fw "$source" >/dev/null ||
    fail "source driver $source is not compiled in"
done

rc=0
docker run --rm --network none "$image" -definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/flag" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# create writes a sequential up/down pair into a mounted directory. Run as the
# invoking user so the test can clean up the files it writes.
mkdir -p "$work/created"
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$work/created:/work" "$image" \
  create -ext sql -dir /work -seq add_users >/dev/null 2>&1 || fail 'create failed'
for file in 000001_add_users.up.sql 000001_add_users.down.sql; do
  test -f "$work/created/$file" || fail "create did not write $file"
done

# Fixture migrations against PostgreSQL.
mkdir -p "$work/migrations"
cat >"$work/migrations/000001_create_users.up.sql" <<'SQL'
CREATE TABLE users (id serial PRIMARY KEY, email text NOT NULL UNIQUE);
SQL
cat >"$work/migrations/000001_create_users.down.sql" <<'SQL'
DROP TABLE users;
SQL
cat >"$work/migrations/000002_add_name.up.sql" <<'SQL'
ALTER TABLE users ADD COLUMN name text;
INSERT INTO users (email, name) VALUES ('smoke@example.invalid', 'smoke');
SQL
cat >"$work/migrations/000002_add_name.down.sql" <<'SQL'
DELETE FROM users WHERE email = 'smoke@example.invalid';
ALTER TABLE users DROP COLUMN name;
SQL
mkdir -p "$work/broken"
cp "$work/migrations/"* "$work/broken/"
cat >"$work/broken/000003_broken.up.sql" <<'SQL'
ALTER TABLE no_such_table ADD COLUMN broken text;
SQL
cat >"$work/broken/000003_broken.down.sql" <<'SQL'
SELECT 1;
SQL
chmod -R a+rX "$work"

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
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
  -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=app "$postgres" >/dev/null
attempts=0
until docker exec "$backend" pg_isready -U postgres -d app -h 127.0.0.1 >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    fail 'postgres did not become ready'
  }
  sleep 1
done

url='postgres://postgres:smoke@postgres:5432/app?sslmode=disable'
migrate() {
  dir=$1
  shift
  docker run --rm --network "$network" --read-only --cap-drop=ALL \
    -v "$work/$dir:/migrations:ro" "$image" -path /migrations -database "$url" "$@"
}
psql() {
  docker exec "$backend" psql -U postgres -d app -At -c "$1"
}

migrate migrations up >"$work/up" 2>&1 || fail "up failed: $(cat "$work/up")"
grep -F '2/u add_name' "$work/up" >/dev/null || fail 'up did not apply migration 2'
migrate migrations version >"$work/v2" 2>&1 || fail 'version after up failed'
test "$(cat "$work/v2")" = 2 || fail "schema version is $(cat "$work/v2"), expected 2"
test "$(psql 'SELECT version, dirty FROM schema_migrations')" = '2|f' ||
  fail 'schema_migrations does not record clean version 2'
test "$(psql "SELECT name FROM users WHERE email = 'smoke@example.invalid'")" = smoke ||
  fail 'migration 2 data is missing'

migrate migrations up >"$work/noop" 2>&1 || fail 'repeated up failed'
grep -F 'no change' "$work/noop" >/dev/null || fail 'repeated up did not report no change'

migrate migrations down 1 >"$work/down" 2>&1 || fail "down failed: $(cat "$work/down")"
test "$(psql 'SELECT version, dirty FROM schema_migrations')" = '1|f' ||
  fail 'down 1 did not return to version 1'
test "$(psql "SELECT count(*) FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'name'")" = 0 ||
  fail 'down 1 did not drop the name column'

# A failing migration exits non-zero, names the error and leaves the version dirty.
rc=0
migrate broken up >"$work/broken.out" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'failing migration unexpectedly succeeded'
grep -F 'no_such_table' "$work/broken.out" >/dev/null ||
  fail "failing migration diagnostic is missing: $(cat "$work/broken.out")"
test "$(psql 'SELECT version, dirty FROM schema_migrations')" = '3|t' ||
  fail 'failed migration did not leave version 3 dirty'
migrate broken force 2 >/dev/null 2>&1 || fail 'force failed'
test "$(psql 'SELECT version, dirty FROM schema_migrations')" = '2|f' ||
  fail 'force did not reset to clean version 2'

# The pgx5 driver reads the same schema_migrations state.
url='pgx5://postgres:smoke@postgres:5432/app?sslmode=disable'
migrate migrations version >"$work/pgx5" 2>&1 || fail "pgx5 version failed: $(cat "$work/pgx5")"
test "$(cat "$work/pgx5")" = 2 || fail "pgx5 reports version $(cat "$work/pgx5"), expected 2"
migrate migrations down -all >"$work/pgx5.down" 2>&1 || fail "pgx5 down -all failed: $(cat "$work/pgx5.down")"
test "$(psql "SELECT count(*) FROM information_schema.tables WHERE table_name = 'users'")" = 0 ||
  fail 'pgx5 down -all did not drop the users table'

# The pgx v4 driver is deliberately not compiled in (see melange.yaml).
for driver in pgx pgx4; do
  grep -F 'Database drivers:' "$work/help" | grep -Fw "$driver" >/dev/null &&
    fail "database driver $driver is compiled in"
done

rc=0
docker run --rm --network none "$image" -path /tmp -database 'nosuchdb://x' up >"$work/driver" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unknown database driver unexpectedly succeeded'
grep -F 'unknown driver nosuchdb' "$work/driver" >/dev/null ||
  fail "unknown driver diagnostic is missing: $(cat "$work/driver")"

printf 'SMOKE PASS image=%s\n' "$image"
