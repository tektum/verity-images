#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - openfga=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
container="verity-openfga-test-$$"
work=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned openfga version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/openfga"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["run"]' ||
  fail 'unexpected command'

docker run --rm --network none "$image" version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -F "OpenFGA version \`v$version\`" "$work/version" >/dev/null ||
  fail "version does not report v$version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

rc=0
docker run --rm --network none "$image" run --datastore-engine bogus >"$work/engine" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'unsupported datastore engine unexpectedly started'
grep -F "storage engine 'bogus' is unsupported" "$work/engine" >/dev/null ||
  fail 'unsupported datastore diagnostic is missing'

# Default command: the server with the in-memory datastore, read-only root.
docker run -d --name "$container" --read-only --cap-drop=ALL \
  -p 127.0.0.1::8080 -p 127.0.0.1::8081 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$port" ] || fail 'http port is not published'
api="http://127.0.0.1:$port"

i=0
until health=$(curl --fail --silent --connect-timeout 1 --max-time 5 "$api/healthz"); do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    docker logs "$container" >&2 || true
    fail 'server did not become healthy'
  fi
  sleep 1
done
printf '%s' "$health" | grep -F '"status":"SERVING"' >/dev/null ||
  fail "unexpected health response: $health"

post() {
  curl --fail-with-body --silent --show-error --max-time 10 \
    -H 'Content-Type: application/json' -d "$2" "$api$1"
}

store=$(post /stores '{"name":"verity-smoke"}') || fail "create store failed: $store"
store_id=$(printf '%s' "$store" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])') ||
  fail "store response has no id: $store"

model=$(post "/stores/$store_id/authorization-models" '{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {
      "type": "document",
      "relations": {"viewer": {"this": {}}},
      "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}
    }
  ]
}') || fail "write authorization model failed: $model"
model_id=$(printf '%s' "$model" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["authorization_model_id"])') ||
  fail "model response has no id: $model"

out=$(post "/stores/$store_id/write" "{
  \"authorization_model_id\": \"$model_id\",
  \"writes\": {\"tuple_keys\": [
    {\"user\": \"user:anne\", \"relation\": \"viewer\", \"object\": \"document:roadmap\"}
  ]}
}") || fail "write tuple failed: $out"

check() {
  post "/stores/$store_id/check" "{
    \"authorization_model_id\": \"$model_id\",
    \"tuple_key\": {\"user\": \"$1\", \"relation\": \"viewer\", \"object\": \"document:roadmap\"}
  }"
}
allowed=$(check user:anne) || fail "check for anne failed: $allowed"
printf '%s' "$allowed" | grep -F '"allowed":true' >/dev/null ||
  fail "anne is not allowed: $allowed"
denied=$(check user:bob) || fail "check for bob failed: $denied"
printf '%s' "$denied" | grep -F '"allowed":false' >/dev/null ||
  fail "bob is unexpectedly allowed: $denied"

# A model that references an undefined type is rejected with a validation error.
rc=0
bad=$(post "/stores/$store_id/authorization-models" '{
  "schema_version": "1.1",
  "type_definitions": [
    {
      "type": "document",
      "relations": {"viewer": {"this": {}}},
      "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "nosuchtype"}]}}}
    }
  ]
}' 2>/dev/null) || rc=$?
test "$rc" -ne 0 || fail 'invalid authorization model was accepted'
printf '%s' "$bad" | grep -F 'nosuchtype' >/dev/null ||
  fail "invalid model diagnostic does not name the type: $bad"

docker stop -t 15 "$container" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
test "$code" = 0 || fail "server exit code $code after SIGTERM"
docker logs "$container" >"$work/server.log" 2>&1
grep -F 'graceful shutdown completed successfully' "$work/server.log" >/dev/null ||
  fail 'server did not report a graceful shutdown'

printf 'SMOKE PASS image=%s\n' "$image"
