#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

rg() {
  docker run --rm --network none -v "$work:/work:ro" -w /work "$image" "$@"
}

# ripgrep searches standard input when it is not a terminal, so only the
# stdin cases attach it.
rg_stdin() {
  docker run --rm -i --network none "$image" "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/rg"] null' ] || fail "unexpected entrypoint: $entrypoint"
[ "$(docker run --rm "$image" --version | sed -n 1p | cut -d' ' -f1-2)" = "ripgrep $expected_version" ] ||
  fail "unexpected version, want $expected_version"
rg --version | grep -Fx 'features:+pcre2' >/dev/null || fail 'PCRE2 support is missing'
[ "$(docker run --rm "$image" --pcre2-version | sed -n 1p | cut -d' ' -f1)" = PCRE2 ] ||
  fail 'rg --pcre2-version did not report PCRE2'

# Unknown flags are rejected with exit status 2.
set +e
rg --no-such-flag >/dev/null 2>&1
status=$?
set -e
[ "$status" = 2 ] || fail "unknown flag exited $status, want 2"

# Fixture tree: a nested match, a gitignored file and a hidden file.
mkdir -p "$work/src/deep" "$work/.git"
printf 'needle in haystack\n' >"$work/src/deep/a.txt"
printf 'no match here\n' >"$work/src/b.txt"
printf 'ignored.txt\n' >"$work/.gitignore"
printf 'needle ignored\n' >"$work/ignored.txt"
printf 'needle hidden\n' >"$work/.hidden.txt"
chmod -R a+rX "$work"

[ "$(rg --no-heading needle | sort)" = 'src/deep/a.txt:needle in haystack' ] ||
  fail 'recursive search did not honor .gitignore and hidden-file rules'
[ "$(rg -uu --files-with-matches needle | sort | tr '\n' ' ')" = '.hidden.txt ignored.txt src/deep/a.txt ' ] ||
  fail 'rg -uu did not search ignored and hidden files'

# Exit status 0 on a match, 1 on no match.
rg -q needle src || fail 'expected exit status 0 for a match'
set +e
rg -q absent-pattern src
status=$?
set -e
[ "$status" = 1 ] || fail "no-match search exited $status, want 1"

# PCRE2 look-behind from stdin.
[ "$(printf 'foo=bar\n' | rg_stdin -o -P '(?<=foo=)\w+')" = bar ] || fail 'PCRE2 look-behind failed'
# Rust regex engine rejects look-behind without -P.
if printf 'foo=bar\n' | rg_stdin '(?<=foo=)\w+' >/dev/null 2>&1; then
  fail 'look-behind was accepted without -P'
fi

printf '%s\n' "ripgrep $expected_version smoke test passed"
