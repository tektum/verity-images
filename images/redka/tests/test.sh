#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - redka=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
server="verity-redka-server-$$"
client="verity-redka-client-$$"
network="verity-redka-network-$$"
volume="verity-redka-data-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$server" "$client" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned redka version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/redka"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["-h","0.0.0.0","-p","6379","/data/redka.db"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /data ||
  fail 'unexpected working directory'

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")

# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$valkey_index"
valkey=$helper

# Raw replies: redka answers PING with a bulk string, so formatted output
# would quote it.
cli() {
  docker exec "$client" valkey-cli -h redka "$@"
}

start_server() {
  docker run -d --name "$server" --network "$network" --network-alias redka --read-only \
    -v "$volume:/data" "$image" >/dev/null
  attempts=0
  until [ "$(cli ping 2>/dev/null)" = PONG ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || { docker logs "$server" >&2; fail 'redka did not become ready'; }
    sleep 1
  done
}

docker network create --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$client" --network "$network" "$valkey" sleep 600 >/dev/null
start_server

docker logs "$server" >"$work/start.log" 2>&1
grep -F "msg=\"starting redka\" version=v$version" "$work/start.log" >/dev/null ||
  fail "startup log does not report v$version: $(cat "$work/start.log")"
grep -F 'msg="data source" driver=sqlite-redka path=/data/redka.db' "$work/start.log" >/dev/null ||
  fail "startup log does not report the SQLite data source: $(cat "$work/start.log")"

test "$(cli set verity:key hello)" = OK || fail 'SET failed'
test "$(cli get verity:key)" = hello || fail 'GET returned the wrong value'
test "$(cli incrby verity:counter 41)" = 41 || fail 'INCRBY failed'
test "$(cli incr verity:counter)" = 42 || fail 'INCR failed'
test "$(cli hset verity:hash field value)" = 1 || fail 'HSET failed'
test "$(cli hget verity:hash field)" = value || fail 'HGET failed'
test "$(cli type verity:hash)" = hash || fail 'TYPE returned the wrong type'
test "$(cli set verity:temp gone px 1)" = OK || fail 'SET with PX failed'
sleep 1
test "$(cli exists verity:temp)" = 0 || fail 'expired key still exists'
test "$(cli exists verity:missing)" = 0 || fail 'missing key reported as existing'
cli nosuchcommand >"$work/unknown" 2>&1 || true
grep -F 'ERR unknown command' "$work/unknown" >/dev/null ||
  fail "unknown command was not rejected: $(cat "$work/unknown")"

# Restart on the same volume: the data must come back from the SQLite file.
docker rm -f "$server" >/dev/null
start_server
test "$(cli get verity:key)" = hello || fail 'string did not survive a restart'
test "$(cli get verity:counter)" = 42 || fail 'counter did not survive a restart'
test "$(cli hget verity:hash field)" = value || fail 'hash did not survive a restart'
# DBSIZE also counts expired rows until the 60-second background cleanup
# deletes them, so list the live keys instead.
keys=$(cli keys 'verity:*' | sort | tr '\n' ' ')
test "$keys" = 'verity:counter verity:hash verity:key ' ||
  fail "unexpected live keys after restart: $keys"
test "$(cli exists verity:temp)" = 0 || fail 'expired key came back after a restart'

printf 'SMOKE PASS\n'
