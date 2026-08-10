#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail "unexpected image user: $user"
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/bin/external-dns"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] \
  || fail 'unexpected image command'

docker run --rm "$image" --help 2>&1 | grep -F -- '--provider=provider' >/dev/null \
  || fail 'help did not list the required provider flag'

if output=$(docker run --rm "$image" --provider=not-a-provider 2>&1); then
  fail 'unknown provider unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F "got 'not-a-provider'" >/dev/null \
  || fail 'unknown provider did not report the expected error'

if output=$(docker run --rm "$image" --provider=aws --interval=not-a-duration 2>&1); then
  fail 'invalid interval unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'time: invalid duration' >/dev/null \
  || fail 'invalid interval did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
