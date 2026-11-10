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
  '["/usr/bin/terragrunt"]' || fail 'unexpected entrypoint'

mkdir "$work/stack"

run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work/stack "$image" "$@"
}

run --version >"$work/version" 2>&1 || fail 'version failed'
test "$(cat "$work/version")" = "terragrunt version v${version}" ||
  fail 'version is not embedded'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage: terragrunt [global options] <command> [options]' "$work/help" >/dev/null ||
  fail 'help is missing usage text'

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid argument unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# The stack directory must be world readable because the container runs as the
# host uid. The image ships no OpenTofu or Terraform binary, so only commands that
# evaluate HCL on their own are exercised here.
cat >"$work/stack/terragrunt.hcl" <<'HCL'
locals {
  name = "demo"
}

inputs = {
  greeting = "hello-${local.name}"
}
HCL

# render evaluates locals and interpolation and prints the resolved configuration.
run render --json >"$work/render.json" 2>"$work/render.err" || fail 'render failed'
grep -F '"greeting":"hello-demo"' "$work/render.json" >/dev/null ||
  fail 'rendered inputs are missing the interpolated value'
grep -F '"name":"demo"' "$work/render.json" >/dev/null ||
  fail 'rendered locals are missing'

# hcl fmt --check passes on formatted files and fails on an unformatted one.
run hcl fmt --check >"$work/fmt-ok.out" 2>&1 || fail 'formatted configuration was rejected'
printf 'locals{\nname="demo"\n}\n' >"$work/stack/bad.hcl"
rc=0
run hcl fmt --check >"$work/fmt-bad.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "unformatted configuration exit code $rc, expected 1"
grep -F "bad.hcl' needs formatting" "$work/fmt-bad.out" >/dev/null ||
  fail 'formatting diagnostic does not name the file'
rm "$work/stack/bad.hcl"

# Documented boundary: without tofu or terraform on PATH a run fails with a
# message that says so, instead of a partial result.
rc=0
run run -- plan >"$work/plan.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "run without a terraform binary exit code $rc, expected 1"
grep -F "The executables 'terraform' and 'tofu' are missing from your \$PATH" "$work/plan.out" >/dev/null ||
  fail 'missing-binary diagnostic is missing'

# Remote module sources over SSH (git@host:org/repo.git) need an SSH transport. Offline
# the clone must fail at name resolution, not with a missing ssh executable. ssh needs a
# passwd entry, so this runs as the image user instead of the host uid.
rc=0
docker run --rm --network none --read-only --tmpfs /tmp:rw,mode=1777 \
  --entrypoint git "$image" \
  ls-remote git@example.invalid:org/modules.git >"$work/ssh.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'offline ssh clone unexpectedly succeeded'
grep -F 'Could not resolve hostname' "$work/ssh.out" >/dev/null ||
  fail 'git did not reach the ssh transport'

printf 'SMOKE PASS image=%s\n' "$image"
