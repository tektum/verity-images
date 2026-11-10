#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

version=$(docker run --rm "$image" --version)
case "$version" in
  'yamllint 1.'*) ;;
  *) fail "unexpected version output: $version" ;;
esac

printf '%s\n' '---' 'service:' '  name: verity' '  replicas: 3' >"$work/valid.yaml"
# Seed one trailing-space error and one line-length error.
long_value=$(printf '%090d' 0)
printf '%s\n' '---' 'service:' '  name: verity ' "  token: $long_value" >"$work/invalid.yaml"
chmod 0755 "$work"
chmod 0644 "$work/valid.yaml" "$work/invalid.yaml"

docker run --rm -v "$work:/work:ro" "$image" --strict /work/valid.yaml \
  || fail 'valid YAML was rejected'

set +e
output=$(docker run --rm -v "$work:/work:ro" "$image" -f parsable /work/invalid.yaml 2>&1)
status=$?
set -e
test "$status" -eq 1 || fail "invalid YAML exited $status, want 1: $output"
printf '%s\n' "$output" | grep -q '^/work/invalid.yaml:3:15: \[error\] trailing spaces (trailing-spaces)$' \
  || fail "missing trailing-spaces finding: $output"
printf '%s\n' "$output" | grep -q '^/work/invalid.yaml:4:81: \[error\] line too long (99 > 80 characters) (line-length)$' \
  || fail "missing line-length finding: $output"

user=$(docker image inspect -f '{{.Config.User}}' "$image")
test "$user" = 65532 || fail "image user is $user, want 65532"

printf 'SMOKE PASS image=%s\n' "$image"
