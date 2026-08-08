#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-haproxy-test-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/haproxy","-f","/etc/haproxy/haproxy.cfg"]'

cat > "$fixture/valid.cfg" <<'EOF'
global
    maxconn 100

defaults
    mode http
    timeout connect 5s
    timeout client 5s
    timeout server 5s

frontend health
    bind *:8080
    monitor-uri /healthz
EOF
chmod 644 "$fixture/valid.cfg"

docker run --rm --entrypoint /usr/bin/haproxy \
  -v "$fixture/valid.cfg:/etc/haproxy/haproxy.cfg:ro" \
  "$image" -c -f /etc/haproxy/haproxy.cfg |
  grep -F 'Configuration file is valid'

docker run --name "$container" -d \
  -v "$fixture/valid.cfg:/etc/haproxy/haproxy.cfg:ro" \
  -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" || { docker logs "$container" >&2 || true; exit 1; }

i=0
until status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/healthz") &&
  [ "$status" = 200 ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$container" >&2; exit 1; }
  sleep 1
done

cat > "$fixture/invalid.cfg" <<'EOF'
frontend health
    bind *:8080
    monitor-uri
EOF
chmod 644 "$fixture/invalid.cfg"

if docker run --rm -v "$fixture/invalid.cfg:/etc/haproxy/haproxy.cfg:ro" "$image" >/dev/null 2>&1; then
  printf 'invalid config unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
