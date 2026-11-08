#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
backend="verity-redis-exporter-valkey-$$"
exporter="verity-redis-exporter-exporter-$$"
orphan="verity-redis-exporter-orphan-$$"
network="verity-redis-exporter-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" "$orphan" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

wait_metrics() {
  # $1 container, $2 host port, $3 output file, $4 required line (fixed, whole line)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -Fx "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      docker logs "$1" >&2
      fail "metrics did not contain: $4"
    }
    sleep 1
  done
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/redis_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E 'Redis Metrics Exporter v1\.' >/dev/null ||
  fail 'unexpected exporter version'

created=$(docker create "$image")
docker cp "$created:/usr/bin/redis_exporter" "$tmp/redis_exporter"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$tmp/redis_exporter" | grep -q 'GOFIPS140=v1.0.0' ||
    fail 'fips flavor must be built with GOFIPS140=v1.0.0'
elif go version -m "$tmp/redis_exporter" | grep -q 'GOFIPS140='; then
  fail 'plain flavor must not set GOFIPS140'
fi

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

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias valkey "$valkey" \
  valkey-server --save "" --appendonly no --ignore-warnings ARM64-COW-BUG >/dev/null
attempts=0
until [ "$(docker exec "$backend" valkey-cli ping 2>/dev/null)" = PONG ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || { docker logs "$backend" >&2; fail 'valkey fixture did not become ready'; }
  sleep 1
done
docker exec "$backend" valkey-cli set verity:key value >/dev/null

docker run --name "$exporter" -d --network "$network" --read-only \
  -p 127.0.0.1::9121 \
  "$image" --redis.addr=redis://valkey:6379 >/dev/null
port=$(docker port "$exporter" 9121/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

wait_metrics "$exporter" "$port" "$tmp/metrics" 'redis_up 1'
grep -F 'redis_instance_info{' "$tmp/metrics" >/dev/null ||
  fail 'redis_instance_info missing'
grep -E '^redis_db_keys\{db="db0"\} 1$' "$tmp/metrics" >/dev/null ||
  fail 'redis_db_keys for the seeded key missing'

# An unreachable server must be reported as redis_up 0 while the exporter
# itself keeps serving.
docker run --name "$orphan" -d --network "$network" -p 127.0.0.1::9121 \
  "$image" --redis.addr=redis://unreachable.invalid:6379 >/dev/null
orphan_port=$(docker port "$orphan" 9121/tcp | awk -F: 'NR == 1 { print $2 }')
wait_metrics "$orphan" "$orphan_port" "$tmp/orphan.metrics" 'redis_up 0'

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'no-such-flag' "$tmp/invalid.log" >/dev/null ||
  fail 'unknown flag error missing'

docker stop "$exporter" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$exporter")" = 0 ] ||
  fail 'exporter did not stop cleanly on SIGTERM'

printf 'SMOKE PASS image=%s flavor=%s\n' "$image" "$flavor"
