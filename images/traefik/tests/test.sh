#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-traefik-test-$$"
created=

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$created" ] || docker rm -f "$created" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/traefik"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]

created=$(docker create "$image")
docker export "$created" | tar -tf - | grep -qx 'usr/bin/traefik'
docker export "$created" | tar -tf - | grep -q '^etc/traefik/'
docker rm "$created" >/dev/null
created=

docker run --rm --user 65532 "$image" version | grep -q 'Version:.*v3.7.10'
docker run --rm --user 65532 "$image" --help >/dev/null

docker run --name "$container" -d --read-only --user 65532 \
  -p 127.0.0.1::8080 "$image" \
  --entrypoints.web.address=:8000 --ping --api.insecure >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')

i=0
until response=$(curl --fail --silent "http://127.0.0.1:$port/ping"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done
printf '%s' "$response" | grep -qx 'OK'
curl --fail --silent "http://127.0.0.1:$port/api/version" | grep -q '"Version":"v3.7.10"'
curl --fail --silent "http://127.0.0.1:$port/dashboard/" | grep -q '<title>Traefik Proxy</title>'
