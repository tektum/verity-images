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
  '["/usr/bin/step-issuer"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

# Go's flag package exits 0 for -h and prints every registered flag.
docker run --rm --network none --read-only "$image" -h >"$work/help" 2>&1 ||
  fail 'help exited non-zero'
for flag in -disable-approval-check -enable-leader-election -leader-election-id \
  -metrics-bind-address -kubeconfig -zap-log-level; do
  grep -F -- "$flag" "$work/help" >/dev/null || fail "help is missing $flag"
done

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Offline startup: the manager must reach client config loading and fail on
# the missing kubeconfig rather than crash earlier.
if docker run --rm --network none --read-only "$image" \
  --kubeconfig=/definitely-missing >"$work/startup" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F '"msg":"unable to get kubeconfig"' "$work/startup" >/dev/null ||
  fail 'kubeconfig load error is missing'
grep -F 'stat /definitely-missing: no such file or directory' "$work/startup" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'


printf 'SMOKE PASS image=%s\n' "$image"
