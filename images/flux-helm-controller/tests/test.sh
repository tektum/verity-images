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

help_output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --help 2>&1) || fail '/manager safe help path failed'
printf '%s\n' "$help_output" | grep -F -- '--http-timeout duration' >/dev/null \
  || fail 'current HTTP timeout flag is missing'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  -e KUBECONFIG=/tmp/missing "$image" 2>&1); then
  fail 'missing Kubernetes credentials unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unable to get kubeconfig' >/dev/null \
  || fail 'missing Kubernetes credentials did not report a kubeconfig error'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  -e KUBECONFIG=/tmp/missing "$image" --feature-gates=UseHelm3Defaults=true 2>&1); then
  fail 'Helm 3 compatibility gate startup unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unable to get kubeconfig' >/dev/null \
  || fail 'Helm 3 compatibility gate was not accepted'

if output=$(docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 \
  "$image" --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F -- '--not-a-real-flag' >/dev/null \
  || fail 'invalid flag diagnostic missing'

printf 'SMOKE PASS image=%s\n' "$image"
