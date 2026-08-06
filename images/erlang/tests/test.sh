#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
actual=$(docker run --rm "$image" -noshell -eval 'case file:get_cwd() of {ok, "/app"} -> io:format("~p~n", [6 * 7]), halt(0); _ -> halt(1) end.')
test "$actual" = 42

if docker run --rm "$image" -noshell -eval 'invalid expression' >/dev/null 2>&1; then
  printf '%s\n' 'invalid Erlang expression unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
