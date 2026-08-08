#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-haproxy-ingress-test-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/haproxy-ingress-controller"]' ] \
  || fail 'unexpected entrypoint'

docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'test -x /usr/bin/haproxy-ingress-controller && test -x /usr/bin/haproxy && test -d /etc/haproxy && test -d /var/lib/haproxy' \
  || fail 'required HAProxy paths are missing'

docker run --rm --network none "$image" --help 2>&1 | grep -q 'Usage of HAProxy Ingress' \
  || fail 'controller --help did not print usage'

docker run --rm --network none "$image" --version 2>&1 | grep -q 'HAProxy Ingress' \
  || fail 'controller --version did not report release info'

if docker run --rm --network none "$image" --not-a-real-flag >/dev/null 2>&1; then
  fail 'invalid controller flag unexpectedly succeeded'
fi

cat > "$work/valid.cfg" <<'EOF'
global
    maxconn 256

defaults
    mode http
    timeout connect 5s
    timeout client 5s
    timeout server 5s

frontend health
    bind *:8080
    monitor-uri /healthz
EOF
chmod 644 "$work/valid.cfg"

docker run --rm --network none --entrypoint /usr/bin/haproxy \
  -v "$work/valid.cfg:/cfg/valid.cfg:ro" "$image" -c -f /cfg/valid.cfg \
  || fail 'valid HAProxy config unexpectedly failed validation'

docker run --name "$container" -d -p 127.0.0.1::8080 \
  -v "$work/valid.cfg:/cfg/valid.cfg:ro" \
  --entrypoint /usr/bin/haproxy "$image" -f /cfg/valid.cfg -db >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || { docker logs "$container" >&2 || true; fail 'HAProxy did not publish its health port'; }

i=0
until curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || { docker logs "$container" >&2; fail 'HAProxy health endpoint never became ready'; }
  sleep 1
done
[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] \
  || { docker logs "$container" >&2; fail 'HAProxy container exited unexpectedly'; }
docker rm -f "$container" >/dev/null

cat > "$work/bad.cfg" <<'EOF'
global
    maxconn 256

defaults
    mode http

frontend health
    bind *:8080
    this-is-not-a-real-directive
EOF
chmod 644 "$work/bad.cfg"

if docker run --rm --network none --entrypoint /usr/bin/haproxy \
  -v "$work/bad.cfg:/cfg/bad.cfg:ro" "$image" -c -f /cfg/bad.cfg >/dev/null 2>&1; then
  fail 'invalid HAProxy config unexpectedly passed validation'
fi

printf 'SMOKE PASS image=%s\n' "$image"
