#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
# Harbor 2.15 ships PostgreSQL 15 and Valkey; the repository's PostgreSQL 15
# image and the official Valkey image are pinned by index digest.
postgres_index='ghcr.io/tektum/postgres-15-trixie@sha256:1549b52aa9f87da26ab5de23ac31dee0b4d675810dcf505e6cfe955efff14774'
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
label=verity.test=harbor-jobservice-$$
network="verity-harbor-jobservice-network-$$"
db="verity-harbor-jobservice-postgres-$$"
cache="verity-harbor-jobservice-valkey-$$"
core="verity-harbor-jobservice-core-$$"
js="verity-harbor-jobservice-$$"
work=$(mktemp -d)
db_password=harbor-smoke-db
secret=jobservice-smoke-secret

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

# OCI contract: upstream goharbor/harbor-jobservice runs as harbor (10000) from
# /harbor with -c /etc/jobservice/config.yml and a /var/log/jobs volume.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 10000 ] ||
  fail 'image must run as UID 10000'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/harbor/harbor_jobservice","-c","/etc/jobservice/config.yml"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /harbor ] ||
  fail 'unexpected working directory'
[ "$(docker image inspect -f '{{json .Config.Volumes}}' "$image")" = '{"/var/log/jobs":{}}' ] ||
  fail 'unexpected volumes'

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

# Stand-in for core's internal configuration API, which the job service reads
# at startup with its secret. It answers with the database settings and logs
# every request so the secret header can be asserted.
cat >"$work/config.json" <<EOF
{"database_type":{"value":"postgresql","editable":false},
"postgresql_host":{"value":"postgresql","editable":false},
"postgresql_port":{"value":5432,"editable":false},
"postgresql_username":{"value":"postgres","editable":false},
"postgresql_password":{"value":"$db_password","editable":false},
"postgresql_database":{"value":"registry","editable":false},
"postgresql_sslmode":{"value":"disable","editable":false}}
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
body=$(cat /fake/config.json)
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
  "${#body}" "$body"
EOF
chmod 755 "$work/core.sh"
chmod -R a+rX "$work"
docker run -d --label "$label" --name "$core" --network "$network" --network-alias core \
  -v "$work:/fake:ro" --entrypoint nc "$valkey_image" -lk -p 8080 -e /fake/core.sh >/dev/null

# Upstream prepare output without internal TLS.
mkdir -p "$work/jobservice"
cat >"$work/jobservice/config.yml" <<'EOF'
---
protocol: "http"
port: 8080
worker_pool:
  workers: 2
  backend: "redis"
  redis_pool:
    redis_url: redis://redis:6379/2?idle_timeout_seconds=30
    namespace: "harbor_job_service_namespace"
    idle_timeout_second: 3600
job_loggers:
  - name: "STD_OUTPUT"
    level: "INFO"
  - name: "FILE"
    level: "INFO"
    settings:
      base_dir: "/var/log/jobs"
    sweeper:
      duration: 1
      settings:
        work_dir: "/var/log/jobs"
loggers:
  - name: "STD_OUTPUT"
    level: "INFO"
metric:
  enabled: true
  path: /metrics
  port: 8001
reaper:
  max_update_hours: 24
  max_dangling_hours: 168
max_retrieve_size_mb: 10
EOF
chmod -R a+rX "$work/jobservice"

docker run -d --label "$label" --name "$js" --network "$network" --read-only \
  -e CORE_URL=http://core:8080 -e CORE_SECRET="$secret" -e JOBSERVICE_SECRET="$secret" \
  -e REGISTRY_URL=http://registry.invalid:5000 \
  -e REGISTRY_CONTROLLER_URL=http://registryctl.invalid:8080 -e LOG_LEVEL=info \
  -e METRIC_NAMESPACE=harbor -e METRIC_SUBSYSTEM=jobservice \
  -v "$work/jobservice:/etc/jobservice:ro" "$image" >/dev/null

http_get() {
  docker exec "$cache" wget -q -T 5 -O - "$@"
}
auth="Authorization: Harbor-Secret $secret"
attempts=0
until http_get --header "$auth" http://"$js":8080/api/v1/stats >"$work/stats.json" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || { docker logs "$js" >&2; fail 'jobservice did not answer /api/v1/stats'; }
  [ "$(docker inspect -f '{{.State.Running}}' "$js")" = true ] || {
    docker logs "$js" >&2
    fail 'jobservice exited'
  }
  sleep 1
done

# The worker pool registered itself in Valkey with the configured concurrency.
[ "$(jq -r '[.worker_pools[] | select(.status == "Healthy" and .concurrency == 2)] | length' "$work/stats.json")" -ge 1 ] || {
  cat "$work/stats.json" >&2
  fail 'stats do not report a healthy worker pool with concurrency 2'
}
docker exec "$cache" valkey-cli -n 2 --scan --pattern '{harbor_job_service_namespace}:*' \
  >"$work/keys" || fail 'cannot list Valkey keys'
grep -F 'worker_pools' "$work/keys" >/dev/null || {
  cat "$work/keys" >&2
  fail 'worker pool is not registered in Valkey'
}

# Startup configuration came from core with the job service secret.
docker exec "$core" cat /tmp/requests >"$work/requests"
grep -F 'GET /api/v2.0/internalconfig' "$work/requests" >/dev/null ||
  fail 'jobservice did not read core internal configuration'
grep -iF "Authorization: Harbor-Secret $secret" "$work/requests" >/dev/null ||
  fail 'jobservice did not authenticate to core with its secret'

# Negative: job submission rejects a wrong secret (stats is the unauthenticated
# upstream health check).
if docker exec "$cache" wget -q -T 5 -O - --header 'Authorization: Harbor-Secret wrong' \
  --header 'Content-Type: application/json' \
  --post-data '{"job":{"name":"DEMO","metadata":{"kind":"Generic"}}}' \
  http://"$js":8080/api/v1/jobs >/dev/null 2>&1; then
  fail 'job submission accepted a wrong secret'
fi

# Negative: an unknown job kind is rejected.
if docker exec "$cache" wget -q -T 5 -O - --header "$auth" --header 'Content-Type: application/json' \
  --post-data '{"job":{"name":"NO_SUCH_JOB","metadata":{"kind":"Generic"}}}' \
  http://"$js":8080/api/v1/jobs >"$work/bad-job.out" 2>&1; then
  fail 'an unknown job kind was accepted'
fi

http_get "http://$js:8001/metrics" >"$work/metrics" || fail 'metrics endpoint failed'
grep -E '^harbor_jobservice_' "$work/metrics" >/dev/null ||
  fail 'metrics do not expose harbor_jobservice series'

docker stop -t 20 "$js" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$js")" = 0 ] || {
  docker logs "$js" >&2
  fail 'jobservice did not exit 0 on SIGTERM'
}

printf 'SMOKE PASS image=%s\n' "$image"
