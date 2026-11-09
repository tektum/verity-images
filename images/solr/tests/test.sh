#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container=verity-solr-test-$$
volume=verity-solr-data-$$

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

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 8983 ] || fail 'unexpected OCI user'
docker run --rm --entrypoint java "$image" -version 2>&1 | grep -q 'version "21' || fail 'Java 21 is missing'
docker run --rm "$image" version 2>/dev/null | grep -qx "Client version: $expected_version" || fail 'unexpected Solr version'

docker volume create "$volume" >/dev/null
docker run --name "$container" -d -v "$volume:/var/solr" -e SOLR_HEAP=512m "$image" start -f -c >/dev/null

i=0
# The image ships no HTTP client, so a curl sidecar shares the server's network namespace.
http() { docker run --rm --network "container:$container" "$fixture" -fsS "$@"; }

until http 'http://localhost:8983/solr/admin/info/system?wt=json' >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
    docker logs "$container" >&2
    fail 'Solr exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 120 ] || {
    docker logs "$container" >&2
    fail 'Solr did not become ready'
  }
  sleep 1
done

http 'http://localhost:8983/solr/admin/info/system?wt=json' | grep -q "\"solr-spec-version\":\"$expected_version\"" ||
  fail 'system info does not report the shipped version'
http 'http://localhost:8983/solr/admin/collections?action=CREATE&name=verity&numShards=1&replicationFactor=1&wt=json' |
  grep -q '"status":0' || fail 'collection creation failed'
http -H 'Content-Type: application/json' --data '[{"id":"1","title_s":"persisted"}]' \
  'http://localhost:8983/solr/verity/update?commit=true' >/dev/null ||
  fail 'indexing failed'
[ "$(http 'http://localhost:8983/solr/verity/select?q=title_s:persisted&wt=json' | grep -c '"numFound":1')" = 1 ] ||
  fail 'indexed document was not found'
if http 'http://localhost:8983/solr/nosuch/select?q=*:*' >/dev/null 2>&1; then
  fail 'query against a missing collection unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
