#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(awk -F'"' '/^  version: /{print $2; exit}' "$(dirname "$0")/../melange.yaml")
container="verity-cloudnative-pg-test-$$"
tmp=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

[ -n "$expected_version" ] || fail 'package version not found'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] \
  || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/manager"]' ] \
  || fail 'unexpected image entrypoint'
docker run --rm "$image" version 2>&1 | grep -F "Version:$expected_version " >/dev/null \
  || fail 'manager version check failed'

# Every PostgreSQL pod runs an init container that executes /manager bootstrap
# to copy the instance manager out of the operator image, so the copy must be
# an executable that reports the same version.
chmod 777 "$tmp"
docker run --rm -v "$tmp:/controller" "$image" bootstrap /controller/manager >/dev/null 2>&1 \
  || fail 'manager bootstrap could not copy the instance manager'
docker run --rm --entrypoint /controller/manager -v "$tmp:/controller:ro" "$image" version 2>&1 \
  | grep -F "Version:$expected_version " >/dev/null \
  || fail 'copied instance manager did not run'

# Outside a cluster the operator must fail fast with a readable error instead
# of hanging or crash-looping on argument parsing.
if controller=$(docker run --rm "$image" controller 2>&1); then
  fail 'controller unexpectedly started without a Kubernetes API'
fi
printf '%s' "$controller" | grep -Ei 'kubeconfig|in-cluster|KUBERNETES_SERVICE_HOST|unable to|error' >/dev/null \
  || fail 'controller did not return a readable error without a Kubernetes API'

if invalid=$(docker run --rm "$image" no-such-command 2>&1); then
  fail 'invalid command unexpectedly succeeded'
fi
printf '%s' "$invalid" | grep -F 'unknown command' >/dev/null \
  || fail 'invalid command did not return a readable error'

printf 'SMOKE PASS image=%s\n' "$image"
