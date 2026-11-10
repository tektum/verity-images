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
  '["/ko-app/webhook"]' || fail 'unexpected entrypoint'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

run() {
  docker run --rm --network none --read-only --cpus 2 --memory 512m --pids-limit 256 \
    -e SYSTEM_NAMESPACE=tekton-pipelines "$@"
}

run "$image" --help >"$work/help" 2>&1
grep -F 'Usage of /ko-app/webhook:' "$work/help" >/dev/null ||
  fail 'webhook help is missing usage text'
grep -F -- '-disable-ha' "$work/help" >/dev/null ||
  fail 'webhook help is missing Knative flags'
grep -F -- '-kubeconfig' "$work/help" >/dev/null ||
  fail 'webhook help is missing Kubernetes flags'

if run "$image" --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if run "$image" --kubeconfig=/definitely-missing >"$work/kubeconfig" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'stat /definitely-missing: no such file or directory' "$work/kubeconfig" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

if docker run --rm --network none --read-only "$image" >"$work/nonamespace" 2>&1; then
  fail 'start without SYSTEM_NAMESPACE unexpectedly succeeded'
fi
grep -F 'The environment variable "SYSTEM_NAMESPACE" is not set' "$work/nonamespace" >/dev/null ||
  fail 'missing SYSTEM_NAMESPACE diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
