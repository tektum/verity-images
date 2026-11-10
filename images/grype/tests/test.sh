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
  '["/usr/bin/grype"]' || fail 'unexpected entrypoint'

# The smoke test runs offline: no network, no vulnerability database and no
# application update check, so every assertion is about the image itself.
run() {
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e GRYPE_DB_AUTO_UPDATE=false -e GRYPE_CHECK_FOR_APP_UPDATE=false \
    --tmpfs /tmp:rw,mode=1777 \
    -v "$work:/work:ro" -w /work "$image" "$@"
}

run version >"$work/version" 2>&1 || fail 'version failed'
grep -E "^Version: +${version}\$" "$work/version" >/dev/null ||
  fail 'version is not embedded'
grep -E '^GitCommit: +[0-9a-f]{40}$' "$work/version" >/dev/null ||
  fail 'source commit is not embedded'
grep -E '^Supported DB Schema: +6$' "$work/version" >/dev/null ||
  fail 'supported database schema is missing'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid argument unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# Default configuration: database updates are on unless overridden, and the
# database cache lives under the home directory.
run config >"$work/config" 2>&1 || fail 'config failed'
grep -E '^ +auto-update: true$' "$work/config" >/dev/null ||
  fail 'default database auto-update is not enabled'
grep -F "cache-dir: '~/.cache/grype/db'" "$work/config" >/dev/null ||
  fail 'default database cache dir is missing'

# Fixture project with one vulnerable-looking Python requirement. The directory
# must be world readable because the container runs as the host uid.
mkdir "$work/project"
printf 'flask==2.0.1\n' >"$work/project/requirements.txt"

# Documented no-database behavior: with auto-update disabled and an empty cache,
# a scan fails closed with a database error instead of reporting a clean result.
rc=0
run dir:/work/project >"$work/scan.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "scan without a database exit code $rc, expected 1"
grep -F 'failed to load vulnerability db: database does not exist' "$work/scan.out" >/dev/null ||
  fail 'missing-database diagnostic is missing'

rc=0
run db status >"$work/db-status.out" 2>&1 || rc=$?
grep -F 'Status:    invalid' "$work/db-status.out" >/dev/null ||
  fail 'database status does not report the missing database'

# A missing SBOM input is rejected.
rc=0
run sbom:/work/missing.json >"$work/missing.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'missing SBOM unexpectedly succeeded'

printf 'SMOKE PASS image=%s\n' "$image"
