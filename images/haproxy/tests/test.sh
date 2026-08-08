#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-haproxy-test-$$"
checker="verity-haproxy-check-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" "$checker" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

user=$(docker image inspect --format '{{.Config.User}}' "$image")
test "$user" = 65532 || {
  printf 'unexpected image user: %s\n' "$user" >&2
  exit 1
}

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
expected_entrypoint='["/usr/bin/haproxy","-f","/etc/haproxy/haproxy.cfg"]'
test "$entrypoint" = "$expected_entrypoint" || {
  printf 'unexpected image entrypoint: %s (want %s)\n' "$entrypoint" "$expected_entrypoint" >&2
  exit 1
}

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

check_status=0
docker run --name "$checker" --entrypoint /usr/bin/haproxy \
  -v "$fixture/valid.cfg:/etc/haproxy/haproxy.cfg:ro" \
  "$image" -c -f /etc/haproxy/haproxy.cfg > "$fixture/check.log" 2>&1 || check_status=$?
cat "$fixture/check.log"
docker rm -f "$checker" >/dev/null 2>&1 || true
test "$check_status" -eq 0 || {
  printf 'config check exited %s\n' "$check_status" >&2
  exit 1
}

docker run --name "$container" -d \
  -v "$fixture/valid.cfg:/etc/haproxy/haproxy.cfg:ro" \
  -p 127.0.0.1::8080 "$image" >/dev/null
running=$(docker inspect --format '{{.State.Running}}' "$container")
test "$running" = true || { docker logs "$container" >&2 || true; exit 1; }
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
