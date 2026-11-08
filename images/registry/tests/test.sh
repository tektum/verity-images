#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-registry-test-$$"
volume="verity-registry-data-$$"
body=$(mktemp)
headers=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$body" "$headers"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected image user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/registry"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["serve","/etc/distribution/config.yml"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/var/lib/registry":{}}' ] \
  || fail 'missing registry data volume'

start() {
  docker run --name "$container" -d -v "$volume:/var/lib/registry" \
    -p 127.0.0.1::5000 "$image" >/dev/null
  port=$(docker port "$container" 5000/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'registry port was not published'
  base="http://127.0.0.1:$port"
  attempts=0
  until curl --silent --connect-timeout 1 --max-time 5 --dump-header "$headers" \
    --output /dev/null "$base/v2/" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'registry did not become ready'
    sleep 1
  done
}

docker volume create "$volume" >/dev/null
start

head -n 1 "$headers" | grep -Fq ' 200' || fail '/v2/ did not return HTTP 200'
grep -iq '^Docker-Distribution-Api-Version: registry/2.0' "$headers" \
  || fail 'missing Docker-Distribution-Api-Version header'

printf 'verity-registry-blob' >"$body"
digest="sha256:$(sha256sum "$body" | cut -d' ' -f1)"
location=$(curl --silent --show-error --fail --max-time 10 -X POST \
  --dump-header /dev/stdout --output /dev/null "$base/v2/verity/smoke/blobs/uploads/" |
  awk 'tolower($1) == "location:" { gsub("\r", ""); print $2 }')
[ -n "$location" ] || fail 'upload session returned no Location header'
case $location in
  http*) ;;
  *) location="$base$location" ;;
esac
curl --silent --show-error --fail --max-time 10 -X PUT -H "Content-Type: application/octet-stream" \
  --data-binary "@$body" "$location&digest=$digest" >/dev/null || fail 'blob upload failed'
[ "$(curl --silent --show-error --fail --max-time 10 "$base/v2/verity/smoke/blobs/$digest")" = verity-registry-blob ] \
  || fail 'blob read returned unexpected content'

docker rm -f "$container" >/dev/null
start
[ "$(curl --silent --show-error --fail --max-time 10 "$base/v2/verity/smoke/blobs/$digest")" = verity-registry-blob ] \
  || fail 'blob did not survive restart'

docker stop --time 30 "$container" >/dev/null
# Distribution exits with status 2 on SIGTERM; 137 would mean it ignored the signal.
case $(docker inspect --format '{{.State.ExitCode}}' "$container") in
  0|2) ;;
  *) fail 'SIGTERM did not stop the registry' ;;
esac
docker rm -f "$container" >/dev/null

printf 'version: 0.1\nstorage: [\n' >"$body"
if docker run --name "$container" -v "$body:/tmp/bad.yml:ro" "$image" serve /tmp/bad.yml >/dev/null 2>&1; then
  fail 'invalid configuration exited successfully'
fi
docker logs "$container" 2>&1 | grep -iq 'yaml\|config' \
  || fail 'invalid configuration failed without a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
