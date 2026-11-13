#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
fixture="$here/fixture.diff"
version=$(sed -n 's/^    - delta=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)
esc=$(printf '\033')

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -n "$version" ] || fail 'could not read the pinned delta version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/delta"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "delta $version" "$work/version" >/dev/null ||
  fail "version does not report delta $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
sed "s/${esc}\[[0-9;]*m//g" "$work/invalid" |
  grep -F "unexpected argument '--definitely-invalid'" >/dev/null ||
  fail 'invalid flag diagnostic is missing'

# Decorated output on a read-only root with no capabilities: delta replaces the
# git headers with a file title, drops the +/- markers and highlights the changed
# word inside the changed line.
docker run --rm -i --network none --read-only --cap-drop=ALL "$image" \
  --no-gitconfig --paging=never --dark --width=80 <"$fixture" >"$work/decorated" 2>&1 ||
  fail "decorated diff failed: $(cat "$work/decorated")"
grep -F 'greeting.txt' "$work/decorated" >/dev/null || fail 'file title is missing'
grep -F 'diff --git' "$work/decorated" >/dev/null && fail 'raw git header was not decorated'
grep -F -- '-old line' "$work/decorated" >/dev/null && fail 'minus marker was not removed'
grep -F -- '+new line' "$work/decorated" >/dev/null && fail 'plus marker was not removed'
grep -F "${esc}[48;5;124mold" "$work/decorated" >/dev/null ||
  fail 'removed word is not emphasized'
grep -F "${esc}[48;5;28;38;5;231mnew" "$work/decorated" >/dev/null ||
  fail 'added word is not emphasized'

# --color-only keeps the input lines intact, so stripping the escapes restores
# the fixture byte for byte.
docker run --rm -i --network none "$image" --no-gitconfig --paging=never --dark \
  --color-only <"$fixture" >"$work/color-only" 2>&1 || fail 'color-only failed'
sed "s/${esc}\[[0-9;]*[mK]//g" "$work/color-only" >"$work/stripped"
cmp -s "$fixture" "$work/stripped" || fail 'color-only output changed the diff text'

# Without color the decorated output carries no escape sequences.
docker run --rm -i --network none "$image" --no-gitconfig --paging=never \
  --color-only --features= --syntax-theme=none --plus-style=normal \
  --minus-style=normal --plus-emph-style=normal --minus-emph-style=normal \
  --zero-style=normal <"$fixture" >"$work/plain" 2>&1 || fail 'plain styles failed'
cmp -s "$fixture" "$work/plain" || fail 'plain styled output differs from the input'

printf 'SMOKE PASS image=%s\n' "$image"
