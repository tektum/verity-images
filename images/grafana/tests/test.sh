#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-grafana-test-$$"
volume="verity-grafana-data-$$"
config=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$config"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 || {
  printf '%s\n' 'image user is not 65532' >&2
  exit 1
}
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = \
  '["/usr/bin/grafana","server","--homepath","/usr/share/grafana","--config","/etc/grafana/grafana.ini"]' || {
  printf '%s\n' 'unexpected image entrypoint' >&2
  exit 1
}
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d \
    -e GF_SECURITY_ADMIN_PASSWORD=verity \
    -v "$volume:/var/lib/grafana" \
    -p 127.0.0.1::3000 \
    "$image" >/dev/null
  port=$(docker port "$container" 3000/tcp | awk -F: 'NR == 1 { print $2 }')

  i=0
  until curl --fail --silent --connect-timeout 1 --max-time 2 \
    "http://127.0.0.1:$port/api/health" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      docker logs "$container" >&2
      exit 1
    }
    sleep 1
  done
}

start_server
curl --fail --silent --user admin:verity \
  -H 'Content-Type: application/json' \
  -d '{"dashboard":{"uid":"verity","title":"Verity Dashboard","schemaVersion":41,"panels":[]},"overwrite":false}' \
  "http://127.0.0.1:$port/api/dashboards/db" | grep -q '"status":"success"' || {
  printf '%s\n' 'dashboard creation failed' >&2
  exit 1
}

docker rm -f "$container" >/dev/null
start_server
curl --fail --silent --user admin:verity \
  "http://127.0.0.1:$port/api/dashboards/uid/verity" | grep -q '"title":"Verity Dashboard"' || {
  printf '%s\n' 'dashboard did not survive restart' >&2
  exit 1
}

printf '%s\n' '[server' >"$config"
chmod 644 "$config"
if docker run --rm -v "$config:/etc/grafana/grafana.ini:ro" "$image" \
  >/dev/null 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
