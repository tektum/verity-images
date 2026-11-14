#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Catalog nginx is the local egress destination and catalog curl the client,
# both pinned by index digest.
upstream_index=ghcr.io/tektum/nginx@sha256:1f15c75985329f5ff751ded753e4f80eea80e1e0a18bd7728e2e9bf3bd4bfc15
curl_index=ghcr.io/tektum/curl@sha256:845cf5a624918906e519018049a5d1729371a0f2e9d1191b420af5cf72cdf20b

id=$$
network="verity-smokescreen-$id"
proxy="verity-smokescreen-proxy-$id"
allowed="verity-smokescreen-allowed-$id"
other="verity-smokescreen-other-$id"
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$proxy" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

cleanup() {
  docker rm -f "$proxy" "$allowed" "$other" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/smokescreen"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 || fail 'unexpected OCI user'

version=$(docker run --rm --network none "$image" --version) || fail 'smokescreen --version failed'
printf '%s\n' "$version" | grep -F "v$expected_version" >/dev/null || fail "unexpected version: $version"

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
upstream_image=$(pull_child "$upstream_index")
curl_image=$(pull_child "$curl_index")

# Two local destinations on a private Docker network.
docker network create "$network" >/dev/null
docker run -d --name "$allowed" --network "$network" "$upstream_image" >/dev/null
docker run -d --name "$other" --network "$network" "$upstream_image" >/dev/null
subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network")
allowed_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$allowed")
other_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$other")
[ -n "$subnet" ] && [ -n "$allowed_ip" ] && [ -n "$other_ip" ] || fail 'could not read the network addresses'

# start_proxy ARGS: run smokescreen on its default port with ARGS.
start_proxy() {
  docker rm -f "$proxy" >/dev/null 2>&1 || true
  docker run -d --name "$proxy" --network "$network" --read-only --cap-drop=ALL \
    --security-opt no-new-privileges "$image" "$@" >/dev/null
  i=0
  until docker logs "$proxy" 2>&1 | grep -F 'starting' >/dev/null; do
    [ "$(docker inspect --format '{{.State.Running}}' "$proxy")" = true ] || fail 'smokescreen exited'
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail 'smokescreen did not start'
    sleep 1
  done
}

# fetch NAME URL [CURL_ARGS]: request URL through the proxy; record the status
# code, the Smokescreen error header, and the body under $work/NAME.
fetch() {
  name=$1
  url=$2
  shift 2
  status=0
  docker run --rm --network "$network" "$curl_image" -sS --max-time 20 --retry 0 \
    --proxy "http://$proxy:4750" -D - "$@" "$url" >"$work/$name" 2>&1 || status=$?
  printf '%s' "$status" >"$work/$name.exit"
}

# expect_allowed NAME: the destination answered through the proxy.
expect_allowed() {
  test "$(cat "$work/$1.exit")" = 0 || fail "$1 was not allowed: $(cat "$work/$1")"
  grep -E '^HTTP/[0-9.]+ 200' "$work/$1" >/dev/null || fail "$1 did not return 200: $(cat "$work/$1")"
  grep -F 'nginx' "$work/$1" >/dev/null || fail "$1 did not reach nginx: $(cat "$work/$1")"
}

# expect_denied NAME HOST: smokescreen refused the destination itself, with
# 407 for plain HTTP and for CONNECT.
expect_denied() {
  grep -E '^HTTP/[0-9.]+ 407 ' "$work/$1" >/dev/null || fail "$1 was not refused with 407: $(cat "$work/$1")"
  grep -F "Egress proxying is denied to host '$2'" "$work/$1" >/dev/null ||
    fail "$1 was not denied by smokescreen: $(cat "$work/$1")"
  grep -iF 'X-Smokescreen-Error:' "$work/$1" >/dev/null || fail "$1 has no X-Smokescreen-Error header"
  if grep -E '^Server: nginx' "$work/$1" >/dev/null; then
    fail "$1 reached the destination"
  fi
}

# Default policy: local (private range) egress is denied, for plain HTTP and
# for CONNECT tunnels.
start_proxy
fetch default-http "http://$allowed/"
expect_denied default-http "$allowed"
grep -F 'Private Range' "$work/default-http" >/dev/null || fail 'denial did not name the private range rule'
fetch default-connect "http://$allowed/" --proxytunnel
expect_denied default-connect "$allowed:80"
docker logs "$proxy" 2>&1 | grep -F '"allow":false' >/dev/null || fail 'denial was not logged'

# An allowed address opens exactly that destination; its neighbour stays denied.
start_proxy --allow-address "$allowed_ip:80"
fetch address-http "http://$allowed/"
expect_allowed address-http
fetch address-connect "http://$allowed/" --proxytunnel
expect_allowed address-connect
fetch address-other "http://$other/"
expect_denied address-other "$other"
docker logs "$proxy" 2>&1 | grep -F '"allow":true' >/dev/null || fail 'allowed request was not logged'

# An allowed range opens the whole local network.
start_proxy --allow-range "$subnet"
fetch range-allowed "http://$allowed/"
expect_allowed range-allowed
fetch range-other "http://$other_ip/"
expect_allowed range-other

# A denied address stays denied even when private ranges are allowed.
start_proxy --unsafe-allow-private-ranges --deny-address "$other_ip"
fetch unsafe-allowed "http://$allowed/"
expect_allowed unsafe-allowed
fetch unsafe-denied "http://$other_ip/"
expect_denied unsafe-denied "$other_ip"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
