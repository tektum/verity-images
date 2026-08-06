#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected='["alpha","beta"]'
actual=$(printf '%s\n' '{"items":[{"name":"beta"},{"name":"alpha"}]}' | docker run --rm -i "$image" -c '.items | map(.name) | sort')
test "$actual" = "$expected"

if printf '%s\n' '{"items":' | docker run --rm -i "$image" . >/dev/null 2>&1; then
  printf '%s\n' 'malformed JSON unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
