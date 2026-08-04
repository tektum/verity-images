#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-memcached-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run --platform "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" \
  --name "$container" --user 65532:65532 -d -p 127.0.0.1::11211 "$image" >/dev/null

i=0
port=
until [ -n "$port" ] && response=$(printf 'set verity 0 60 5\r\nworks\r\nget verity\r\nquit\r\n' | \
  curl --silent --show-error --max-time 2 "telnet://127.0.0.1:$port"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  port=$(docker port "$container" 11211/tcp 2>/dev/null | awk -F: 'NR == 1 { print $2 }')
  sleep 1
done

expected='STORED
VALUE verity 0 5
works
END'
test "$(printf '%s' "$response" | tr -d '\r')" = "$expected"
