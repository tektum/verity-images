#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container=verity-opensearch-test-$$
volume=verity-opensearch-data-$$

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the fixture by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") ||
  fail 'cannot inspect fixture image index'
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail 'fixture image index digest mismatch'
fixture_digest=$(printf '%s' "$fixture_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve fixture image digest'
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch fixture image in $fixture_index" ;;
esac
fixture=docker.io/curlimages/curl@$fixture_digest
docker pull --quiet --platform "linux/$image_arch" "$fixture" >/dev/null ||
  fail 'cannot pull fixture image'

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
docker run --rm --entrypoint java "$image" -version 2>&1 | grep -q 'version "21' || fail 'Java 21 is missing'
docker run --rm "$image" --version 2>/dev/null | grep -q "^Version: $expected_version," ||
  fail 'unexpected OpenSearch version'

# Probe from a separate container on the default bridge, so the server must bind beyond loopback.
http() { docker run --rm "$fixture" -fsS "$@"; }

start_server() {
  docker run --name "$container" -d -v "$volume:/usr/share/opensearch/data" \
    -e OPENSEARCH_JAVA_OPTS='-Xms512m -Xmx512m' "$image" -Ediscovery.type=single-node >/dev/null
  address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")
  [ -n "$address" ] || fail 'server container has no bridge address'
  i=0
  until http "http://$address:9200/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'OpenSearch exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 180 ] || {
      docker logs "$container" >&2
      fail 'OpenSearch did not become ready'
    }
    sleep 1
  done
}

docker volume create "$volume" >/dev/null
start_server
http "http://$address:9200/" | grep -q "\"number\" : \"$expected_version\"" ||
  fail 'root endpoint does not report the shipped version'
http -X PUT -H 'Content-Type: application/json' --data '{"title":"persisted"}' \
  "http://$address:9200/verity/_doc/1?refresh=true" >/dev/null || fail 'indexing failed'
http "http://$address:9200/verity/_search?q=title:persisted" | grep -q '"value":1' ||
  fail 'indexed document was not found'
docker stop --time 60 "$container" >/dev/null
docker rm "$container" >/dev/null

start_server
http "http://$address:9200/verity/_doc/1" | grep -q '"found":true' || fail 'document was not persisted'
if http "http://$address:9200/nosuch/_search" >/dev/null 2>&1; then
  fail 'search against a missing index unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
