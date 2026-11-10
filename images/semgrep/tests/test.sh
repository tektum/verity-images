#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
fixture=$here/fixture
recipe=$here/../melange.yaml

# The expected release comes from the recipe, so a version bump needs no edit here.
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$recipe" | head -n 1)
[ -n "$expected_version" ] || { printf 'package version not found in %s\n' "$recipe" >&2; exit 1; }

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Every run is offline, as the image's non-root user, on a read-only root
# filesystem with no capabilities. /tmp is the only writable path.
run() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --tmpfs /tmp:exec,uid=65532,gid=65532,mode=1777 \
    -e HOME=/tmp "$@"
}

[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/semgrep"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected user'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /src ] || fail 'unexpected work directory'

# The CLI, the Python wrapper and both engine entry points report the release.
for tool in semgrep pysemgrep; do
  reported=$(run --entrypoint "/usr/bin/$tool" "$image" --version) || fail "$tool --version failed"
  [ "$reported" = "$expected_version" ] || fail "$tool reports '$reported' (want $expected_version)"
done
core=$(run --entrypoint /usr/bin/semgrep-core "$image" -version) || fail 'semgrep-core -version failed'
case "$core" in
  *"$expected_version"*) ;;
  *) fail "semgrep-core reports '$core' (want $expected_version)" ;;
esac
osemgrep=$(run --entrypoint /usr/bin/osemgrep "$image" --version) || fail 'osemgrep --version failed'
case "$osemgrep" in
  *"$expected_version"*) ;;
  *) fail "osemgrep reports '$osemgrep' (want $expected_version)" ;;
esac

# Scan a fixture with a local rule: the seeded eval() call must be reported
# exactly once, at the seeded line, and nothing else may match. No registry,
# no metrics, no network.
report=$(mktemp)
trap 'rm -f "$report"' EXIT INT TERM
status=0
run -v "$fixture:/src:ro" "$image" scan --metrics=off --disable-version-check \
  --config /src/rule.yaml --json --quiet /src/target.py > "$report" || status=$?
# --error is not set, so findings do not change the exit status.
[ "$status" -eq 0 ] || { cat "$report" >&2; fail "scan exited $status"; }
count=$(grep -o '"check_id": *"[^"]*verity-no-eval"' "$report" | wc -l)
[ "$count" -eq 1 ] || { cat "$report" >&2; fail "expected 1 verity-no-eval finding, got $count"; }
grep -Eq '"start": *\{[^}]*"line": *9[,}]' "$report" || { cat "$report" >&2; fail 'finding is not on the seeded line 9'; }
grep -Eq '"errors": *\[\]' "$report" || { cat "$report" >&2; fail 'scan reported errors'; }

# The osemgrep engine finds the same seed.
osemgrep_out=$(run -v "$fixture:/src:ro" --entrypoint /usr/bin/osemgrep "$image" scan --metrics=off \
  --config /src/rule.yaml --quiet /src/target.py 2>&1) || fail 'osemgrep scan failed'
printf '%s\n' "$osemgrep_out" | grep -q 'verity-no-eval' || { printf '%s\n' "$osemgrep_out" >&2; fail 'osemgrep did not report verity-no-eval'; }

# Negative case: a file without the pattern yields zero findings, and --error
# turns a finding into exit status 1.
clean=$(run -v "$fixture:/src:ro" "$image" scan --metrics=off --disable-version-check \
  --config /src/rule.yaml --json --quiet /src/clean.py) || fail 'scan of clean file failed'
printf '%s\n' "$clean" | grep -Eq '"results": *\[\]' || { printf '%s\n' "$clean" >&2; fail 'clean file produced findings'; }
error_status=0
run -v "$fixture:/src:ro" "$image" scan --metrics=off --disable-version-check \
  --config /src/rule.yaml --error --quiet /src/target.py >/dev/null 2>&1 || error_status=$?
[ "$error_status" -eq 1 ] || fail "scan --error exited $error_status (want 1 for a finding)"

# A malformed rule file is rejected with a non-zero status.
bad=$(mktemp -d)
trap 'rm -f "$report"; rm -rf "$bad"' EXIT INT TERM
printf 'rules:\n  - id: broken\n' > "$bad/bad.yaml"
chmod 755 "$bad"
chmod 644 "$bad/bad.yaml"
bad_status=0
run -v "$bad:/cfg:ro" -v "$fixture:/src:ro" "$image" scan --metrics=off --disable-version-check \
  --config /cfg/bad.yaml --quiet /src/target.py >/dev/null 2>&1 || bad_status=$?
[ "$bad_status" -ne 0 ] || fail 'malformed rule was accepted'

printf 'semgrep %s smoke test passed\n' "$expected_version"
