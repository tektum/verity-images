#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/k9s"] null' ] || fail "unexpected entrypoint: $entrypoint"

# k9s needs no cluster for version, info, and flag parsing; every run is bounded
# so a regression that starts the terminal UI cannot hang the job.
timeout 30 docker run --rm "$image" version -s >"$work/version.txt" 2>&1 ||
  { cat "$work/version.txt" >&2; fail 'k9s version failed'; }
grep -Eq "^Version[[:space:]]+v$expected_version\$" "$work/version.txt" ||
  { cat "$work/version.txt" >&2; fail "unexpected version, want v$expected_version"; }
grep -Eq '^Commit[[:space:]]+[0-9a-f]{40}$' "$work/version.txt" ||
  { cat "$work/version.txt" >&2; fail 'build commit was not stamped'; }

timeout 30 docker run --rm "$image" info >"$work/info.txt" 2>&1 ||
  { cat "$work/info.txt" >&2; fail 'k9s info failed'; }
# Labels are wrapped in ANSI color codes, so the match is not anchored at the start.
grep -Eq 'Config:.*[[:space:]]/home/nonroot/\.config/k9s/config\.yaml$' "$work/info.txt" ||
  { cat "$work/info.txt" >&2; fail 'k9s info does not resolve paths under HOME'; }

if timeout 30 docker run --rm "$image" --no-such-flag >"$work/flag.txt" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -F 'no-such-flag' "$work/flag.txt" >/dev/null ||
  { cat "$work/flag.txt" >&2; fail 'unknown flag error does not name the flag'; }

printf '%s\n' "k9s $expected_version smoke test passed"
