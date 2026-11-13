#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
version=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
commit=$(sed -n 's/^  source-commit: \([0-9a-f]\{40\}\)$/\1/p' "$here/../melange.yaml")
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the package version'
[ -n "$commit" ] || fail 'could not read the source commit'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/trivy-operator"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'

# run LOG ENV... exits non-zero within the timeout or fails the test; the
# operator has no CLI flags, it is configured through OPERATOR_* variables.
run() {
  log=$1
  shift
  rc=0
  timeout 120 docker run --rm --network none --read-only --cap-drop=ALL \
    -v "$work/cfg:/cfg:ro" "$@" "$image" >"$work/$log" 2>&1 || rc=$?
  test "$rc" -ne 124 || fail "$log: operator hung instead of exiting"
  test "$rc" -ne 0 || fail "$log: operator unexpectedly exited 0"
  grep -F 'panic:' "$work/$log" >/dev/null && fail "$log: operator panicked: $(cat "$work/$log")"
  grep -F '"msg":"Starting operator"' "$work/$log" |
    grep -F "\"buildInfo\":{\"Version\":\"$version\",\"Commit\":\"$commit\"" >/dev/null ||
    fail "$log: build info does not carry $version and $commit: $(cat "$work/$log")"
}

mkdir -p "$work/cfg"
cat >"$work/cfg/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: unreachable
    cluster:
      server: https://127.0.0.1:1
      insecure-skip-tls-verify: true
contexts:
  - name: unreachable
    context:
      cluster: unreachable
      user: smoke
current-context: unreachable
users:
  - name: smoke
    user:
      token: smoke
EOF
chmod 0755 "$work/cfg"
chmod 0644 "$work/cfg/kubeconfig"

# Negative: the operator namespace is mandatory.
run no-namespace
grep -Fx 'unable to run trivy operator: resolving install mode: OPERATOR_NAMESPACE must be set' \
  "$work/no-namespace" >/dev/null || fail "missing namespace diagnostic: $(cat "$work/no-namespace")"

# Negative: outside a cluster and without a kubeconfig it reports the missing
# client configuration and exits instead of crash looping.
run no-cluster -e OPERATOR_NAMESPACE=trivy-system
grep -F '"install mode":"AllNamespaces"' "$work/no-cluster" >/dev/null ||
  fail 'default install mode is not AllNamespaces'
grep -F 'unable to run trivy operator: getting kube client config:' "$work/no-cluster" >/dev/null ||
  fail "missing client config diagnostic: $(cat "$work/no-cluster")"

# With a kubeconfig and a target namespace it resolves single-namespace mode,
# builds its client and makes its first API call (reading its own ConfigMap)
# against the configured server, then reports the refused connection.
run unreachable -e OPERATOR_NAMESPACE=trivy-system -e OPERATOR_TARGET_NAMESPACES=apps \
  -e KUBECONFIG=/cfg/kubeconfig
grep -F '"install mode":"SingleNamespace"' "$work/unreachable" >/dev/null ||
  fail 'target namespace did not select SingleNamespace mode'
grep -F '"target namespaces":["apps"]' "$work/unreachable" >/dev/null ||
  fail 'target namespace was not applied'
grep -F 'failed getting configmap: trivy-operator: Get "https://127.0.0.1:1/api/v1/namespaces/trivy-system/configmaps/trivy-operator"' \
  "$work/unreachable" >/dev/null || fail "first API call was not made: $(cat "$work/unreachable")"
grep -F 'connection refused' "$work/unreachable" >/dev/null ||
  fail 'refused connection was not reported'

echo 'SMOKE PASS'
