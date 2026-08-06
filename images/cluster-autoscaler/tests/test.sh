#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

docker run --rm --network none "$image" --help >/dev/null || fail '/usr/bin/cluster-autoscaler is not executable'
docker run --rm --network none --entrypoint /cluster-autoscaler "$image" --help >/dev/null || fail '/cluster-autoscaler is not executable'

if docker run --rm --network none "$image" --cloud-provider=unsupported >/dev/null 2>&1; then
  fail 'unsupported cloud provider unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
