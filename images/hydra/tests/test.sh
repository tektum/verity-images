#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-hydra-test-$$"
tmp=$(mktemp -d)
chmod 777 "$tmp"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

hydra() {
  docker run --rm -v "$tmp:/data" \
    -e DSN='sqlite:///data/h.db?_fk=true' "$image" "$@"
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/hydra"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["serve","all"]' ] ||
  fail 'unexpected image config: Cmd'
docker run --rm "$image" version | grep -F "v$expected_version" >/dev/null ||
  fail "version output does not report v$expected_version"

hydra migrate sql up -e --yes >"$tmp/migrate.log" 2>&1 || {
  cat "$tmp/migrate.log" >&2
  fail 'hydra migrate sql failed'
}

start() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
    -v "$tmp:/data" \
    -e DSN='sqlite:///data/h.db?_fk=true' \
    -e SECRETS_SYSTEM=verity-smoke-system-secret-0123456789 \
    -e URLS_SELF_ISSUER=http://127.0.0.1:4444 \
    -e URLS_LOGIN=http://127.0.0.1:3000/login \
    -e URLS_CONSENT=http://127.0.0.1:3000/consent \
    -p 127.0.0.1::4444 -p 127.0.0.1::4445 \
    "$image" serve all --dev --sqa-opt-out >/dev/null
  public=$(docker port "$container" 4444/tcp | awk -F: 'NR == 1 { print $2 }')
  admin=$(docker port "$container" 4445/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$public" ] || fail 'no published host port for 4444'
  [ -n "$admin" ] || fail 'no published host port for 4445'
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$admin/health/ready" >"$tmp/ready.json"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 120 ] || fail 'hydra did not become ready'
    sleep 1
  done
  # The public listener can come up after the admin one, notably under emulation.
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$public/.well-known/openid-configuration" >"$tmp/oidc.json"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 120 ] || fail 'hydra public listener did not become ready'
    sleep 1
  done
}

start
grep -F '"status":"ok"' "$tmp/ready.json" >/dev/null || fail 'readiness body is not ok'
[ "$(jq -r .issuer "$tmp/oidc.json")" = 'http://127.0.0.1:4444' ] || fail 'unexpected issuer'
jq -e '.jwks_uri and .token_endpoint' "$tmp/oidc.json" >/dev/null || fail 'discovery document incomplete'

curl --fail --silent -X POST "http://127.0.0.1:$admin/admin/clients" \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"verity-smoke","grant_types":["client_credentials"],"token_endpoint_auth_method":"client_secret_post","client_secret":"verity-smoke-client-secret"}' \
  >/dev/null || fail 'client creation failed'
curl --fail --silent -X POST "http://127.0.0.1:$public/oauth2/token" \
  -d grant_type=client_credentials -d client_id=verity-smoke \
  -d client_secret=verity-smoke-client-secret >"$tmp/token.json" || fail 'client_credentials grant failed'
jq -e '.access_token' "$tmp/token.json" >/dev/null || fail 'token response has no access_token'

# State must survive a restart from the migrated database.
docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail 'hydra did not exit cleanly on SIGTERM'
start
curl --fail --silent --show-error "http://127.0.0.1:$admin/admin/clients/verity-smoke" >"$tmp/client.json" ||
  fail 'client missing after restart'
[ "$(jq -r .client_id "$tmp/client.json")" = verity-smoke ] || fail 'client not persisted'

if docker run --rm "$image" serve all >"$tmp/invalid.log" 2>&1; then
  printf '%s\n' 'serve without a DSN unexpectedly succeeded' >&2
  exit 1
fi
grep -qi 'dsn' "$tmp/invalid.log" || {
  cat "$tmp/invalid.log" >&2
  fail 'missing DSN error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
