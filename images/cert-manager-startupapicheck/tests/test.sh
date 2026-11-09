#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
cid=

cleanup() {
  if [ -n "$cid" ]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
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
  '["/app/cmd/startupapicheck/startupapicheck"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage:' "$work/help" >/dev/null || fail 'startupapicheck help is missing usage text'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

grep -F 'check' "$work/help" >/dev/null || fail 'check command is missing'

docker run --rm --network none --read-only "$image" check api --help \
  >"$work/apihelp" 2>&1 || fail 'check api help failed'
grep -F 'dry-run create of a cert-manager' "$work/apihelp" >/dev/null ||
  fail 'check api description is missing'

if docker run --rm --network none --read-only "$image" check api \
  --kubeconfig=/definitely-missing --wait=0 >"$work/startup" 2>&1; then
  fail 'missing kubeconfig unexpectedly succeeded'
fi
grep -F 'stat /definitely-missing: no such file or directory' "$work/startup" >/dev/null ||
  fail 'missing kubeconfig diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
