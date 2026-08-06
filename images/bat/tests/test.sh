#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/fixture.rs

plain=$(docker run --rm -v "$fixture:/fixture.rs:ro" "$image" \
  --plain --color=never --paging=never /fixture.rs)
expected_plain=$(cat "$fixture")
[ "$plain" = "$expected_plain" ] || {
  printf 'plain output mismatch\n' >&2
  exit 1
}

styled=$(docker run --rm -v "$fixture:/fixture.rs:ro" "$image" \
  --style=numbers --decorations=always --color=never --paging=never /fixture.rs)
styled_sha256=$(printf '%s' "$styled" | sha256sum | awk '{print $1}')
[ "$styled_sha256" = 80edc38b7dda5bbcdeb1218879d054e9cae3fb8f6e0d14575deac775450a3dc9 ] || {
  printf 'styled output mismatch\n' >&2
  exit 1
}

if docker run --rm "$image" --plain --color=never --paging=never /missing.rs >/dev/null 2>&1; then
  printf 'missing file unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS\n'
