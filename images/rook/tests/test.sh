#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/local/bin/rook"]' ] \
  || fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

run() {
  docker run --rm --network none --read-only --user 65534 \
    --cpus 2 --memory 1g --pids-limit 256 "$@"
}

version_output=$(run "$image" version 2>&1) || fail 'rook version failed'
printf '%s\n' "$version_output" | grep -Ex 'rook: v1\.21\.[0-9]+' >/dev/null \
  || { printf '%s\n' "$version_output" >&2; fail 'rook version output unexpected'; }

help_output=$(run "$image" ceph --help 2>&1) || fail 'rook ceph --help failed'
printf '%s\n' "$help_output" | grep -F 'operator' >/dev/null || fail 'operator subcommand missing'

# Negative: an unknown subcommand exits non-zero with a diagnostic.
status=0
output=$(run "$image" nosuchcommand 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'unknown subcommand unexpectedly succeeded'
printf '%s\n' "$output" | grep -F 'unknown command "nosuchcommand"' >/dev/null \
  || fail 'unknown subcommand diagnostic missing'

# Negative: the operator needs a Kubernetes cluster and must fail clearly without one.
status=0
output=$(run "$image" ceph operator 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'operator without a cluster unexpectedly succeeded'
printf '%s\n' "$output" | grep -F 'failed to get k8s cluster config' >/dev/null \
  || { printf '%s\n' "$output" >&2; fail 'operator missing-cluster diagnostic missing'; }

printf 'SMOKE PASS image=%s\n' "$image"
