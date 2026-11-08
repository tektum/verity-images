#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
nginx_index='docker.io/library/nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de'
backend="verity-nginx-exporter-nginx-$$"
exporter="verity-nginx-exporter-exporter-$$"
orphan="verity-nginx-exporter-orphan-$$"
network="verity-nginx-exporter-network-$$"
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

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/nginx-prometheus-exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E 'nginx_exporter, version 1\.5\.' >/dev/null ||
  fail 'unexpected exporter version'

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
nginx_raw=$(docker buildx imagetools inspect --raw "$nginx_index") ||
  fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$nginx_raw" | sha256sum | cut -d' ' -f1)" = "${nginx_index#*@}" ] ||
  fail 'helper image index digest mismatch'
nginx_digest=$(printf '%s' "$nginx_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve helper image digest'
case $nginx_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $nginx_index" ;;
esac
nginx=docker.io/library/nginx@$nginx_digest
docker pull --quiet --platform "linux/$image_arch" "$nginx" >/dev/null ||
  fail 'cannot pull helper image'

cat >"$tmp/default.conf" <<'EOF'
server {
  listen 8080;
  location = /stub_status {
    stub_status;
  }
}
EOF
chmod 644 "$tmp/default.conf"

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias nginx \
  -v "$tmp/default.conf:/etc/nginx/conf.d/default.conf:ro" "$nginx" >/dev/null

attempts=0
until docker exec "$backend" wget -q -O - http://127.0.0.1:8080/stub_status >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$backend" >&2
    exit 1
  }
  sleep 1
done

docker run --name "$exporter" -d --network "$network" --read-only \
  -p 127.0.0.1::9113 \
  "$image" --nginx.scrape-uri=http://nginx:8080/stub_status >/dev/null
port=$(docker port "$exporter" 9113/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/metrics" >"$tmp/metrics" 2>/dev/null &&
  grep -Fx 'nginx_up 1' "$tmp/metrics" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$exporter" >&2
    cat "$tmp/metrics" >&2 || true
    fail 'exporter did not report nginx_up 1'
  }
  sleep 1
done
grep -E '^nginx_connections_accepted [1-9]' "$tmp/metrics" >/dev/null ||
  fail 'nginx_connections_accepted missing or zero'
grep -F 'nginx_exporter_build_info{' "$tmp/metrics" >/dev/null ||
  fail 'nginx_exporter_build_info missing'

# An unreachable stub_status endpoint must be reported as nginx_up 0 while
# the exporter itself keeps serving.
docker run --name "$orphan" -d --network "$network" -p 127.0.0.1::9113 \
  "$image" --nginx.scrape-uri=http://unreachable.invalid:8080/stub_status >/dev/null
orphan_port=$(docker port "$orphan" 9113/tcp | awk -F: 'NR == 1 { print $2 }')
attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$orphan_port/metrics" >"$tmp/orphan.metrics" 2>/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$orphan" >&2
    exit 1
  }
  sleep 1
done
grep -Fx 'nginx_up 0' "$tmp/orphan.metrics" >/dev/null ||
  fail 'unreachable backend must report nginx_up 0'

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'unknown long flag' "$tmp/invalid.log" >/dev/null ||
  fail 'unknown flag error missing'

docker stop "$exporter" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$exporter")" = 0 ] ||
  fail 'exporter did not stop cleanly on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"
