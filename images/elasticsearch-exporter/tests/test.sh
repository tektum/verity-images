#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
# Live catalog OpenSearch 3 index, pinned by digest. It speaks the Elasticsearch
# API the exporter scrapes.
backend_index='ghcr.io/tektum/opensearch@sha256:b3fc817726ee2e73d10059a14b28ce36bce1d6ea55d64f5de03e285ae8345b4e'
backend="verity-esexp-backend-$$"
exporter="verity-esexp-exporter-$$"
orphan="verity-esexp-orphan-$$"
network="verity-esexp-network-$$"
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
  # $1 container, $2 host port, $3 output file, $4 required line (extended regex)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -E "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || {
      docker logs "$1" >&2
      fail "metrics did not match: $4"
    }
    sleep 1
  done
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/elasticsearch_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E '^elasticsearch_exporter, version [0-9]+\.[0-9]+\.[0-9]+ ' >/dev/null ||
  fail 'unexpected exporter version'

created=$(docker create "$image")
docker cp "$created:/usr/bin/elasticsearch_exporter" "$tmp/elasticsearch_exporter"
docker rm "$created" >/dev/null
if [ "$flavor" = fips ]; then
  go version -m "$tmp/elasticsearch_exporter" | grep -q 'GOFIPS140=v1.0.0' ||
    fail 'fips flavor must be built with GOFIPS140=v1.0.0'
elif go version -m "$tmp/elasticsearch_exporter" | grep -q 'GOFIPS140='; then
  fail 'plain flavor must not set GOFIPS140'
fi

# Negative: an unknown flag exits non-zero with a readable diagnostic.
if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'no-such-flag' "$tmp/invalid.log" >/dev/null || fail 'unknown flag error missing'

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned backend by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
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
  -p 127.0.0.1::9200 -e OPENSEARCH_JAVA_OPTS='-Xms512m -Xmx512m' \
  "$backend_image" -Ediscovery.type=single-node >/dev/null
backend_port=$(docker port "$backend" 9200/tcp | awk -F: 'NR == 1 { print $2 }')
attempts=0
until curl --fail --silent --max-time 3 \
  "http://127.0.0.1:$backend_port/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 180 ] || { docker logs "$backend" >&2; fail 'backend did not become ready'; }
  sleep 1
done
curl --fail --silent -X PUT -H 'Content-Type: application/json' \
  --data '{"title":"verity"}' \
  "http://127.0.0.1:$backend_port/verity/_doc/1?refresh=true" >/dev/null ||
  fail 'seeding the backend index failed'

docker run --name "$exporter" -d --network "$network" --read-only \
  -p 127.0.0.1::9114 \
  "$image" --es.uri=http://search:9200 --es.indices >/dev/null
port=$(docker port "$exporter" 9114/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

wait_metrics "$exporter" "$port" "$tmp/metrics" '^elasticsearch_cluster_health_number_of_nodes\{cluster="opensearch"\} 1$'
grep -E '^elasticsearch_clusterinfo_up\{url="http://search:9200"\} 1$' "$tmp/metrics" >/dev/null ||
  fail 'elasticsearch_clusterinfo_up is not 1 for the live backend'
grep -E '^elasticsearch_cluster_health_status\{cluster="opensearch",color="(green|yellow)"\} 1$' "$tmp/metrics" >/dev/null ||
  fail 'elasticsearch_cluster_health_status for green or yellow missing'
grep -E '^elasticsearch_indices_docs_total\{cluster="opensearch",index="verity"\} 1$' "$tmp/metrics" >/dev/null ||
  fail 'per-index metrics for the seeded index are missing'

# An unreachable backend must be reported as down while the exporter itself
# keeps serving.
docker run --name "$orphan" -d --network "$network" -p 127.0.0.1::9114 \
  "$image" --es.uri=http://unreachable.invalid:9200 >/dev/null
orphan_port=$(docker port "$orphan" 9114/tcp | awk -F: 'NR == 1 { print $2 }')
wait_metrics "$orphan" "$orphan_port" "$tmp/orphan.metrics" '^elasticsearch_clusterinfo_up\{url="http://unreachable.invalid:9200"\} 0$'

# Upstream exits with status 2 on SIGTERM; 137 would mean docker had to SIGKILL it.
docker stop --time 10 "$exporter" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$exporter") in
  0|2|143) ;;
  *) fail 'exporter did not stop promptly on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s flavor=%s\n' "$image" "$flavor"
