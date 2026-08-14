#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = 'null' ] || fail 'unexpected command'

help=$(docker run --rm --network none --read-only --user 65532 "$image" --help 2>&1) || fail '/manager --help failed'
printf '%s\n' "$help" | grep -Fq 'Usage of /manager:' || fail 'manager help output missing usage'
printf '%s\n' "$help" | grep -Fq -- '-operation value' || fail 'manager help output missing webhook operation flag'

set +e
invalid=$(docker run --rm --network none --read-only --user 65532 "$image" --operation=invalid-webhook 2>&1)
status=$?
set -e
[ "$status" -eq 2 ] || fail "invalid webhook operation exited $status instead of 2"
printf '%s\n' "$invalid" | grep -Fq 'invalid value "invalid-webhook" for flag -operation' \
  || fail 'invalid webhook operation error missing'

printf 'SMOKE PASS image=%s\n' "$image"
