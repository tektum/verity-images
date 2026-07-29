#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-nginx-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run --name "$container" -d -p 127.0.0.1::80 "$image" >/dev/null
port=$(docker port "$container" 80/tcp | awk -F: 'NR == 1 { print $2 }')

i=0
until response=$(curl --fail --silent "http://127.0.0.1:$port/"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done

printf '%s' "$response" | grep -q '<title>Welcome to nginx!</title>'
