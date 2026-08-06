#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
test "$entrypoint" = '["/usr/bin/erl"]' || {
  printf 'unexpected entrypoint: %s\n' "$entrypoint" >&2
  exit 1
}
user=$(docker image inspect --format '{{.Config.User}}' "$image")
test "$user" = 65532 || {
  printf 'unexpected user: %s\n' "$user" >&2
  exit 1
}
docker run --rm --entrypoint /bin/sh "$image" -c 'test "$(id -u)" = 65532 && touch /app/smoke-test'

actual=$(docker run --rm "$image" -noshell -eval 'case file:get_cwd() of {ok, "/app"} -> io:format("~p~n", [6 * 7]), halt(0); _ -> halt(1) end.')
test "$actual" = 42

if docker run --rm "$image" -noshell -eval 'invalid expression' >/dev/null 2>&1; then
  printf '%s\n' 'invalid Erlang expression unexpectedly succeeded' >&2
  exit 1
fi

printf 'SMOKE PASS image=%s\n' "$image"
