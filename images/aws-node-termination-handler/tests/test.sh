#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'unexpected image user'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/node-termination-handler"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] \
  || fail 'unexpected image command'

docker run --rm --network none "$image" -h 2>&1 | grep -F -- '-enable-sqs-termination-draining' >/dev/null \
  || fail 'help did not list the SQS termination draining flag'

if output=$(docker run --rm --network none "$image" --no-such-flag 2>&1); then
  fail 'unknown flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'flag provided but not defined' >/dev/null \
  || fail 'unknown flag did not report the expected error'

if output=$(docker run --rm --network none "$image" 2>&1); then
  fail 'handler unexpectedly started without a node name'
fi
printf '%s\n' "$output" | grep -F 'You must provide a node-name' >/dev/null \
  || fail 'missing node name did not report the expected error'

if output=$(docker run --rm --network none "$image" --node-name=smoke 2>&1); then
  fail 'handler unexpectedly started without a cluster'
fi
printf '%s\n' "$output" | grep -F 'unable to load in-cluster configuration' >/dev/null \
  || fail 'missing cluster did not report the expected configuration error'

printf 'SMOKE PASS image=%s\n' "$image"
