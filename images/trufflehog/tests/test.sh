#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/trufflehog"]' || fail 'unexpected entrypoint'

# Offline and read-only: detectors that would call a provider API are run with
# --no-verification, so findings are reported as unverified.
run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e GIT_CONFIG_NOSYSTEM=1 --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work "$image" "$@"
}

run --version >"$work/version" 2>&1 || fail 'version failed'
test "$(cat "$work/version")" = "trufflehog ${version}" || fail 'version is not embedded'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'usage: trufflehog' "$work/help" >/dev/null || fail 'help is missing usage text'

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid argument unexpectedly succeeded'
grep -F "unknown long flag '--definitely-invalid'" "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Build the repositories on the host with the same uid the container uses, so git
# does not reject them as unsafely owned. The planted token has the shape of a
# GitHub personal access token with random characters, split so this file is not
# itself a finding.
prefix=ghp_
token="${prefix}R8pT3xKq1Vn5Zc9Wm2Ld7Hs4Yb6Jf0Ae3Xg1"

git_init() {
  git -C "$1" init -q
  git -C "$1" config user.email smoke@example.invalid
  git -C "$1" config user.name smoke
  git -C "$1" config commit.gpgsign false
}
mkdir "$work/leaky" "$work/clean"
git_init "$work/leaky"
printf 'token = %s\n' "$token" >"$work/leaky/config.ini"
git -C "$work/leaky" add config.ini
git -C "$work/leaky" commit -q -m 'add config'
git_init "$work/clean"
printf 'hello world\n' >"$work/clean/README.md"
git -C "$work/clean" add README.md
git -C "$work/clean" commit -q -m 'add readme'

scan() {
  run "$@" --no-verification --no-update
}

# Planted token in git history: the Github detector reports it with its commit and
# file, and --fail turns a finding into exit code 183.
rc=0
scan git file:///work/leaky --json --fail >"$work/leaky-git.json" 2>"$work/leaky-git.err" || rc=$?
test "$rc" = 183 || fail "leaky git scan exit code $rc, expected 183"
grep -F '"DetectorName":"Github"' "$work/leaky-git.json" >/dev/null ||
  fail 'Github detector finding is missing'
grep -F '"file":"config.ini"' "$work/leaky-git.json" >/dev/null ||
  fail 'finding does not name the file'
grep -E '"commit":"[0-9a-f]{40}"' "$work/leaky-git.json" >/dev/null ||
  fail 'finding does not name the commit'
grep -F '"Verified":false' "$work/leaky-git.json" >/dev/null ||
  fail 'finding was unexpectedly verified offline'
grep -F "$token" "$work/leaky-git.json" >/dev/null ||
  fail 'finding does not carry the planted token'

# Same token through a plain filesystem scan.
rc=0
scan filesystem /work/leaky --json --fail >"$work/leaky-fs.json" 2>/dev/null || rc=$?
test "$rc" = 183 || fail "leaky filesystem scan exit code $rc, expected 183"
grep -F '"DetectorName":"Github"' "$work/leaky-fs.json" >/dev/null ||
  fail 'filesystem scan did not report the Github detector'

# Clean repository: exit 0 and no findings, for both sources.
scan git file:///work/clean --json --fail >"$work/clean-git.json" 2>"$work/clean-git.err" ||
  fail 'clean git scan failed'
if grep -F '"DetectorName"' "$work/clean-git.json" >/dev/null; then
  fail 'clean git scan reported a finding'
fi
grep -F '"unverified_secrets":0' "$work/clean-git.err" >/dev/null ||
  fail 'clean git scan summary is missing'
scan filesystem /work/clean --json --fail >"$work/clean-fs.json" 2>/dev/null ||
  fail 'clean filesystem scan failed'
if grep -F '"DetectorName"' "$work/clean-fs.json" >/dev/null; then
  fail 'clean filesystem scan reported a finding'
fi

printf 'SMOKE PASS image=%s\n' "$image"
