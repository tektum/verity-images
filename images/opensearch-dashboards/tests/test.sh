#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
# Live catalog OpenSearch 3 index (security plugin off, plain HTTP), pinned by digest.
backend_index='ghcr.io/tektum/opensearch@sha256:b3fc817726ee2e73d10059a14b28ce36bce1d6ea55d64f5de03e285ae8345b4e'
network="verity-osd-network-$$"
backend="verity-osd-backend-$$"
dashboards="verity-osd-dashboards-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$dashboards" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/share/opensearch-dashboards/opensearch-dashboards-docker-entrypoint.sh"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["opensearch-dashboards"]' ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /usr/share/opensearch-dashboards ||
  fail 'unexpected working directory'

docker run --rm --platform "$platform" --entrypoint /usr/share/opensearch-dashboards/node/bin/node "$image" --version |
  grep -E '^v22\.' >/dev/null || fail 'bundled Node.js is not 22.x'
docker run --rm --platform "$platform" "$image" opensearch-dashboards --version 2>&1 |
  grep -F "$expected_version" >/dev/null || fail 'unexpected OpenSearch Dashboards version'

# Negative: an unknown option must fail with a readable error.
if docker run --rm --platform "$platform" "$image" opensearch-dashboards --no-such-option \
  >"$tmp/invalid.log" 2>&1; then
  fail 'unknown option unexpectedly succeeded'
fi
grep -iE 'unknown|invalid|no-such-option' "$tmp/invalid.log" >/dev/null ||
  { cat "$tmp/invalid.log" >&2; fail 'unknown option diagnostic is missing'; }

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned backend by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen.
backend_raw=$(docker buildx imagetools inspect --raw "$backend_index") ||
  fail 'cannot inspect backend image index'
[ "sha256:$(printf '%s' "$backend_raw" | sha256sum | cut -d' ' -f1)" = "${backend_index#*@}" ] ||
  fail 'backend image index digest mismatch'
backend_digest=$(printf '%s' "$backend_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve backend image digest'
case $backend_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch backend image in $backend_index" ;;
esac
backend_image=${backend_index%%@*}@$backend_digest
docker pull --quiet --platform "linux/$image_arch" "$backend_image" >/dev/null ||
  fail 'cannot pull backend image'

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias search \
  -e OPENSEARCH_JAVA_OPTS='-Xms512m -Xmx512m' "$backend_image" -Ediscovery.type=single-node >/dev/null

# The upstream entrypoint maps OPENSEARCH_* variables to --opensearch.* options and
# DISABLE_SECURITY_DASHBOARDS_PLUGIN removes the security plugin for the HTTP backend.
docker run --platform "$platform" --name "$dashboards" -d --network "$network" -m 4g \
  -p 127.0.0.1::5601 \
  -e OPENSEARCH_HOSTS='["http://search:9200"]' \
  -e DISABLE_SECURITY_DASHBOARDS_PLUGIN=true \
  "$image" >/dev/null
port=$(docker port "$dashboards" 5601/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

i=0
until curl --silent --max-time 5 "http://127.0.0.1:$port/api/status" 2>/dev/null |
  jq -e '.status.overall.state == "green"' >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$dashboards")" = true ] || {
    docker logs "$dashboards" >&2
    fail 'dashboards exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 420 ] || {
    docker logs "$dashboards" >&2
    fail 'dashboards did not report a green status'
  }
  sleep 2
done

status=$(curl --silent --fail "http://127.0.0.1:$port/api/status")
printf '%s' "$status" | jq -e --arg v "$expected_version" '.version.number == $v' >/dev/null ||
  fail '/api/status does not report the shipped version'
# The bundled security plugin was removed by the entrypoint for the HTTP backend.
if docker exec "$dashboards" test -d /usr/share/opensearch-dashboards/plugins/securityDashboards; then
  fail 'DISABLE_SECURITY_DASHBOARDS_PLUGIN did not remove the security plugin'
fi
# The remaining bundled plugins are present.
for plugin in observabilityDashboards alertingDashboards indexManagementDashboards; do
  docker exec "$dashboards" test -d "/usr/share/opensearch-dashboards/plugins/$plugin" ||
    fail "bundled plugin $plugin is missing"
done

# A saved object round trip proves the connection to OpenSearch (the .kibana index).
curl --silent --fail -X POST -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
  --data '{"attributes":{"title":"verity-*"}}' \
  "http://127.0.0.1:$port/api/saved_objects/index-pattern/verity" >/dev/null ||
  fail 'creating a saved object failed'
curl --silent --fail "http://127.0.0.1:$port/api/saved_objects/index-pattern/verity" |
  jq -e '.attributes.title == "verity-*"' >/dev/null || fail 'saved object was not persisted in OpenSearch'

docker stop --time 30 "$dashboards" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$dashboards") in
  0|143) ;;
  *) fail 'dashboards did not stop cleanly on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
