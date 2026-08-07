#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/manager"]' ] || fail 'unexpected entrypoint'

docker run --rm --network none --user 65532 "$image" --help >/dev/null || fail '/usr/bin/manager is not executable'
docker run --rm --network none --user 65532 --entrypoint /manager "$image" --help >/dev/null || fail '/manager is not executable'

if docker run --rm --network none --user 65532 "$image" --not-a-real-flag >/dev/null 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
