#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-minio-test-$$"
volume="verity-minio-data-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected image user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/minio"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["server","/data"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/data":{}}' ] \
  || fail 'missing data volume'

docker volume create "$volume" >/dev/null

docker run --name "$container" -d --cpus 4 --read-only --user 65532 \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$volume:/data" \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  -p 127.0.0.1::9000 "$image" >/dev/null

port=$(docker port "$container" 9000/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'minio port was not published'

attempts=0
until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/minio/health/live" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'MinIO did not become ready'
  sleep 1
done

docker rm -f "$container" >/dev/null
docker run --name "$container" -d --cpus 4 --read-only --user 65532 \
  --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$volume:/data" \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  -p 127.0.0.1::9000 "$image" >/dev/null

port=$(docker port "$container" 9000/tcp | awk -F: 'NR == 1 { print $2 }')

attempts=0
until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/minio/health/live" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'MinIO did not become ready after restart'
  sleep 1
done

printf 'SMOKE PASS image=%s\n' "$image"
