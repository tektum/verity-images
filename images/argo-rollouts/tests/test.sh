#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none --cpus 4 --memory 1g --pids-limit 256 "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 999 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /home/argo-rollouts ] \
  || fail 'unexpected working directory'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rollouts-controller"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

version_output=$(run "$image" --version 2>&1) || fail 'rollouts-controller --version failed'
printf '%s\n' "$version_output" | grep -E "^v${expected_version}\+[0-9a-f]{7}\.dirty$" >/dev/null \
  || fail "unexpected version output: $version_output"

help_output=$(run "$image" --help 2>&1) || fail 'rollouts-controller --help failed'
for flag in --namespaced --leader-elect --metricsPort --healthzPort --kubeconfig; do
  printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null || fail "help is missing $flag"
done

if output=$(run "$image" 2>&1); then
  fail 'controller started without Kubernetes credentials'
fi
printf '%s\n' "$output" | grep -F 'invalid configuration: no configuration has been provided' >/dev/null \
  || fail "missing Kubernetes credentials did not report a configuration error: $output"

if output=$(run "$image" --kubeconfig /tmp/missing 2>&1); then
  fail 'controller started with a missing kubeconfig'
fi
printf '%s\n' "$output" | grep -F '/tmp/missing' >/dev/null \
  || fail "missing kubeconfig path was not reported: $output"

if output=$(run "$image" --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown flag: --not-a-real-flag' >/dev/null \
  || fail "invalid flag diagnostic missing: $output"

printf 'SMOKE PASS image=%s\n' "$image"
