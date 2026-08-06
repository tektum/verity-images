#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-prometheus-test-$$"
config=$(mktemp)
invalid_config=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid_config"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/prometheus"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]

cat > "$config" <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: [localhost:9090]
EOF
chmod 644 "$config"

docker run --name "$container" -d --read-only --user 65532 \
  --tmpfs /prometheus:uid=65532,gid=65532 \
  -v "$config:/etc/prometheus/prometheus.yml:ro" -p 127.0.0.1::9090 "$image" \
  --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus >/dev/null
port=$(docker port "$container" 9090/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || { docker logs "$container" >&2 || true; exit 1; }

i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/-/ready"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2 || true; exit 1; }
  sleep 1
done
printf '%s' "$response" | grep -q 'Prometheus Server is Ready.'
curl --fail --silent "http://127.0.0.1:$port/api/v1/status/buildinfo" | grep -q '"status":"success"'

printf 'not: [valid\n' > "$invalid_config"
chmod 644 "$invalid_config"
if docker run --rm --user 65532 -v "$invalid_config:/tmp/prometheus.yml:ro" "$image" \
  --config.file=/tmp/prometheus.yml --storage.tsdb.path=/tmp/data >/dev/null 2>&1; then
  exit 1
fi

docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]
