#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Harbor 2.15 ships PostgreSQL 15 and Valkey; the repository's PostgreSQL 15
# image and the official Valkey image are pinned by index digest.
postgres_index='ghcr.io/tektum/postgres-15-trixie@sha256:1549b52aa9f87da26ab5de23ac31dee0b4d675810dcf505e6cfe955efff14774'
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
label=verity.test=harbor-exporter-$$
network="verity-harbor-exporter-network-$$"
db="verity-harbor-exporter-postgres-$$"
cache="verity-harbor-exporter-valkey-$$"
core="verity-harbor-exporter-core-$$"
exp="verity-harbor-exporter-$$"
work=$(mktemp -d)
db_password=harbor-smoke-db

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

# OCI contract: upstream goharbor/harbor-exporter runs as harbor (10000) from
# /harbor with -c /etc/jobservice/config.yml and a /var/log/jobs volume.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 10000 ] ||
  fail 'image must run as UID 10000'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/harbor/harbor_exporter"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /harbor ] ||
  fail 'unexpected working directory'

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

docker network create --internal --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$db" --network "$network" \
  --network-alias postgresql -e POSTGRES_PASSWORD="$db_password" \
  -e POSTGRES_DB=registry "$postgres_image" >/dev/null
docker run -d --label "$label" --name "$cache" --network "$network" \
  --network-alias redis "$valkey_image" \
  valkey-server --ignore-warnings ARM64-COW-BUG >/dev/null

attempts=0
until docker exec -e PGPASSWORD="$db_password" "$db" \
  psql -h 127.0.0.1 -U postgres -d registry -tAc 'select 1' >/dev/null 2>&1; do
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

# Stand-in for core: one JSON document that answers both the health and the
# systeminfo requests the exporter makes on each scrape.
cat >"$work/core.json" <<'EOF'
{"status":"healthy","components":[{"name":"core","status":"healthy"},{"name":"jobservice","status":"unhealthy"}],
"auth_mode":"db_auth","self_registration":false}
EOF
cat >"$work/core.sh" <<'EOF'
#!/bin/sh
# One forked handler per connection: log the request line and headers, then
# answer with the canned JSON document.
cr=$(printf '\r')
read -r line
printf '%s\n' "${line%"$cr"}" >>/tmp/requests
while read -r header; do
  header=${header%"$cr"}
  [ -n "$header" ] || break
  printf '%s\n' "$header" >>/tmp/requests
done
body=$(cat /fake/core.json)
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
  "${#body}" "$body"
EOF
chmod 755 "$work/core.sh"
chmod -R a+rX "$work"
docker run -d --label "$label" --name "$core" --network "$network" --network-alias core \
  -v "$work:/fake:ro" --entrypoint nc "$valkey_image" -lk -p 8080 -e /fake/core.sh >/dev/null

# Upstream prepare environment without internal TLS; caching is disabled so
# every scrape reaches core.
cat >"$work/exporter.env" <<EOF
LOG_LEVEL=info
HARBOR_EXPORTER_PORT=8080
HARBOR_EXPORTER_METRICS_PATH=/metrics
HARBOR_EXPORTER_METRICS_ENABLED=true
HARBOR_EXPORTER_MAX_REQUESTS=30
HARBOR_EXPORTER_CACHE_TIME=0
HARBOR_EXPORTER_CACHE_CLEAN_INTERVAL=14400
HARBOR_METRIC_NAMESPACE=harbor
HARBOR_METRIC_SUBSYSTEM=exporter
HARBOR_SERVICE_HOST=core
HARBOR_SERVICE_PORT=8080
HARBOR_SERVICE_SCHEME=http
HARBOR_REDIS_URL=redis://redis:6379/2
HARBOR_REDIS_NAMESPACE=harbor_job_service_namespace
HARBOR_REDIS_TIMEOUT=3600
HARBOR_DATABASE_HOST=postgresql
HARBOR_DATABASE_PORT=5432
HARBOR_DATABASE_USERNAME=postgres
HARBOR_DATABASE_PASSWORD=$db_password
HARBOR_DATABASE_DBNAME=registry
HARBOR_DATABASE_SSLMODE=disable
EOF

docker run -d --label "$label" --name "$exp" --network "$network" --read-only \
  --env-file "$work/exporter.env" "$image" >/dev/null

attempts=0
until docker exec "$cache" wget -q -T 10 -O /tmp/metrics "http://$exp:8080/metrics" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$exp" >&2; fail 'exporter did not serve /metrics'; }
  [ "$(docker inspect -f '{{.State.Running}}' "$exp")" = true ] || {
    docker logs "$exp" >&2
    fail 'exporter exited'
  }
  sleep 1
done
docker exec "$cache" cat /tmp/metrics >"$work/metrics"

# Overall and per-component health come from the core API.
grep -Ex 'harbor_health 1' "$work/metrics" >/dev/null || {
  cat "$work/metrics" >&2
  fail 'harbor_health is not 1'
}
grep -Ex 'harbor_up\{component="core"\} 1' "$work/metrics" >/dev/null ||
  fail 'core component health is missing'
grep -Ex 'harbor_up\{component="jobservice"\} 0' "$work/metrics" >/dev/null ||
  fail 'an unhealthy component is not reported as 0'
# harbor_system_info carries the exporter's own build stamp.
grep '^harbor_system_info{' "$work/metrics" | grep -F 'auth_mode="db_auth"' |
  grep -F "harbor_version=\"v$expected_version-$short_commit\"" >/dev/null ||
  fail "harbor_system_info does not report v$expected_version-$short_commit"
grep -E '^go_goroutines ' "$work/metrics" >/dev/null ||
  fail 'exporter runtime metrics are missing'

docker exec "$core" cat /tmp/requests >"$work/requests"
grep -F 'GET /api/v2.0/health' "$work/requests" >/dev/null || fail 'exporter did not query core health'
grep -F 'GET /api/v2.0/systeminfo' "$work/requests" >/dev/null || fail 'exporter did not query core systeminfo'

docker stop -t 20 "$exp" >/dev/null

# Negative: an unreachable database fails startup.
sed -e 's/^HARBOR_DATABASE_HOST=.*/HARBOR_DATABASE_HOST=missing-db/' "$work/exporter.env" >"$work/bad.env"
if timeout 180 docker run --rm --label "$label" --network "$network" --read-only \
  --env-file "$work/bad.env" "$image" >"$work/bad.log" 2>&1; then
  fail 'exporter started without a reachable database'
fi
grep -F 'failed to initialize database' "$work/bad.log" >/dev/null || {
  cat "$work/bad.log" >&2
  fail 'unreachable database did not report a database error'
}

printf 'SMOKE PASS image=%s\n' "$image"
