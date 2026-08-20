#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ -z "$user" ] || [ "$user" = 0 ] || fail "unexpected image user: $user"
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = / ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["argoexec"]' ] \
  || fail 'unexpected image entrypoint'

version_output=$(docker run --rm --cpus=4 --network none "$image" version 2>&1)
printf '%s\n' "$version_output" | grep -F "argoexec: v${IMAGE_VERSION}+" >/dev/null \
  || fail 'argoexec version check failed'
printf '%s\n' "$version_output" | grep -F 'GitTreeState: dirty' >/dev/null \
  || fail 'argoexec did not disclose the dependency-remediated build'

if ! output=$(docker run --rm --cpus=4 --network none "$image" 2>&1); then
  printf '%s\n' "$output" >&2
  fail 'missing workflow command did not preserve upstream help behavior'
fi
printf '%s\n' "$output" | grep -F 'argoexec is the executor sidecar to workflow containers' >/dev/null \
  || fail 'missing workflow command did not print argoexec help'

if output=$(docker run --rm --cpus=4 --network none "$image" not-a-workflow-command 2>&1); then
  fail 'invalid workflow command unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown command "not-a-workflow-command" for "argoexec"' >/dev/null \
  || fail 'invalid workflow command did not report the expected error'

printf 'SMOKE PASS image=%s\n' "$image"
