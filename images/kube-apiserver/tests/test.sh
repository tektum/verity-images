#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s: %s\n' "$image" "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] ||
  fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kube-apiserver-1.36"]' ] || fail 'unexpected OCI entrypoint'

[ "$(docker run --rm --network none --read-only "$image" --version)" = 'Kubernetes v1.36.3' ] ||
  fail 'unexpected version'
help=$(docker run --rm --network none --read-only "$image" --help)
printf '%s\n' "$help" | grep -Fq \
  'The Kubernetes API server validates and configures data' || fail 'help text missing'

if output=$(docker run --rm --network none --read-only "$image" --definitely-invalid-flag 2>&1); then
  echo 'invalid flag unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq 'unknown flag: --definitely-invalid-flag' ||
  fail 'invalid flag error missing'

if output=$(docker run --rm --network none --read-only --tmpfs /tmp \
  "$image" --advertise-address=127.0.0.1 --secure-port=-1 --cert-dir=/tmp 2>&1); then
  echo 'invalid secure port unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq -- \
  '--secure-port -1 must be between 1 and 65535, inclusive' ||
  fail 'invalid secure port error missing'

printf 'SMOKE PASS %s\n' "$image"
