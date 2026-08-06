#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
actual=$(printf 'name: old\n' | docker run --rm -i "$image" '.name = "new"' -)
[ "$actual" = 'name: new' ] || {
  printf 'unexpected transformation: %s\n' "$actual" >&2
  exit 1
}

if docker run --rm "$image" '.name = [' >/dev/null 2>&1; then
  printf 'malformed expression unexpectedly succeeded\n' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
