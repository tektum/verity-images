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

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cert-manager-istio-csr"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# istio-csr has no version flag: upstream's version ldflags target a package
# that no longer exists. Help output proves the binary starts and parses flags.
docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'
grep -F 'cert-manager-istio-csr' "$work/help" >/dev/null || fail 'help is missing command name'
grep -F -- '--issuer-name' "$work/help" >/dev/null || fail 'help is missing issuer flags'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# No cluster: neither in-cluster env nor a kubeconfig is available.
if timeout 60 docker run --rm --network none --read-only "$image" \
  >"$work/nocluster" 2>&1; then
  fail 'startup without a cluster unexpectedly succeeded'
fi
grep -F 'failed to build kubernetes rest config' "$work/nocluster" >/dev/null ||
  fail 'missing cluster diagnostic is missing'

if timeout 60 docker run --rm --network none --read-only "$image" \
  --kubeconfig=/definitely-missing >"$work/kubeconfig" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'failed to build kubernetes rest config' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'
grep -F '/definitely-missing' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig path is not reported'

# An unauthenticated gRPC CreateCertificate probe is not practical offline: the
# server only listens after the controller-runtime manager has connected to a
# Kubernetes API server and loaded the issuer root CA through cert-manager.

printf 'SMOKE PASS image=%s\n' "$image"
