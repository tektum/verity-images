#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --user 65534 --cpus 4 --memory 1g --pids-limit 256 "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

help_output=$(run "$image" --help 2>&1) || fail '/manager safe help path failed'
printf '%s\n' "$help_output" | grep -F -- '--storage-path string' >/dev/null \
  || fail 'storage path flag is missing'
printf '%s\n' "$help_output" | grep -F -- '--default-service-account string' >/dev/null \
  || fail 'default service account flag is missing'

# Without credentials the controller must fail with a readable kubeconfig error
# once its storage directory is usable.
if output=$(run --tmpfs /tmp -e KUBECONFIG=/tmp/missing "$image" --storage-path=/tmp/data 2>&1); then
  fail 'missing Kubernetes credentials unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unable to get kubeconfig' >/dev/null \
  || fail 'missing Kubernetes credentials did not report a kubeconfig error'

# The default storage path does not exist in the image and must be reported.
if output=$(run -e KUBECONFIG=/tmp/missing "$image" 2>&1); then
  fail 'unwritable default storage path unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'failed to create storage path' >/dev/null \
  || fail 'unwritable default storage path was not reported'

if output=$(run "$image" --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F -- '--not-a-real-flag' >/dev/null \
  || fail 'invalid flag diagnostic missing'

printf 'SMOKE PASS image=%s\n' "$image"
