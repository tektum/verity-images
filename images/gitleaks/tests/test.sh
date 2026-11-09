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

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gitleaks"]' || fail 'unexpected entrypoint'

run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e GIT_CONFIG_NOSYSTEM=1 --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work" -w /work "$image" "$@"
}

run version >"$work/version" 2>&1 || fail 'version failed'
grep -Fx "${version}" "$work/version" >/dev/null || fail 'version is not embedded'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'

if run --definitely-invalid >"$work/invalid" 2>&1; then
  fail 'invalid argument unexpectedly succeeded'
fi
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Build the repositories on the host with the same uid the container uses, so git
# does not reject them as unsafely owned. The planted key is a fake AWS access key
# id (the AWS documentation example is allowlisted by gitleaks, so it is not
# used), split so this file is not itself a finding.
akia=AKIA
key="${akia}QYLPMN5HHHFPZAM2"

mkdir "$work/leaky" "$work/clean"
git_init() {
  git -C "$1" init -q
  git -C "$1" config user.email smoke@example.invalid
  git -C "$1" config user.name smoke
  git -C "$1" config commit.gpgsign false
}
git_init "$work/leaky"
printf 'aws_access_key_id = %s\n' "$key" >"$work/leaky/config.ini"
git -C "$work/leaky" add config.ini
git -C "$work/leaky" commit -q -m 'add config'

git_init "$work/clean"
printf 'hello world\n' >"$work/clean/README.md"
git -C "$work/clean" add README.md
git -C "$work/clean" commit -q -m 'add readme'

# Planted key in git history: exit 1 and the finding is reported.
rc=0
run git --no-banner --redact --report-format json \
  --report-path /work/leaky.json /work/leaky >"$work/leaky.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "leaky git scan exit code $rc, expected 1"
grep -F '"RuleID": "aws-access-token"' "$work/leaky.json" >/dev/null ||
  fail 'aws-access-token finding is missing from the report'
grep -F 'config.ini' "$work/leaky.json" >/dev/null ||
  fail 'finding does not name the file'
if grep -F "$key" "$work/leaky.json" >/dev/null; then
  fail 'secret was not redacted in the report'
fi
grep -F 'leaks found: 1' "$work/leaky.out" >/dev/null ||
  fail 'leak summary is missing'

# Same key through a plain directory scan.
rc=0
run dir --no-banner /work/leaky >"$work/leaky-dir.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "leaky dir scan exit code $rc, expected 1"

# Clean repository: exit 0.
run git --no-banner /work/clean >"$work/clean.out" 2>&1 ||
  fail 'clean git scan failed'
grep -F 'no leaks found' "$work/clean.out" >/dev/null ||
  fail 'clean scan summary is missing'
run dir --no-banner /work/clean >"$work/clean-dir.out" 2>&1 ||
  fail 'clean dir scan failed'

printf 'SMOKE PASS image=%s\n' "$image"
