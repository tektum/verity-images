#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
here=$(cd "$(dirname "$0")" && pwd)
expected=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml" | head -n 1)
[ -n "$expected" ] || { printf 'package version not found\n' >&2; exit 1; }

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# OCI contract: pulumi entrypoint, non-root user, update check off.
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/pulumi"]' ] || fail 'unexpected entrypoint'
user=$(docker image inspect -f '{{.Config.User}}' "$image")
case "$user" in
  ''|0|root|0:*|root:*) fail "image runs as root: '$user'" ;;
esac
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'PULUMI_SKIP_UPDATE_CHECK=true' ||
  fail 'PULUMI_SKIP_UPDATE_CHECK is not set'

version=$(docker run --rm --network none "$image" version)
[ "$version" = "v$expected" ] || fail "pulumi version reported '$version', expected v$expected"

# Negative: an unknown flag fails.
status=0
docker run --rm --network none "$image" --no-such-flag >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'an unknown flag exited 0'

# Real workflow on the self-managed file backend, offline: log in, create an encrypted stack, set a plain and a
# secret config value, read them back, and confirm the secret is encrypted at rest in the state directory.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
chmod 755 "$work"
cat > "$work/Pulumi.yaml" <<'EOF'
name: verity-smoke
runtime: yaml
description: verity smoke test project
EOF
mkdir "$work/state"
run() {
  docker run --rm --network none --user "$(id -u):$(id -g)" \
    -e HOME=/work/.home -e PULUMI_CONFIG_PASSPHRASE=verity-smoke-passphrase \
    -v "$work:/work" -w /work "$image" "$@"
}

out=$(run login file:///work/state 2>&1) || fail "pulumi login --local failed: $out"
printf '%s\n' "$out" | grep -q 'Logged in to' || fail "unexpected login output: $out"
run stack init dev --secrets-provider passphrase >/dev/null 2>&1 || fail 'pulumi stack init failed'
run config set greeting hello-verity >/dev/null || fail 'pulumi config set failed'
run config set --secret token s3cr3t-value >/dev/null || fail 'pulumi config set --secret failed'
[ "$(run config get greeting)" = hello-verity ] || fail 'plain config value did not round-trip'
[ "$(run config get token)" = s3cr3t-value ] || fail 'secret config value did not round-trip'
grep -q 's3cr3t-value' "$work/Pulumi.dev.yaml" && fail 'secret stored in plain text'
grep -q 'secure:' "$work/Pulumi.dev.yaml" || fail 'secret is not marked secure'
stacks=$(run stack ls --json) || fail 'pulumi stack ls failed'
printf '%s\n' "$stacks" | grep -q '"name": "dev"' || fail "stack dev not listed: $stacks"
[ -n "$(find "$work/state/.pulumi" -name 'dev*' 2>/dev/null)" ] || fail 'no stack state written to the file backend'

# Negative: a wrong passphrase cannot decrypt the secret.
status=0
docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/work/.home -e PULUMI_CONFIG_PASSPHRASE=wrong \
  -v "$work:/work" -w /work "$image" config get token >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail 'a wrong passphrase decrypted the secret'
