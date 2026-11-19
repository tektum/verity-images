#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The repository's own PostgreSQL 18 image is the migration target; the pinned
# index is resolved to the child that matches the candidate's architecture.
postgres_index='ghcr.io/tektum/postgres-18-trixie@sha256:344fb505d9ffee93562e867666a4a3294cc3ada80f06e29ae2199b6cfc49b50a'
label=verity.test=flyway-$$
network="verity-flyway-network-$$"
backend="verity-flyway-postgres-$$"
work=$(mktemp -d)
db_user=flyway
db_password=flyway-test-secret
db_name=app
url="jdbc:postgresql://postgres:5432/$db_name"

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/flyway/flyway"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /flyway ||
  fail 'unexpected working directory'
uid=$(docker run --rm --network none --entrypoint /usr/bin/id "$image" -u)
[ "$uid" = 65532 ] || fail "container runs as UID '$uid', expected 65532"

# Edition and version: the Community (OSS) build must report the pinned version.
docker run --rm --network none --read-only "$image" -skipCheckForUpdate version \
  >"$work/version" 2>&1 || { cat "$work/version" >&2; fail 'flyway version failed'; }
grep -Fx "Flyway OSS Edition $expected_version by Redgate" "$work/version" >/dev/null || {
  cat "$work/version" >&2
  fail "flyway version does not report OSS Edition $expected_version"
}
if grep -Ei 'teams|enterprise|license key' "$work/version" >/dev/null; then
  cat "$work/version" >&2
  fail 'flyway version reports a Redgate edition'
fi

# Shipped jars: only the Community core, the PostgreSQL module, and its driver.
docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'cd /flyway && find . -name "*.jar" | sed -e "s/-[0-9][0-9A-Za-z.]*\.jar$//" | sort' \
  >"$work/jars"
cat >"$work/expected-jars" <<'EOF'
./drivers/postgresql
./lib/flyway/flyway-command-mcp
./lib/flyway/flyway-commandline
./lib/flyway/flyway-core
./lib/flyway/flyway-core-utilities
./lib/flyway/flyway-database-cockroachdb
./lib/flyway/flyway-database-postgresql
./lib/jackson-annotations
./lib/jackson-core
./lib/jackson-databind
./lib/jackson-dataformat-toml
./lib/jackson-dataformat-xml
./lib/jansi
./lib/stax2-api
./lib/woodstox-core
EOF
diff -u "$work/expected-jars" "$work/jars" >&2 || fail 'unexpected jar inventory'
if grep -Ei 'redgate|rgcompare|licens|proprietary' "$work/jars" >/dev/null; then
  fail 'proprietary Redgate artifact shipped'
fi

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
postgres_image=$(pull_child "$postgres_index")

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$backend" --network "$network" \
  --network-alias postgres -e POSTGRES_USER="$db_user" \
  -e POSTGRES_PASSWORD="$db_password" -e POSTGRES_DB="$db_name" \
  "$postgres_image" >/dev/null

psql_query() {
  docker exec -e PGPASSWORD="$db_password" "$backend" \
    psql -h 127.0.0.1 -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 -tA -F '|' -c "$1"
}

attempts=0
until docker exec "$backend" pg_isready -h 127.0.0.1 -U "$db_user" -d "$db_name" >/dev/null 2>&1 &&
  psql_query 'select 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$backend" >&2; fail 'postgres did not become ready'; }
  sleep 1
done

mkdir -p "$work/sql" "$work/broken"
cp "$here/fixtures/sql/"*.sql "$work/sql/"
cp "$here/fixtures/sql/"*.sql "$here/fixtures/broken/"*.sql "$work/broken/"
chmod -R a+rX "$work"

# flyway DIR ARGS...: run the candidate with DIR mounted as the default
# /flyway/sql location, on a read-only root filesystem.
flyway() {
  dir=$1
  shift
  docker run --rm --label "$label" --network "$network" --read-only \
    -v "$dir:/flyway/sql:ro" "$image" -skipCheckForUpdate "-url=$url" \
    "-user=$db_user" "-password=$db_password" "$@"
}

flyway "$work/sql" migrate >"$work/migrate" 2>&1 || { cat "$work/migrate" >&2; fail 'flyway migrate failed'; }
grep -F 'Successfully applied 2 migrations to schema "public", now at version v2' \
  "$work/migrate" >/dev/null || { cat "$work/migrate" >&2; fail 'migrate did not apply two migrations'; }

history=$(psql_query 'select version, description, script, success from flyway_schema_history order by installed_rank')
expected_history='1|create widget|V1__create_widget.sql|t
2|seed widget|V2__seed_widget.sql|t'
[ "$history" = "$expected_history" ] || {
  printf '%s\n' "$history" >&2
  fail 'flyway_schema_history does not record V1 and V2 as successful'
}
rows=$(psql_query 'select id, name from widget order by id')
[ "$rows" = '1|alpha
2|beta' ] || { printf '%s\n' "$rows" >&2; fail 'widget table does not hold the seeded rows'; }

flyway "$work/sql" info >"$work/info" 2>&1 || { cat "$work/info" >&2; fail 'flyway info failed'; }
for version in 1 2; do
  grep -E "^\| Versioned +\| $version +\|.*\| Success +\|" "$work/info" >/dev/null || {
    cat "$work/info" >&2
    fail "flyway info does not report version $version as Success"
  }
done
flyway "$work/sql" info -outputType=json >"$work/info.json" 2>"$work/info.err" ||
  { cat "$work/info.err" >&2; fail 'flyway info -outputType=json failed'; }
states=$(jq -r '[.migrations[] | "\(.version)=\(.state)"] | join(",")' "$work/info.json") ||
  fail 'flyway info JSON is not parseable'
[ "$states" = '1=Success,2=Success' ] || fail "flyway info JSON states are '$states'"

# Negative: an invalid migration must fail with a readable error and leave the
# schema at v2 (PostgreSQL DDL is transactional).
if flyway "$work/broken" migrate >"$work/broken.out" 2>&1; then
  cat "$work/broken.out" >&2
  fail 'invalid migration unexpectedly succeeded'
fi
for needle in 'V3__broken_column.sql' 'type "this_type_does_not_exist" does not exist'; do
  grep -F "$needle" "$work/broken.out" >/dev/null || {
    cat "$work/broken.out" >&2
    fail "invalid migration error does not mention: $needle"
  }
done
current=$(psql_query 'select max(version::int) from flyway_schema_history where success')
[ "$current" = 2 ] || fail "schema history moved to '$current' after a failed migration"
[ "$(psql_query "select count(*) from flyway_schema_history where version = '3'")" = 0 ] ||
  fail 'failed migration was recorded in flyway_schema_history'

# Negative: an unreachable database URL must fail with a readable error.
if docker run --rm --label "$label" --network "$network" --read-only "$image" \
  -skipCheckForUpdate -url=jdbc:postgresql://no-such-host.invalid:5432/app \
  -user=flyway -password=wrong -connectRetries=0 info >"$work/badurl" 2>&1; then
  cat "$work/badurl" >&2
  fail 'bad URL unexpectedly succeeded'
fi
grep -F 'Unable to obtain connection from database' "$work/badurl" >/dev/null || {
  cat "$work/badurl" >&2
  fail 'bad URL error is not readable'
}

printf 'flyway %s OSS: migrate, info, and negative checks passed\n' "$expected_version"
