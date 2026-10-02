#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-minio-test-$$"
volume="verity-minio-data-$$"
user=verity-smoke
password=verity-smoke-secret
body=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$body"
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
if docker image inspect --format '{{json .Config.Env}}' "$image" | grep -F MINIO_ROOT >/dev/null; then
  fail 'image must not ship default root credentials'
fi

s3() {
  credentials=$1
  shift
  curl --silent --show-error --connect-timeout 1 --max-time 10 \
    --aws-sigv4 'aws:amz:us-east-1:s3' --user "$credentials" "$@"
}

start() {
  docker run --name "$container" -d --cpus 4 --read-only \
    --tmpfs /tmp:uid=65532,gid=65532 --tmpfs /home/nonroot:uid=65532,gid=65532 \
    -v "$volume:/data" -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD="$password" \
    -p 127.0.0.1::9000 "$image" >/dev/null
  port=$(docker port "$container" 9000/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'S3 port was not published'
  base="http://127.0.0.1:$port"
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "$base/minio/health/ready" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'server did not become ready'
    sleep 1
  done
}

docker volume create "$volume" >/dev/null
start

s3 "$user:$password" --fail -X PUT "$base/verity-smoke" >/dev/null \
  || fail 'bucket creation failed'
printf 'verity-minio-persistence' >"$body"
s3 "$user:$password" --fail -X PUT --data-binary "@$body" \
  "$base/verity-smoke/object.txt" >/dev/null || fail 'object upload failed'
[ "$(s3 "$user:$password" --fail "$base/verity-smoke/object.txt")" = verity-minio-persistence ] \
  || fail 'object read returned unexpected content'

status=$(s3 "$user:wrong-secret-value" --output /dev/null --write-out '%{http_code}' \
  "$base/verity-smoke/object.txt")
[ "$status" = 403 ] || fail "wrong credentials returned HTTP $status, expected 403"

docker rm -f "$container" >/dev/null
start
[ "$(s3 "$user:$password" --fail "$base/verity-smoke/object.txt")" = verity-minio-persistence ] \
  || fail 'object did not survive restart'
docker rm -f "$container" >/dev/null

docker run --name "$container" -d --cpus 4 --tmpfs /tmp:uid=65532,gid=65532 \
  -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD=short \
  "$image" server /tmp/invalid >/dev/null
attempts=0
while [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'short root password did not stop the server'
  sleep 1
done
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" != 0 ] \
  || fail 'short root password exited successfully'
docker logs "$container" 2>&1 | grep -F 'MINIO_ROOT_PASSWORD length at least 8 characters' >/dev/null \
  || fail 'short root password was rejected for an unexpected reason'

printf 'SMOKE PASS image=%s\n' "$image"
