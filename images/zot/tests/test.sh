#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-zot-test-$$"
volume="verity-zot-data-$$"
config=$(mktemp)
invalid_config=$(mktemp)
headers=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid_config" "$headers"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected image user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/zot"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["serve","/etc/zot/config.json"]' ] \
  || fail 'unexpected image command'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/var/lib/registry":{}}' ] \
  || fail 'missing registry data volume'

cat >"$config" <<'EOF'
{
  "distSpecVersion": "1.1.1",
  "storage": {"rootDirectory": "/var/lib/registry"},
  "http": {"address": "0.0.0.0", "port": "5000"}
}
EOF
chmod 644 "$config"

start() {
  docker run --name "$container" -d --cpus 4 --read-only --user 65532 \
    --tmpfs /tmp:uid=65532,gid=65532 \
    -v "$volume:/var/lib/registry" -v "$config:/tmp/config.json:ro" \
    -p 127.0.0.1::5000 "$image" serve /tmp/config.json >/dev/null
  port=$(docker port "$container" 5000/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$port" ] || fail 'registry port was not published'

  attempts=0
  until response=$(curl --fail --include --silent --show-error --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port/v2/"); do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || fail 'Zot did not become ready'
    sleep 1
  done
  printf '%s\n' "$response" | grep -Fi 'Docker-Distribution-API-Version: registry/2.0' >/dev/null \
    || fail 'registry API response is missing the distribution header'
}

docker volume create "$volume" >/dev/null
start

blob=verity-zot-persistence
digest=$(printf '%s' "$blob" | sha256sum | cut -d' ' -f1)
curl --fail --silent --show-error --dump-header "$headers" --output /dev/null \
  -X POST "http://127.0.0.1:$port/v2/verity/smoke/blobs/uploads/"
location=$(awk 'tolower($1) == "location:" { print $2 }' "$headers" | tr -d '\r')
[ -n "$location" ] || fail 'blob upload did not return a location'
case "$location" in
  http://*|https://*) upload=$location ;;
  *) upload="http://127.0.0.1:$port$location" ;;
esac
case "$upload" in
  *\?*) upload="$upload&digest=sha256:$digest" ;;
  *) upload="$upload?digest=sha256:$digest" ;;
esac
printf '%s' "$blob" | curl --fail --silent --show-error --output /dev/null \
  -X PUT -H 'Content-Type: application/octet-stream' --data-binary @- "$upload"
[ "$(curl --fail --silent --show-error \
  "http://127.0.0.1:$port/v2/verity/smoke/blobs/sha256:$digest")" = "$blob" ] \
  || fail 'registry blob read failed'

docker rm -f "$container" >/dev/null
start
[ "$(curl --fail --silent --show-error \
  "http://127.0.0.1:$port/v2/verity/smoke/blobs/sha256:$digest")" = "$blob" ] \
  || fail 'registry blob did not survive restart'

printf '%s\n' '{' >"$invalid_config"
chmod 644 "$invalid_config"
if docker run --rm --cpus 4 -v "$invalid_config:/tmp/invalid.json:ro" \
  "$image" serve /tmp/invalid.json >/dev/null 2>&1; then
  fail 'invalid configuration unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
