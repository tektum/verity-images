#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)"$/\1/p' "$recipe")
commit=$(sed -n 's/^  source-commit: //p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/cmctl"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

docker run --rm --network none --read-only "$image" version --client >"$work/version" 2>&1 ||
  fail 'version --client failed'
grep -F "v${version}" "$work/version" >/dev/null || fail 'client version is not embedded'
grep -F "$commit" "$work/version" >/dev/null || fail 'client commit is not embedded'

grep -F 'approve' "$work/help" >/dev/null || fail 'approve command is missing'
grep -F 'renew' "$work/help" >/dev/null || fail 'renew command is missing'

if docker run --rm --network none --read-only "$image" status certificate example \
  --kubeconfig=/definitely-missing >"$work/startup" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F '/definitely-missing' "$work/startup" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
