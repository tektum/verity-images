#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-pushgateway-test-$$"
volume="verity-pushgateway-data-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

curl_fixture() {
  docker run --rm --network "container:$container" "$fixture" "$@"
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/pushgateway"]' ] || fail 'unexpected image entrypoint'
docker run --rm "$image" --version 2>&1 | grep -F 'version 1.11.3' >/dev/null || fail 'pushgateway version check failed'

docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d -v "$volume:/tmp" "$image" \
    --web.listen-address=0.0.0.0:9091 \
    --persistence.file=/tmp/pushgateway.data \
    >/dev/null

  i=0
  until [ "$(curl_fixture --silent --show-error http://127.0.0.1:9091/-/ready 2>/dev/null)" = OK ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'Pushgateway exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 30 ] || {
      docker logs "$container" >&2
      fail 'Pushgateway did not become ready'
    }
    sleep 1
  done
}

start_server

cat <<'EOF' | docker run --rm -i --network "container:$container" "$fixture" \
  --fail --silent --show-error --data-binary @- \
  http://127.0.0.1:9091/metrics/job/verity_smoke
# TYPE verity_smoke_metric gauge
verity_smoke_metric 42
EOF

curl_fixture --fail --silent --show-error http://127.0.0.1:9091/metrics \
  | grep -F 'verity_smoke_metric{instance="",job="verity_smoke"} 42' >/dev/null \
  || fail 'pushed metric was not readable back from /metrics'

malformed_code=$(docker run --rm -i --network "container:$container" "$fixture" \
  --silent --output /dev/null --write-out '%{http_code}' --data-binary 'not a valid metric line' \
  http://127.0.0.1:9091/metrics/job/verity_smoke)
[ "$malformed_code" = 400 ] || fail "malformed metric push returned $malformed_code, expected 400"

docker stop --time 30 "$container" >/dev/null
docker rm "$container" >/dev/null

docker run --rm -v "$volume:/data" --entrypoint /bin/sh "$fixture" \
  -c '[ -s /data/pushgateway.data ]' \
  || fail 'persistence file was not written after graceful shutdown'

start_server
curl_fixture --fail --silent --show-error http://127.0.0.1:9091/metrics \
  | grep -F 'verity_smoke_metric{instance="",job="verity_smoke"} 42' >/dev/null \
  || fail 'pushed metric did not survive restart via the persistence file'

printf 'SMOKE PASS image=%s\n' "$image"
