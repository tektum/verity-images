#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)"$/\1/p' "$recipe")
otp=$(sed -n 's/^      - erlang-\([0-9][0-9]*\)$/\1/p' "$recipe")
[ -n "$version" ] && [ -n "$otp" ] || { printf 'version or OTP release not found in %s\n' "$recipe" >&2; exit 1; }

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")
[ "$entrypoint" = '["/usr/bin/elixir"]' ] || fail "unexpected entrypoint: $entrypoint"
user=$(docker image inspect --format '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "unexpected user: $user"
workdir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /app ] || fail "unexpected working directory: $workdir"

banner=$(docker run --rm "$image" --version 2>&1)
printf '%s\n' "$banner" | grep -qxF "Elixir $version (compiled with Erlang/OTP $otp)" ||
  fail "unexpected version banner: $banner"

sum=$(docker run --rm "$image" -e 'IO.puts(1 + 1)')
[ "$sum" = 2 ] || fail "elixir -e printed: $sum"

encoding=$(docker run --rm "$image" -e 'IO.puts(:file.native_name_encoding())')
[ "$encoding" = utf8 ] || fail "unexpected native name encoding: $encoding"

iex=$(docker run --rm --entrypoint /usr/bin/iex "$image" -e 'IO.puts("iex " <> System.version()); System.halt(0)' 2>&1)
printf '%s\n' "$iex" | grep -qxF "iex $version" || fail "iex printed: $iex"

if docker run --rm "$image" -e 'raise "boom"' >/dev/null 2>&1; then
  fail 'raising script unexpectedly succeeded'
fi

project=$(docker run --rm --entrypoint /bin/sh "$image" -c '
  set -eu
  test "$(id -u)" = 65532
  mix new smoke >/dev/null
  cd smoke
  mix compile >/dev/null
  mix run -e "IO.puts(Smoke.hello())"
  mix test 2>&1 | grep -E "^[0-9]+ (doctests?|tests?).*, 0 failures$"
' 2>&1) || fail "mix project failed: $project"
printf '%s\n' "$project" | grep -qxF world || fail "mix run printed: $project"

broken=$(docker run --rm --entrypoint /bin/sh "$image" -c '
  mix new broken >/dev/null
  cd broken
  printf "defmodule Broken do\n  def f, do: undefined_call(\n" > lib/broken.ex
  mix compile
' 2>&1) && fail "invalid project unexpectedly compiled: $broken"

printf 'SMOKE PASS image=%s version=%s otp=%s\n' "$image" "$version" "$otp"
