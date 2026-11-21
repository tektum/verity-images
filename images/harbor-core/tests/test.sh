#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Harbor 2.15 ships PostgreSQL 15 and Valkey; the repository's PostgreSQL 15
# image and the official Valkey image are pinned by index digest.
postgres_index='ghcr.io/tektum/postgres-15-trixie@sha256:1549b52aa9f87da26ab5de23ac31dee0b4d675810dcf505e6cfe955efff14774'
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
label=verity.test=harbor-core-$$
network="verity-harbor-core-network-$$"
db="verity-harbor-core-postgres-$$"
cache="verity-harbor-core-valkey-$$"
core="verity-harbor-core-$$"
work=$(mktemp -d)
db_password=harbor-smoke-db
admin_password=Harbor-Smoke-12345

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
source_commit=$(awk '$1 == "source-commit:" { print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'
[ "${#source_commit}" -eq 40 ] || fail 'could not read the recipe source commit'
short_commit=$(printf '%s' "$source_commit" | cut -c1-8)

# OCI contract: upstream goharbor/harbor-core runs as harbor (10000) from /harbor.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 10000 ] ||
  fail 'image must run as UID 10000'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/harbor/harbor_core"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /harbor ] ||
  fail 'unexpected working directory'

# The migrations shipped in the image define the schema version core must reach.
docker create --label "$label" --name "$core-files" "$image" >/dev/null
docker cp "$core-files:/harbor/migrations" "$work/migrations" >/dev/null ||
  fail 'image has no /harbor/migrations'
docker cp "$core-files:/harbor/views/404.tpl" "$work/404.tpl" >/dev/null ||
  fail 'image has no /harbor/views'
docker cp "$core-files:/harbor/icons/image.png" "$work/image.png" >/dev/null ||
  fail 'image has no /harbor/icons'
docker rm "$core-files" >/dev/null
expected_schema=$(find "$work/migrations/postgresql" -name '*.up.sql' -exec basename {} \; |
  sed -n 's/^0*\([0-9][0-9]*\)_.*/\1/p' | sort -n | tail -1)
[ -n "$expected_schema" ] || fail 'no PostgreSQL migrations in the image'

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
case $image_arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $image_arch" ;; esac
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
  repository=${1%%@*}
  repository=${repository%:*}
  docker pull --quiet --platform "linux/$image_arch" "$repository@$child" >/dev/null ||
    fail "cannot pull $repository@$child"
  printf '%s' "$repository@$child"
}
postgres_image=$(pull_child "$postgres_index")
valkey_image=$(pull_child "$valkey_index")

# Internal network: core reaches only its database and cache, never the internet.
docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$db" --network "$network" \
  --network-alias postgresql -e POSTGRES_PASSWORD="$db_password" \
  -e POSTGRES_DB=registry "$postgres_image" >/dev/null
docker run -d --label "$label" --name "$cache" --network "$network" \
  --network-alias redis "$valkey_image" \
  valkey-server --ignore-warnings ARM64-COW-BUG >/dev/null

psql_query() {
  docker exec -e PGPASSWORD="$db_password" "$db" \
    psql -h 127.0.0.1 -U postgres -d registry -v ON_ERROR_STOP=1 -tA -c "$1"
}
attempts=0
until psql_query 'select 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$db" >&2; fail 'postgres did not become ready'; }
  sleep 1
