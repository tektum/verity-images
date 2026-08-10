#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --help >/dev/null || fail '/manager safe help path failed'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  -e KUBECONFIG=/tmp/missing "$image" 2>&1); then
  fail 'missing Kubernetes credentials unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unable to get kubeconfig' >/dev/null \
  || fail 'missing Kubernetes credentials did not report a kubeconfig error'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F -- '--not-a-real-flag' >/dev/null \
  || fail 'invalid flag diagnostic missing'

printf 'SMOKE PASS image=%s\n' "$image"
