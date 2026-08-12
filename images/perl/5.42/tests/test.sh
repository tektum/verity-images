#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/perl"]' || {
  printf 'unexpected entrypoint: %s\n' "$entrypoint" >&2
  exit 1
}

actual=$(docker run --rm "$image" -e 'print 6 * 7')
test "$actual" = 42

if docker run --rm "$image" -e 'my $value = ;' >/dev/null 2>&1; then
  printf '%s\n' 'invalid Perl script unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
