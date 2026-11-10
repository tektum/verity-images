#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
name=verity-dex-smoke-$$
label=verity.smoke=dex

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1001 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dex"]' || fail 'unexpected entrypoint'

# Static password connector, in-memory storage.
cat >"$work/config.yaml" <<'CFG'
issuer: http://127.0.0.1:5556/dex
storage:
  type: memory
web:
  http: 0.0.0.0:5556
enablePasswordDB: true
staticPasswords:
  - email: admin@example.com
    hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
    username: admin
    userID: 08a8684b-db88-4b73-90a9-3cd1661f5466
CFG
chmod 644 "$work/config.yaml"

docker run -d --name "$name" --label "$label" --read-only --cap-drop ALL \
  --security-opt no-new-privileges -p 127.0.0.1::5556 -v "$work/config.yaml:/cfg/config.yaml:ro" \
  "$image" serve /cfg/config.yaml >/dev/null

ready=0
base=
i=0
while [ "$i" -lt 60 ]; do
  state=$(docker inspect --format '{{.State.Running}}' "$name")
  [ "$state" = true ] || fail 'dex exited before becoming ready'
  hostport=$(docker port "$name" 5556/tcp 2>/dev/null | head -n 1 || true)
  if [ -n "$hostport" ]; then
    base="http://$hostport"
    if curl -fsS "$base/healthz" >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  i=$((i + 1))
  sleep 1
done
[ "$ready" = 1 ] || fail 'dex did not become ready'

curl -fsS "$base/dex/.well-known/openid-configuration" >"$work/oidc.json" ||
  fail 'discovery request failed'
grep -F '"issuer": "http://127.0.0.1:5556/dex"' "$work/oidc.json" >/dev/null ||
  grep -F '"issuer":"http://127.0.0.1:5556/dex"' "$work/oidc.json" >/dev/null ||
  fail 'discovery document does not contain the configured issuer'
grep -F '/dex/auth' "$work/oidc.json" >/dev/null ||
  fail 'discovery document is missing the authorization endpoint'

docker kill --signal TERM "$name" >/dev/null
code=$(docker wait "$name")
[ "$code" = 0 ] || fail "dex did not exit cleanly on SIGTERM (exit $code)"

# Negative: invalid configuration must fail with a readable error.
printf 'issuer: [unterminated\n' >"$work/bad.yaml"
chmod 644 "$work/bad.yaml"
if docker run --rm --network none --read-only --label "$label" \
  -v "$work/bad.yaml:/cfg/bad.yaml:ro" "$image" serve /cfg/bad.yaml \
  >"$work/bad.out" 2>&1; then
  fail 'invalid config unexpectedly succeeded'
fi
grep -i -e 'error' -e 'failed' "$work/bad.out" >/dev/null ||
  fail 'invalid config diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
