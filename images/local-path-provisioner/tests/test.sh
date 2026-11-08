#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail 'image must run as root to create volume directories'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/local-path-provisioner"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ] \
  || fail 'unexpected image command'

docker run --rm --network none "$image" --version 2>&1 \
  | grep -E 'version 0\.0\.[0-9]+' >/dev/null \
  || fail 'version output did not report a 0.0 release'
docker run --rm --network none "$image" --help 2>&1 | grep -F 'start' >/dev/null \
  || fail 'help did not list the start command'
docker run --rm --network none --entrypoint /bin/sh "$image" -c \
  'test -x /usr/bin/local-path-provisioner && test -x /bin/sh' \
  || fail 'binary or helper shell is missing'

if output=$(docker run --rm --network none "$image" start 2>&1); then
  fail 'provisioner unexpectedly started without a cluster'
fi
printf '%s\n' "$output" | grep -F 'unable to get client config' >/dev/null \
  || fail 'missing cluster did not report the expected client config error'

if output=$(docker run --rm --network none "$image" start --kubeconfig /tmp/missing.kubeconfig 2>&1); then
  fail 'provisioner unexpectedly started with a missing explicit kubeconfig'
fi
printf '%s\n' "$output" | grep -F '/tmp/missing.kubeconfig' >/dev/null \
  || fail 'provisioner ignored the explicit kubeconfig path'

if docker run --rm --network none "$image" no-such-command >/dev/null 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
