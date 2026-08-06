#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-nats-test-$$"
config=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$config"
}
trap cleanup EXIT INT TERM

docker run --name "$container" -d \
  -p 127.0.0.1::4222 -p 127.0.0.1::8222 \
  "$image" --jetstream --store_dir /data/nats --http_port 8222 >/dev/null
nats_port=$(docker port "$container" 4222/tcp | awk -F: 'NR == 1 { print $2 }')
http_port=$(docker port "$container" 8222/tcp | awk -F: 'NR == 1 { print $2 }')

i=0
until curl --fail --silent "http://127.0.0.1:$http_port/healthz" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done

subject="verity.$$"
response=$(printf 'CONNECT {"verbose":false}\r\nSUB %s 1\r\nPUB %s 5\r\nworks\r\nPING\r\n' "$subject" "$subject" |
  curl --silent --max-time 2 "telnet://127.0.0.1:$nats_port" || true)
printf '%s' "$response" | grep -q "MSG $subject 1 5"
printf '%s' "$response" | grep -q works
curl --fail --silent "http://127.0.0.1:$http_port/varz" | grep -q '"server_id"'

printf '%s\n' 'this is not valid {' >"$config"
chmod 644 "$config"
if docker run --rm -v "$config:/etc/nats/invalid.conf:ro" "$image" \
  --config /etc/nats/invalid.conf >/dev/null 2>&1; then
  printf '%s\n' 'invalid config unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
