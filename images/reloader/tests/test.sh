#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected image user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/manager"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] \
  || fail 'unexpected image command'

docker run --rm --network none --entrypoint /usr/bin/manager "$image" --help >/dev/null 2>&1 \
  && fail 'controller unexpectedly started without a cluster'

if output=$(docker run --rm --network none "$image" 2>&1); then
  fail 'controller unexpectedly started without a cluster'
fi
printf '%s\n' "$output" | grep -F 'Unable to create Kubernetes client' >/dev/null \
  || fail 'missing cluster did not report the expected client error'
printf '%s\n' "$output" | grep -F 'KUBERNETES_SERVICE_HOST' >/dev/null \
  || fail 'client error did not name the in-cluster environment'

if output=$(docker run --rm --network none \
  -e KUBERNETES_SERVICE_HOST=127.0.0.1 -e KUBERNETES_SERVICE_PORT=1 "$image" 2>&1); then
  fail 'controller unexpectedly started with an unreachable API server'
fi
printf '%s\n' "$output" | grep -E 'level=(fatal|error)' >/dev/null \
  || fail 'unreachable API server did not fail with a logged error'

printf 'SMOKE PASS image=%s\n' "$image"