done
attempts=0
until [ "$(docker exec "$cache" valkey-cli ping 2>/dev/null)" = PONG ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$cache" >&2; fail 'valkey did not become ready'; }
  sleep 1
done

# Upstream prepare output: app.conf, the 16 byte secret key, and the token
# service signing key, mounted read-only under /etc/core.
mkdir -p "$work/core"
printf 'appname = Harbor\nrunmode = prod\nenablegzip = true\n\n[prod]\nhttpport = 8080\n' \
  >"$work/core/app.conf"
printf '%s' 0123456789abcdef >"$work/core/key"
openssl genrsa -out "$work/core/private_key.pem" 2048 2>/dev/null ||
  fail 'cannot generate the token signing key'
chmod -R a+rX "$work/core"

cat >"$work/core.env" <<EOF
CONFIG_PATH=/etc/core/app.conf
LOG_LEVEL=info
EXT_ENDPOINT=http://harbor.invalid
DATABASE_TYPE=postgresql
POSTGRESQL_HOST=postgresql
POSTGRESQL_PORT=5432
POSTGRESQL_USERNAME=postgres
POSTGRESQL_PASSWORD=$db_password
POSTGRESQL_DATABASE=registry
POSTGRESQL_SSLMODE=disable
_REDIS_URL_CORE=redis://redis:6379?idle_timeout_seconds=30
_REDIS_URL_HARBOR=redis://redis:6379/2?idle_timeout_seconds=30
REGISTRY_URL=http://registry.invalid:5000
PORTAL_URL=http://portal.invalid:8080
TOKEN_SERVICE_URL=http://core:8080/service/token
HARBOR_ADMIN_PASSWORD=$admin_password
CORE_SECRET=core-smoke-secret-16
JOBSERVICE_SECRET=job-smoke-secret-16
WITH_TRIVY=false
CORE_URL=http://core:8080
CORE_LOCAL_URL=http://127.0.0.1:8080
JOBSERVICE_URL=http://jobservice.invalid:8080
REGISTRY_CONTROLLER_URL=http://registryctl.invalid:8080
REGISTRY_STORAGE_PROVIDER_NAME=filesystem
READ_ONLY=false
CSRF_KEY=0123456789abcdef0123456789abcdef
PORT=8080
EOF

core_run() {
  docker run --label "$label" --network "$network" --read-only \
    --env-file "$work/core.env" -v "$work/core:/etc/core:ro" "$@"
}

# Helm pre-install/pre-upgrade hook: `-mode migrate` migrates and exits 0.
core_run --rm "$image" -mode migrate >"$work/migrate.log" 2>&1 || {
  cat "$work/migrate.log" >&2
  fail 'migrate mode failed'
}
grep -F 'the database migrate success' "$work/migrate.log" >/dev/null || {
  cat "$work/migrate.log" >&2
  fail 'migrate mode did not report success'
}
schema=$(psql_query 'select version || $$|$$ || dirty from schema_migrations') ||
  fail 'schema_migrations is missing after migrate'
[ "$schema" = "$expected_schema|false" ] ||
  fail "schema_migrations is '$schema', expected '$expected_schema|false'"

core_run -d --name "$core" --network-alias core "$image" >/dev/null

# Probes run from the Valkey container, the only client on the internal network.
http_get() {
  docker exec "$cache" wget -q -T 5 -O - "$@"
}
attempts=0
until [ "$(http_get http://core:8080/api/v2.0/ping 2>/dev/null)" = Pong ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || { docker logs "$core" >&2; fail 'core did not answer /api/v2.0/ping'; }
  [ "$(docker inspect -f '{{.State.Running}}' "$core")" = true ] || {
    docker logs "$core" >&2
    fail 'core exited'
  }
  sleep 1
done

admin_auth="Authorization: Basic $(printf 'admin:%s' "$admin_password" | base64)"
http_get --header "$admin_auth" http://core:8080/api/v2.0/systeminfo >"$work/systeminfo.json" ||
  fail 'systeminfo request failed'
[ "$(jq -r .harbor_version "$work/systeminfo.json")" = "v$expected_version-$short_commit" ] || {
  cat "$work/systeminfo.json" >&2
  fail "systeminfo does not report v$expected_version-$short_commit"
}
[ "$(jq -r .auth_mode "$work/systeminfo.json")" = db_auth ] ||
  fail 'systeminfo does not report db_auth'

# HARBOR_ADMIN_PASSWORD seeded the admin account in PostgreSQL.
http_get --header "$admin_auth" http://core:8080/api/v2.0/users/current >"$work/current.json" || {
  docker logs "$core" >&2
  fail 'admin basic auth was rejected'
}
[ "$(jq -r '.username + "|" + (.sysadmin_flag | tostring)' "$work/current.json")" = 'admin|true' ] || {
  cat "$work/current.json" >&2
  fail 'users/current did not return the system admin'
}
if http_get --header "Authorization: Basic $(printf 'admin:wrong' | base64)" \
  http://core:8080/api/v2.0/users/current >/dev/null 2>&1; then
  fail 'a wrong admin password was accepted'
fi

# Project API round trip writes through core into PostgreSQL.
docker exec "$cache" wget -q -T 5 -O - \
  --header "$admin_auth" --header 'Content-Type: application/json' \
  --post-data '{"project_name":"smoke","metadata":{"public":"false"}}' \
  http://core:8080/api/v2.0/projects >/dev/null || {
  docker logs "$core" >&2
  fail 'project creation failed'
}
[ "$(psql_query "select count(*) from project where name = 'smoke' and deleted = false")" = 1 ] ||
  fail 'created project is not in PostgreSQL'

# Core keeps its session and cache state in Valkey.
[ "$(docker exec "$cache" valkey-cli -n 0 dbsize)" -gt 0 ] ||
  fail 'core wrote nothing to its Valkey database'

# Graceful stop on SIGTERM.
docker stop -t 20 "$core" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$core")" = 0 ] || {
  docker logs "$core" >&2
  fail 'core did not exit 0 on SIGTERM'
}

# Negative: an unreachable database fails startup with a clear error.
sed -e 's/^POSTGRESQL_HOST=.*/POSTGRESQL_HOST=missing-db/' "$work/core.env" >"$work/bad.env"
if timeout 120 docker run --rm --label "$label" --network "$network" --read-only \
  --env-file "$work/bad.env" -v "$work/core:/etc/core:ro" "$image" -mode migrate \
  >"$work/bad.log" 2>&1; then
  fail 'core started without a reachable database'
fi
grep -F 'failed to initialize database' "$work/bad.log" >/dev/null || {
  cat "$work/bad.log" >&2
  fail 'unreachable database did not report a database error'
}

printf 'SMOKE PASS image=%s\n' "$image"
