#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
fixture_index='docker.io/curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
container="verity-spicedb-test-$$"
# Throwaway credential for this test container only.
key="verity-smoke-$$-$(date +%s)"

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the fixture by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") ||
  fail 'cannot inspect fixture image index'
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail 'fixture image index digest mismatch'
fixture_digest=$(printf '%s' "$fixture_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve fixture image digest'
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch fixture image in $fixture_index" ;;
esac
fixture=docker.io/curlimages/curl@$fixture_digest
docker pull --quiet --platform "linux/$image_arch" "$fixture" >/dev/null ||
  fail 'cannot pull fixture image'

# api PATH JSON [KEY]: POST to the HTTP gateway, print "<status> <body>".
api() {
  docker run --rm --network "container:$container" "$fixture" \
    -sS -w '\n%{http_code}' -X POST \
    -H "Authorization: Bearer ${3:-$key}" -H 'Content-Type: application/json' \
    --data "$2" "http://127.0.0.1:8443$1"
}

# OCI contract.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532:65532 ] ||
  fail 'image user is not 65532:65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/spicedb"]' ] ||
  fail 'unexpected image entrypoint'

# Version: the binary reports the pinned upstream release.
version_out=$(docker run --rm "$image" version) || fail 'spicedb version failed'
[ "$version_out" = "spicedb v$expected_version" ] ||
  fail "unexpected version output: $version_out (want spicedb v$expected_version)"

# No shell in the runtime image.
if docker run --rm --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1; then
  fail 'image unexpectedly contains /bin/sh'
fi

# Serve with the in-memory datastore, a preshared key and the HTTP gateway.
docker run -d --name "$container" "$image" serve \
  --grpc-preshared-key "$key" --datastore-engine memory \
  --http-enabled --http-addr :8443 >/dev/null || fail 'cannot start spicedb'

ready=
for _ in $(seq 1 60); do
  if docker run --rm --network "container:$container" "$fixture" \
    -fsS http://127.0.0.1:8443/healthz >/dev/null 2>&1; then
    ready=1
    break
  fi
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'spicedb exited during startup'
  sleep 1
done
[ -n "$ready" ] || fail 'spicedb HTTP gateway did not become healthy'

# The server process runs as the non-root image user.
uid=$(docker top "$container" -o pid,uid,comm | awk '$3 == "spicedb" { print $2 }')
[ "$uid" = 65532 ] || fail "spicedb process uid is '$uid', want 65532"

# The preshared key is enforced.
resp=$(api /v1/schema/read '{}' wrong-key)
wrong_status=$(printf '%s\n' "$resp" | tail -n 1)
wrong_code=$(printf '%s\n' "$resp" | sed '$d' | jq -r '.code')
if [ "$wrong_status" != 403 ] || [ "$wrong_code" != 7 ] ||
  ! printf '%s\n' "$resp" | grep -F 'invalid preshared key' >/dev/null; then
  fail "request with a wrong key was not rejected: $resp"
fi

schema='definition user {}

definition document {
  relation viewer: user
  relation editor: user
  permission view = viewer + editor
  permission edit = editor
}'
resp=$(api /v1/schema/write "$(jq -cn --arg s "$schema" '{schema: $s}')")
[ "$(printf '%s\n' "$resp" | tail -n 1)" = 200 ] || fail "schema write failed: $resp"

resp=$(api /v1/schema/read '{}')
[ "$(printf '%s\n' "$resp" | tail -n 1)" = 200 ] || fail "schema read failed: $resp"
printf '%s\n' "$resp" | sed '$d' | jq -er '.schemaText' | grep -F 'permission view = viewer + editor' >/dev/null ||
  fail "schema did not round-trip: $resp"

resp=$(api /v1/relationships/write '{"updates":[{"operation":"OPERATION_TOUCH","relationship":{
  "resource":{"objectType":"document","objectId":"readme"},"relation":"viewer",
  "subject":{"object":{"objectType":"user","objectId":"alice"}}}}]}')
[ "$(printf '%s\n' "$resp" | tail -n 1)" = 200 ] || fail "relationship write failed: $resp"
printf '%s\n' "$resp" | sed '$d' | jq -er '.writtenAt.token' >/dev/null ||
  fail "relationship write returned no zedtoken: $resp"

# check SUBJECT PERMISSION: print the permissionship.
check() {
  body=$(jq -cn --arg s "$1" --arg p "$2" '{
    consistency: {fullyConsistent: true},
    resource: {objectType: "document", objectId: "readme"},
    permission: $p,
    subject: {object: {objectType: "user", objectId: $s}}}')
  out=$(api /v1/permissions/check "$body")
  [ "$(printf '%s\n' "$out" | tail -n 1)" = 200 ] || fail "check $1 $2 failed: $out"
  printf '%s\n' "$out" | sed '$d' | jq -er '.permissionship'
}

[ "$(check alice view)" = PERMISSIONSHIP_HAS_PERMISSION ] || fail 'alice cannot view readme'
[ "$(check alice edit)" = PERMISSIONSHIP_NO_PERMISSION ] || fail 'viewer alice can edit readme'
[ "$(check bob view)" = PERMISSIONSHIP_NO_PERMISSION ] || fail 'unrelated bob can view readme'

# An unknown permission is rejected rather than answered.
resp=$(api /v1/permissions/check '{"consistency":{"fullyConsistent":true},
  "resource":{"objectType":"document","objectId":"readme"},"permission":"delete",
  "subject":{"object":{"objectType":"user","objectId":"alice"}}}')
[ "$(printf '%s\n' "$resp" | tail -n 1)" = 400 ] || fail "unknown permission was not rejected: $resp"

docker stop -t 20 "$container" >/dev/null || fail 'cannot stop spicedb'
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'spicedb did not exit cleanly on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"
