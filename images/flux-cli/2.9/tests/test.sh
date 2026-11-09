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
  docker run --rm --network none --cpus 2 --memory 512m --pids-limit 256 "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/flux"]' ] \
  || fail 'unexpected entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) fail 'unexpected image command' ;; esac

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
version_output=$(run "$image" version --client) || fail 'flux version --client failed'
[ "$version_output" = "flux: v$expected_version" ] || fail "unexpected version output: $version_output"

manifests=$(run "$image" install --export --components source-controller 2>&1) \
  || fail "flux install --export failed: $manifests"
for want in 'kind: Deployment' 'name: source-controller' 'ghcr.io/fluxcd/source-controller:v' \
  'kind: CustomResourceDefinition'; do
  printf '%s\n' "$manifests" | grep -F -- "$want" >/dev/null || fail "embedded manifests are missing: $want"
done

source=$(run "$image" create source git podinfo --url=https://github.com/stefanprodan/podinfo \
  --branch=master --namespace=flux-system --export 2>&1) || fail "flux create source git --export failed: $source"
for want in 'kind: GitRepository' 'name: podinfo' 'url: https://github.com/stefanprodan/podinfo' 'branch: master'; do
  printf '%s\n' "$source" | grep -F -- "$want" >/dev/null || fail "generated GitRepository is missing: $want"
done

if output=$(run -e KUBECONFIG=/tmp/missing "$image" check --pre 2>&1); then
  fail 'flux check --pre unexpectedly succeeded without a cluster'
fi
printf '%s\n' "$output" | grep -F 'Kubernetes API call failed' >/dev/null \
  || fail "flux check --pre did not report a cluster configuration error: $output"

if output=$(run "$image" version --client --not-a-real-flag 2>&1); then
  fail 'invalid flag unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -F 'unknown flag: --not-a-real-flag' >/dev/null \
  || fail "invalid flag diagnostic missing: $output"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
