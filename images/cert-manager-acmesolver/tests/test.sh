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
  '["/app/cmd/acmesolver/acmesolver"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

docker run --rm --network none --read-only "$image" --help >"$work/help" 2>&1
grep -F 'Usage:' "$work/help" >/dev/null || fail 'acmesolver help is missing usage text'

if docker run --rm --network none --read-only "$image" --definitely-invalid \
  >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

grep -F -e '--domain string' -e '--token string' -e '--key string' "$work/help" >/dev/null ||
  fail 'acmesolver challenge flags are missing'

cid=$(docker run -d --read-only -p 127.0.0.1::8089 "$image" \
  --domain=example.test --token=smoke-token --key=smoke-token.smoke-key)
port=$(docker port "$cid" 8089/tcp | sed -n 's/^127\.0\.0\.1://p')
test -n "$port" || fail 'challenge port was not published'

body=
i=0
while [ "$i" -lt 30 ]; do
  if body=$(curl -fsS -H 'Host: example.test' \
    "http://127.0.0.1:$port/.well-known/acme-challenge/smoke-token" 2>/dev/null); then
    break
  fi
  body=
  i=$((i + 1))
  sleep 1
done
test "$body" = 'smoke-token.smoke-key' || fail 'challenge response is wrong'

code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: example.test' \
  "http://127.0.0.1:$port/.well-known/acme-challenge/other-token" || true)
test "$code" = 404 || fail "wrong token returned HTTP $code instead of 404"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: other.test' \
  "http://127.0.0.1:$port/.well-known/acme-challenge/smoke-token" || true)
test "$code" = 404 || fail "wrong host returned HTTP $code instead of 404"

printf 'SMOKE PASS image=%s\n' "$image"
