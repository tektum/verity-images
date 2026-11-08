#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-kratos-test-$$"
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

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/kratos"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["serve"]' ] ||
  fail 'unexpected image config: Cmd'
docker run --rm "$image" version | grep -F "v$expected_version" >/dev/null ||
  fail "version output does not report v$expected_version"

cat >"$tmp/identity.schema.json" <<'JSON'
{
  "$id": "https://example.test/identity.schema.json",
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "traits": {
      "type": "object",
      "properties": {
        "email": {
          "type": "string",
          "format": "email",
          "ory.sh/kratos": { "credentials": { "password": { "identifier": true } } }
        }
      },
      "required": ["email"],
      "additionalProperties": false
    }
  }
}
JSON
cat >"$tmp/kratos.yml" <<'YAML'
dsn: sqlite:///data/k.db?_fk=true
serve:
  public:
    host: 0.0.0.0
    base_url: http://127.0.0.1:4433/
  admin:
    host: 0.0.0.0
    base_url: http://127.0.0.1:4434/
selfservice:
  default_browser_return_url: http://127.0.0.1:4455/
  flows:
    error:
      ui_url: http://127.0.0.1:4455/error
    login:
      ui_url: http://127.0.0.1:4455/login
    registration:
      ui_url: http://127.0.0.1:4455/registration
  methods:
    password:
      enabled: true
identity:
  default_schema_id: default
  schemas:
    - id: default
      url: file:///data/identity.schema.json
secrets:
  cookie:
    - verity-smoke-cookie-secret-0123456789
  cipher:
    - verity-smoke-cipher-secret-01234
YAML

docker run --rm -v "$tmp:/data" "$image" migrate sql -e --yes -c /data/kratos.yml \
  >"$tmp/migrate.log" 2>&1 || {
  cat "$tmp/migrate.log" >&2
  fail 'kratos migrate sql failed'
}

start() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --name "$container" -d --read-only --tmpfs /tmp:uid=65532,gid=65532 \
    -v "$tmp:/data" -p 127.0.0.1::4433 -p 127.0.0.1::4434 \
    "$image" serve -c /data/kratos.yml >/dev/null
  public=$(docker port "$container" 4433/tcp | awk -F: 'NR == 1 { print $2 }')
  admin=$(docker port "$container" 4434/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$public" ] || fail 'no published host port for 4433'
  [ -n "$admin" ] || fail 'no published host port for 4434'
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$admin/health/ready" >"$tmp/ready.json"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 120 ] || fail 'kratos admin listener did not become ready'
    sleep 1
  done
  # The public listener can come up after the admin one, notably under emulation.
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$public/health/ready" >"$tmp/public-ready.json"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 120 ] || fail 'kratos public listener did not become ready'
    sleep 1
  done
}

start
grep -F '"status":"ok"' "$tmp/ready.json" >/dev/null || fail 'readiness body is not ok'

curl --fail --silent --show-error -X POST "http://127.0.0.1:$admin/admin/identities" \
  -H 'Content-Type: application/json' \
  -d '{"schema_id":"default","traits":{"email":"smoke@example.test"}}' >"$tmp/identity.json" ||
  fail 'identity creation failed'
id=$(jq -r .id "$tmp/identity.json")
[ -n "$id" ] && [ "$id" != null ] || fail 'created identity has no id'

curl --fail --silent --show-error "http://127.0.0.1:$public/self-service/registration/api" \
  >"$tmp/flow.json" || fail 'registration flow initialisation failed'
jq -e '.ui.nodes | length > 0' "$tmp/flow.json" >/dev/null || fail 'registration flow has no UI nodes'

# State must survive a restart from the migrated database.
docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail 'kratos did not exit cleanly on SIGTERM'
start
curl --fail --silent --show-error "http://127.0.0.1:$admin/admin/identities" >"$tmp/list.json" ||
  fail 'identity listing failed after restart'
[ "$(jq -r --arg id "$id" '[.[]|select(.id==$id)]|length' "$tmp/list.json")" = 1 ] ||
  fail 'identity not persisted across restart'

if docker run --rm -v "$tmp:/data" "$image" serve -c /data/missing.yml >"$tmp/invalid.log" 2>&1; then
  printf '%s\n' 'serve with a missing config unexpectedly succeeded' >&2
  exit 1
fi
grep -qi 'missing.yml' "$tmp/invalid.log" || {
  cat "$tmp/invalid.log" >&2
  fail 'missing config error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
