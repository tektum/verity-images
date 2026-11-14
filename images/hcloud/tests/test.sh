#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Every run uses --network none: the test never reaches the Hetzner Cloud API.
# It covers the offline surface instead: version, argument and token
# validation, and the context and configuration lifecycle in a mounted file.
work=$(mktemp -d)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/hcloud"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

mkdir -p "$work/cfg"
chmod 0777 "$work/cfg"
token=$(printf 'verity%058d' 0)
[ "${#token}" -eq 64 ] || fail 'fixture token is not 64 characters'

hcloud() {
  docker run --rm --network none --read-only --cap-drop ALL \
    -v "$work/cfg:/cfg" -e HCLOUD_CONFIG=/cfg/cli.toml "$image" "$@"
}

hcloud version >"$work/version" || fail 'hcloud version failed'
grep -Fx "hcloud $expected_version" "$work/version" >/dev/null ||
  fail "hcloud version does not report $expected_version: $(cat "$work/version")"

if hcloud --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid flag unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# Negative: without a context or token no API request is attempted.
if hcloud server list >"$work/notoken" 2>&1; then
  fail 'server list without a token unexpectedly succeeded'
fi
grep -F 'no active context or token' "$work/notoken" >/dev/null ||
  fail "missing token diagnostic is missing: $(cat "$work/notoken")"

# Negative: a malformed token is rejected locally.
if docker run --rm --network none --read-only --cap-drop ALL -v "$work/cfg:/cfg" \
  -e HCLOUD_CONFIG=/cfg/cli.toml -e HCLOUD_TOKEN=short "$image" \
  context create --token-from-env bad >"$work/badtoken" 2>&1; then
  fail 'context with a malformed token unexpectedly succeeded'
fi
grep -F 'invalid token: must be 64 characters in length' "$work/badtoken" >/dev/null ||
  fail "malformed token diagnostic is missing: $(cat "$work/badtoken")"

docker run --rm --network none --read-only --cap-drop ALL -v "$work/cfg:/cfg" \
  -e HCLOUD_CONFIG=/cfg/cli.toml -e HCLOUD_TOKEN="$token" "$image" \
  context create --token-from-env smoke >"$work/create" 2>&1 ||
  fail "context create failed: $(cat "$work/create")"
grep -F 'Context smoke created and activated' "$work/create" >/dev/null ||
  fail "context create output is unexpected: $(cat "$work/create")"
test "$(stat -c %a "$work/cfg/cli.toml")" = 600 || fail 'config file is not mode 0600'

hcloud context active >"$work/active" || fail 'context active failed'
grep -Fx smoke "$work/active" >/dev/null || fail 'smoke is not the active context'
hcloud context list >"$work/list" || fail 'context list failed'
grep -Ex '\* +smoke' "$work/list" >/dev/null || fail "context list is unexpected: $(cat "$work/list")"

hcloud config set default-ssh-keys alpha,beta >/dev/null || fail 'config set failed'
hcloud config get default-ssh-keys >"$work/keys" || fail 'config get failed'
grep -Fx '[alpha,beta]' "$work/keys" >/dev/null ||
  fail "config get is unexpected: $(cat "$work/keys")"
hcloud config list >"$work/config" || fail 'config list failed'
grep -Ex 'token +\[redacted\]' "$work/config" >/dev/null ||
  fail 'config list does not redact the token'
if grep -F "$token" "$work/config" >/dev/null; then
  fail 'config list prints the token'
fi

# Negative: server create validates required flags before any request.
if hcloud server create >"$work/create-server" 2>&1; then
  fail 'server create without flags unexpectedly succeeded'
fi
grep -F 'required flag(s) "image", "name", "type" not set' "$work/create-server" >/dev/null ||
  fail "required flag diagnostic is missing: $(cat "$work/create-server")"

hcloud context delete smoke >/dev/null 2>&1 || fail 'context delete failed'
hcloud context list >"$work/list-after" || fail 'context list after delete failed'
if grep -F smoke "$work/list-after" >/dev/null; then
  fail 'deleted context is still listed'
fi

printf 'SMOKE PASS image=%s version=%s\n' "$image" "$expected_version"
