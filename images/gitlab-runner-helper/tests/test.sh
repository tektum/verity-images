#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail 'image must run as root for executor volume compatibility'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dumb-init","--","/entrypoint"]' ] \
  || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/bin/bash"]' ] \
  || fail 'unexpected image command'

docker run --rm --network none "$image" \
  test -x /usr/bin/gitlab-runner-helper -a -x /usr/bin/gitlab-runner-build -a -x /usr/bin/git \
  || fail 'required helper files are missing'

docker run --rm --network none "$image" gitlab-runner-helper --version 2>&1 \
  | grep -E '^Version:[[:space:]]+v19\.3\.[0-9]+' >/dev/null \
  || fail 'helper version check failed'
docker run --rm --network none "$image" gitlab-runner-helper cache-archiver --help 2>&1 \
  | grep -F 'cache-archiver' >/dev/null \
  || fail 'cache-archiver help check failed'
docker run --rm --network none "$image" git --version | grep -F 'git version' >/dev/null \
  || fail 'git is missing'
docker run --rm --network none "$image" git lfs version | grep -F 'git-lfs/' >/dev/null \
  || fail 'git-lfs is missing'

if output=$(docker run --rm --network none "$image" gitlab-runner-helper health-check 2>&1); then
  fail 'health-check unexpectedly succeeded without an address'
fi
printf '%s\n' "$output" | grep -F 'No HOST or PORT found' >/dev/null \
  || fail 'health-check did not report the missing address'

if docker run --rm --network none "$image" gitlab-runner-helper no-such-command >/dev/null 2>&1; then
  fail 'unknown helper command unexpectedly succeeded'
fi

# The entrypoint execs its arguments.
docker run --rm --network none "$image" sh -c 'printf entrypoint-ok' | grep -F entrypoint-ok >/dev/null \
  || fail 'entrypoint did not exec its arguments'
if docker run --rm --network none "$image" /no/such/binary >/dev/null 2>&1; then
  fail 'entrypoint unexpectedly succeeded for a missing command'
fi

printf 'SMOKE PASS image=%s\n' "$image"
