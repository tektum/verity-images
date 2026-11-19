#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# The catalog memcached image is the scrape target; the pinned index is resolved per platform.
memcached_index='ghcr.io/tektum/memcached@sha256:4043d1cedb310e3f455413ba8c16995be62af3cf7ecf8f8c81211bd4f47fe329'
label=verity.test=memcached-exporter-$$
network="verity-memcached-exporter-network-$$"
backend="verity-memcached-exporter-backend-$$"
exporter="verity-memcached-exporter-exporter-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$exporter" >&2 2>/dev/null || true
  docker logs "$backend" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/memcached_exporter"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'

docker run --rm --network none --read-only "$image" --version >"$work/version" 2>&1 ||
  fail 'version command failed'
grep -E "^memcached_exporter, version $expected_version " "$work/version" >/dev/null ||
  fail "unexpected version output: $(head -n 1 "$work/version")"

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown long flag' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# pull_child INDEX: pull the pinned index by its per-platform child digest,
# verifying the index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
pull_child() {
  raw=$(docker buildx imagetools inspect --raw "$1") || fail "cannot inspect $1"
  [ "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)" = "${1#*@}" ] ||
    fail "index digest mismatch for $1"
  child=$(printf '%s' "$raw" | jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail "cannot resolve a child of $1"
  case $child in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch child in $1" ;;
  esac
  docker pull --quiet --platform "linux/$image_arch" "${1%%@*}@$child" >/dev/null ||
    fail "cannot pull ${1%%@*}@$child"
  printf '%s' "${1%%@*}@$child"
}
memcached_image=$(pull_child "$memcached_index")

docker network create --label "$label" "$network" >/dev/null
docker run -d --label "$label" --name "$backend" --network "$network" \
  --network-alias memcached "$memcached_image" >/dev/null
docker run -d --label "$label" --name "$exporter" --network "$network" --read-only \
  -p 127.0.0.1::9150 "$image" --memcached.address=memcached:11211 >/dev/null
port=$(docker port "$exporter" 9150/tcp | head -n 1 | sed 's/.*://')
[ -n "$port" ] || fail 'exporter port is not published'

# scrape PATH OUT: fetch PATH from the exporter until it answers.
scrape() {
  scrape_attempts=0
  until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port$1" >"$2" 2>"$work/curl.err"; do
    scrape_attempts=$((scrape_attempts + 1))
    [ "$scrape_attempts" -lt 30 ] || fail "exporter did not serve $1: $(cat "$work/curl.err")"
    sleep 1
  done
}

attempts=0
until scrape /metrics "$work/metrics" && grep -Fx 'memcached_up 1' "$work/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'memcached_up never reached 1'
  sleep 1
done
grep -E '^memcached_version\{version="1\.6\.[0-9]+"\} 1$' "$work/metrics" >/dev/null ||
  fail 'memcached_version gauge is missing'
grep -E '^memcached_current_connections [1-9][0-9]*$' "$work/metrics" >/dev/null ||
  fail 'memcached_current_connections is missing'
grep -E "^memcached_exporter_build_info\{.*version=\"$expected_version\"" "$work/metrics" >/dev/null ||
  fail 'build info does not report the recipe version'

# Multi-target scrape endpoint reaches the same backend.
scrape '/scrape?target=memcached:11211' "$work/scrape"
grep -Fx 'memcached_up 1' "$work/scrape" >/dev/null ||
  fail 'multi-target scrape did not reach memcached'

# Negative: an unreachable target reports down instead of failing the scrape.
scrape '/scrape?target=unreachable.invalid:11211' "$work/down"
grep -Fx 'memcached_up 0' "$work/down" >/dev/null ||
  fail 'unreachable target was not reported as down'

docker stop -t 10 "$exporter" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$exporter") in
  0 | 2 | 143) ;;
  *) fail 'exporter did not stop on SIGTERM' ;;
esac
shutdown_log=$(docker logs "$exporter" 2>&1) || fail 'could not read the exporter log after SIGTERM'
if printf '%s\n' "$shutdown_log" | grep -Eq '^(panic: |fatal error: |goroutine [0-9]+ \[)'; then
  fail 'exporter crashed instead of stopping on SIGTERM'
fi

echo "memcached-exporter $expected_version smoke test passed"
