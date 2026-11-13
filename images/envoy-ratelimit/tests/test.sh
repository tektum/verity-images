#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
valkey_index='docker.io/valkey/valkey:9-alpine@sha256:bf09d58e96d6b4524a15396b65b242bbe18beebbcc15a04d8ee75ddac62fae0b'
network="verity-envoy-ratelimit-net-$$"
backend="verity-envoy-ratelimit-valkey-$$"
container="verity-envoy-ratelimit-test-$$"
broken="verity-envoy-ratelimit-broken-$$"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" "$broken" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/ratelimit"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

# Pull pinned helper indexes by their per-platform child digest. A classic
# Docker image store cannot bind an index digest to a second platform's image,
# so the index bytes are verified against the pin before a child is chosen,
# which keeps the pin authoritative.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail "cannot inspect helper image index $helper_index"
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail "helper image index digest mismatch for $helper_index"
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
resolve_helper "$curl_index"
curl_image=$helper
resolve_helper "$valkey_index"
valkey=$helper

# The upstream file runtime layout: RUNTIME_ROOT/RUNTIME_SUBDIRECTORY/config/*.yaml.
mkdir -p "$work/good/ratelimit/config" "$work/bad/ratelimit/config"
cat >"$work/good/ratelimit/config/smoke.yaml" <<'EOF'
domain: verity
descriptors:
  - key: client
    value: smoke
    rate_limit:
      unit: minute
      requests_per_unit: 1
EOF
cat >"$work/bad/ratelimit/config/smoke.yaml" <<'EOF'
domain: verity
descriptors:
  - key: client
    value: smoke
    rate_limit:
      unit: fortnight
      requests_per_unit: 1
EOF
chmod -R a+rX "$work/good" "$work/bad"

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias valkey "$valkey" \
  valkey-server --save '' --appendonly no --ignore-warnings ARM64-COW-BUG >/dev/null
i=0
until [ "$(docker exec "$backend" valkey-cli ping 2>/dev/null)" = PONG ]; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail "valkey fixture did not become ready: $(docker logs "$backend" 2>&1)"
  sleep 1
done

start() {
  docker run --name "$1" -d --network "$network" --read-only --cap-drop=ALL \
    -v "$work/$2:/data:ro" -e USE_STATSD=false -e REDIS_SOCKET_TYPE=tcp \
    -e REDIS_URL=valkey:6379 -e RUNTIME_ROOT=/data -e RUNTIME_SUBDIRECTORY=ratelimit \
    -e RUNTIME_WATCH_ROOT=false "$image" >/dev/null
  i=0
  until [ "$(curl_in "$1" --silent http://127.0.0.1:8080/healthcheck 2>/dev/null)" = OK ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$1")" = true ] ||
      fail "$1 exited: $(docker logs "$1" 2>&1 | tail -20)"
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "$1 did not become healthy: $(docker logs "$1" 2>&1 | tail -20)"
    sleep 1
  done
}

curl_in() {
  target=$1
  shift
  docker run --rm --network "container:$target" "$curl_image" "$@"
}

# should_rate_limit TARGET VALUE OUT: POST a ShouldRateLimit request to the
# HTTP JSON endpoint and print the HTTP status.
should_rate_limit() {
  curl_in "$1" --silent --show-error --output /dev/stdout --write-out '\n%{http_code}' \
    --data "{\"domain\":\"verity\",\"descriptors\":[{\"entries\":[{\"key\":\"client\",\"value\":\"$2\"}]}]}" \
    http://127.0.0.1:8080/json >"$work/$3"
  tail -n 1 "$work/$3"
}

start "$container" good

curl_in "$container" --fail --silent --show-error http://127.0.0.1:6070/rlconfig >"$work/rlconfig" ||
  fail 'debug config endpoint failed'
grep -F 'verity.client_smoke: unit=MINUTE requests_per_unit=1' "$work/rlconfig" >/dev/null ||
  fail "config was not loaded: $(cat "$work/rlconfig")"

# One request per minute: the first is allowed, the second is over the limit.
# Start early in a window so both requests share the same fixed one-minute bucket.
while [ "$(date -u +%S)" -ge 45 ]; do sleep 1; done
test "$(should_rate_limit "$container" smoke first)" = 200 || fail "first request: $(cat "$work/first")"
grep -F '"overallCode":"OK"' "$work/first" >/dev/null || fail 'first request was not OK'
test "$(should_rate_limit "$container" smoke second)" = 429 || fail "second request: $(cat "$work/second")"
grep -F '"overallCode":"OVER_LIMIT"' "$work/second" >/dev/null || fail 'second request was not OVER_LIMIT'

# An unconfigured descriptor is not limited, and the counter lives in Valkey.
test "$(should_rate_limit "$container" other other)" = 200 || fail "other descriptor: $(cat "$work/other")"
grep -F '"overallCode":"OK"' "$work/other" >/dev/null || fail 'unconfigured descriptor was limited'
docker exec "$backend" valkey-cli --scan --pattern 'verity_client_smoke_*' | grep . >/dev/null ||
  fail 'no rate limit counter was written to Valkey'

# SIGTERM shuts the service down cleanly.
docker stop --time 10 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
  fail "service did not exit cleanly: $(docker logs "$container" 2>&1 | tail -5)"

# Negative: an invalid rate limit unit is reported and no request is served
# against the rejected configuration.
start "$broken" bad
docker logs "$broken" 2>&1 | grep -F "invalid rate limit unit 'fortnight'" >/dev/null ||
  fail 'invalid configuration was not reported'
test "$(should_rate_limit "$broken" smoke broken.out)" = 400 ||
  fail "request against a rejected configuration: $(cat "$work/broken.out")"

echo 'SMOKE PASS'
