#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/ko-app/controller"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage of /ko-app/controller:' "$work/help" >/dev/null ||
  fail 'controller help is missing usage text'
grep -F -- '-threads-per-controller' "$work/help" >/dev/null ||
  fail 'controller help is missing Tekton flags'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" --kube-api-qps=invalid \
  >"$work/kubernetes-flags" 2>&1; then
  fail 'invalid Kubernetes flags unexpectedly succeeded'
fi
grep -F 'invalid value "invalid" for flag -kube-api-qps' "$work/kubernetes-flags" >/dev/null ||
  fail 'invalid Kubernetes flags diagnostic is missing'

if docker run --rm --network none --read-only "$image" \
  --kubeconfig=/definitely-missing >"$work/kubeconfig" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'stat /definitely-missing: no such file or directory' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
