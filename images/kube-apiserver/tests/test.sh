#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ]
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kube-apiserver-1.36"]' ]

[ "$(docker run --rm "$image" --version)" = 'Kubernetes v1.36.3' ]
help=$(docker run --rm "$image" --help)
printf '%s\n' "$help" | grep -Fq \
  'The Kubernetes API server validates and configures data'

if output=$(docker run --rm "$image" --definitely-invalid-flag 2>&1); then
  echo 'invalid flag unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq 'unknown flag: --definitely-invalid-flag'

if output=$(docker run --rm "$image" --secure-port=-1 2>&1); then
  echo 'invalid secure port unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq -- \
  '--secure-port -1 must be between 1 and 65535, inclusive'
