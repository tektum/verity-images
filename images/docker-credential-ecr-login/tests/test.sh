#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

recipe_value() {
  awk -v key="$1" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$here/../melange.yaml"
}
expected_version=$(recipe_value version:)
expected_commit=$(recipe_value source-commit:)
[ -n "$expected_version" ] && [ -n "$expected_commit" ] || fail 'could not read the recipe'

test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/docker-credential-ecr-login"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 || fail 'unexpected OCI user'

# Every run is offline: no network, dummy static credentials, and instance and
# container metadata disabled, so no command can reach AWS.
# The helper creates $HOME/.ecr and its log directory 0700 as the image user;
# pre-create them so this script can read the log and seed the cache.
mkdir -p "$work/home/.ecr/log"
chmod 0777 "$work/home" "$work/home/.ecr" "$work/home/.ecr/log"
helper() {
  docker run --rm -i --network none --read-only --cap-drop=ALL --security-opt no-new-privileges \
    --tmpfs /tmp -v "$work/home:/home/nonroot" \
    -e AWS_ACCESS_KEY_ID=AKIAVERITYSMOKETEST0 -e AWS_SECRET_ACCESS_KEY=verity-smoke-secret \
    -e AWS_EC2_METADATA_DISABLED=true -e AWS_REGION=us-east-1 \
    -e AWS_MAX_ATTEMPTS=1 "$image" "$@"
}

banner=$(helper -v) || fail 'version banner failed'
printf '%s\n' "$banner" | grep -Fx "Version:    $expected_version" >/dev/null ||
  fail "unexpected version banner: $banner"
printf '%s\n' "$banner" | grep -Fx "Git commit: $(printf '%.7s' "$expected_commit")" >/dev/null ||
  fail "unexpected commit in banner: $banner"

test "$(helper version </dev/null)" = \
  "docker-credential-ecr-login (github.com/awslabs/amazon-ecr-credential-helper/ecr-login) $expected_version" ||
  fail 'the protocol version action reported the wrong version'

# Protocol: `get` reads a server URL on stdin. A registry that is not ECR is
# rejected before any AWS client exists, with the standard not-found message
# that tells Docker to continue without credentials.
for host in registry-1.docker.io https://ghcr.io quay.io/v2/; do
  status=0
  printf '%s' "$host" | helper get >"$work/get" 2>&1 || status=$?
  test "$status" = 1 || fail "get $host exited $status, want 1"
  grep -Fx 'credentials not found in native keychain' "$work/get" >/dev/null ||
    fail "get $host did not report not found: $(cat "$work/get")"
done
grep -F 'Error parsing the serverURL' "$work/home/.ecr/log/ecr-login.log" >/dev/null ||
  fail 'the helper did not log the rejected non-ECR server URL'

# Protocol: `list` takes no input and prints a JSON object of server URL to
# username. With an empty cache and no reachable AWS it is an empty object.
helper list </dev/null >"$work/list" 2>"$work/list.err" || fail "list failed: $(cat "$work/list.err")"
test "$(jq -c . "$work/list")" = '{}' || fail "empty list returned: $(cat "$work/list")"

# A cached, unexpired token is served from $HOME/.ecr/cache.json by `get` and
# reported by `list`, still with no network. The cache key is the region, the
# SHA-256 of the access key ID, and the registry ID.
registry=123456789012.dkr.ecr.us-east-1.amazonaws.com
key_hash=$(printf '%s' AKIAVERITYSMOKETEST0 | openssl dgst -sha256 -binary | base64)
token=$(printf '%s' 'AWS:verity-smoke-password' | base64)
jq -n --arg key "us-east-1-$key_hash-123456789012" --arg token "$token" \
  --arg endpoint "https://$registry" '{
    Registries: {($key): {
      AuthorizationToken: $token,
      RequestedAt: "2026-01-01T00:00:00Z",
      ExpiresAt: "2099-01-01T00:00:00Z",
      ProxyEndpoint: $endpoint,
      Service: "ecr"
    }},
    Version: "1.0"
  }' >"$work/home/.ecr/cache.json"
chmod 0666 "$work/home/.ecr/cache.json"

printf '%s' "$registry" | helper get >"$work/cached" 2>"$work/cached.err" ||
  fail "get of a cached ECR registry failed: $(cat "$work/cached" "$work/cached.err")"
test "$(jq -c '{ServerURL, Username, Secret}' "$work/cached")" = \
  "{\"ServerURL\":\"$registry\",\"Username\":\"AWS\",\"Secret\":\"verity-smoke-password\"}" ||
  fail "unexpected cached credentials: $(cat "$work/cached")"
helper list </dev/null >"$work/list" 2>"$work/list.err" || fail "list failed: $(cat "$work/list.err")"
test "$(jq -c . "$work/list")" = "{\"https://$registry\":\"AWS\"}" ||
  fail "list did not report the cached registry: $(cat "$work/list")"

# Protocol: credentials are temporary, so `store` and `erase` are refused
# unless AWS_ECR_IGNORE_CREDS_STORAGE turns them into no-ops.
status=0
printf '{"ServerURL":"%s","Username":"AWS","Secret":"x"}' "$registry" |
  helper store >"$work/store" 2>&1 || status=$?
test "$status" = 1 || fail "store exited $status, want 1"
grep -Fx 'not implemented' "$work/store" >/dev/null || fail "store: $(cat "$work/store")"
printf '{"ServerURL":"%s","Username":"AWS","Secret":"x"}' "$registry" |
  docker run --rm -i --network none -e AWS_ECR_IGNORE_CREDS_STORAGE=true --tmpfs /home/nonroot \
    "$image" store >"$work/store" 2>&1 || fail "ignored store failed: $(cat "$work/store")"
status=0
printf '%s' "$registry" | helper erase >"$work/erase" 2>&1 || status=$?
test "$status" = 1 || fail "erase exited $status, want 1"
grep -Fx 'not implemented' "$work/erase" >/dev/null || fail "erase: $(cat "$work/erase")"

status=0
helper bogus </dev/null >"$work/bogus" 2>&1 || status=$?
test "$status" = 1 || fail "unknown action exited $status, want 1"
grep -Fx 'docker-credential-ecr-login: unknown action: bogus' "$work/bogus" >/dev/null ||
  fail "unknown action: $(cat "$work/bogus")"

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
