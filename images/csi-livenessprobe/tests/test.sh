#!/bin/sh
set -eu

# A pinned upstream CSI hostpath driver serves the Probe RPC on a Unix socket in
# a shared volume. The livenessprobe under test connects to that socket and
# must report 200 on /healthz while the driver is up, then fail once the driver
# is gone. HTTP requests come from a pinned curl container in the probe's
# network namespace, so nothing is published on the host.

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([0-9][0-9.]*\)".*$/\1/p' "$recipe")
driver_index='registry.k8s.io/sig-storage/hostpathplugin:v1.17.0@sha256:e20e2681349cb892bc88d8ab23c6785949bdb7e9b518bf3a261b5f13034f8b3b'
curl_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
label="verity-test=csi-livenessprobe-$$"
volume=verity-csi-livenessprobe-$$
driver=verity-csi-driver-$$
probe=verity-csi-probe-$$

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$expected_version" ] || fail 'livenessprobe package version not found'

inspect() {
  docker image inspect --format "$1" "$image"
}

[ "$(inspect '{{.Config.User}}')" = 65532 ] || fail 'unexpected OCI user'
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["/usr/bin/livenessprobe"]' ] ||
  fail "unexpected entrypoint: $(inspect '{{json .Config.Entrypoint}}')"

usage=$(docker run --rm "$image" -h 2>&1 || true)
printf '%s\n' "$usage" | grep -q -- '-csi-address' || fail 'usage is missing -csi-address'
printf '%s\n' "$usage" | grep -q -- '-health-port' || fail 'usage is missing -health-port'

# pull_child INDEX: pull the pinned index by its per-platform child digest, verifying the
# index bytes against the pin first. publish-image runs this test once per platform on one
# host, and a classic Docker image store cannot bind an index digest to a second platform.
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
driver_image=$(pull_child "$driver_index") || exit 1
curl_image=$(pull_child "$curl_index") || exit 1
[ -n "$driver_image" ] && [ -n "$curl_image" ] || fail 'cannot resolve helper images'

docker volume create --label "$label" "$volume" >/dev/null
docker run --rm --label "$label" -u 0 -v "$volume:/csi" --entrypoint chmod "$curl_image" 0777 /csi ||
  fail 'could not prepare the socket volume'

docker run -d --label "$label" --name "$driver" --network none --user 65532 \
  -v "$volume:/csi" "$driver_image" \
  --endpoint=unix:///csi/csi.sock --nodeid=verity --drivername=hostpath.csi.k8s.io \
  --statedir=/csi/state >/dev/null || fail 'CSI driver did not start'

docker run -d --label "$label" --name "$probe" -v "$volume:/csi" "$image" \
  --csi-address=/csi/csi.sock --health-port=9808 --probe-timeout=3s >/dev/null ||
  fail 'livenessprobe did not start'

healthz() {
  docker run --rm --label "$label" --network "container:$probe" "$curl_image" \
    -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9808/healthz 2>/dev/null || true
}

status=
i=0
while [ $i -lt 30 ]; do
  status=$(healthz)
  [ "$status" = 200 ] && break
  i=$((i + 1))
  sleep 1
done
[ "$status" = 200 ] || {
  docker logs "$probe" >&2 || true
  fail "healthz did not report 200 with a live driver: $status"
}

docker logs "$probe" 2>&1 | grep -q 'driver="hostpath.csi.k8s.io"' ||
  fail 'livenessprobe did not discover the CSI driver name'

docker rm -f "$driver" >/dev/null
status=$(healthz)
case "$status" in
  200) fail 'healthz still reported 200 after the driver stopped' ;;
  5??) ;;
  *) fail "unexpected healthz status after the driver stopped: $status" ;;
esac

printf 'SMOKE PASS version=%s\n' "$expected_version"
