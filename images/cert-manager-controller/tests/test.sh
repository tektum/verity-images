#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
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
  '["/app/cmd/controller/controller"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage:' "$work/help" >/dev/null || fail 'controller help is missing usage text'
grep -F "cert-manager-acmesolver:v${IMAGE_VERSION}" "$work/help" >/dev/null ||
  fail 'controller version is not embedded in defaults'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

if docker run --rm --network none --read-only "$image" \
  --kubeconfig=/definitely-missing --v=2 >"$work/startup" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F "version=\"v${IMAGE_VERSION}\"" "$work/startup" >/dev/null ||
  fail 'startup version log is missing'
grep -F 'git_commit="60b0447cc9a64885d42567ea590862b88a62d1ad"' \
  "$work/startup" >/dev/null || fail 'startup commit log is missing'
grep -F 'open /definitely-missing: no such file or directory' "$work/startup" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
