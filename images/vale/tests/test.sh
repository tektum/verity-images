#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - vale=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned vale version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/vale"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "vale version $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# A local style with one existence rule; no network access is needed.
mkdir -p "$work/docs/styles/Verity"
cat >"$work/docs/.vale.ini" <<'INI'
StylesPath = styles
MinAlertLevel = suggestion

[*.md]
BasedOnStyles = Verity
INI
cat >"$work/docs/styles/Verity/Simply.yml" <<'YML'
extends: existence
message: "Avoid '%s'."
level: error
ignorecase: true
tokens:
  - simply
YML
printf '# Guide\n\nYou simply run it.\n\nThis line is clean.\n' >"$work/docs/bad.md"
printf '# Guide\n\nRun it.\n' >"$work/docs/good.md"
chmod -R a+rX "$work"

rc=0
docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  --output=line bad.md >"$work/bad.out" 2>&1 || rc=$?
test "$rc" -eq 1 || fail "linting bad.md exited $rc, want 1: $(cat "$work/bad.out")"
grep -Fx "bad.md:3:5:Verity.Simply:Avoid 'simply'." "$work/bad.out" >/dev/null ||
  fail "expected alert is missing: $(cat "$work/bad.out")"
test "$(wc -l <"$work/bad.out")" -eq 1 || fail "unexpected extra alerts: $(cat "$work/bad.out")"

docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  --output=JSON bad.md >"$work/bad.json" 2>&1 || true
grep -F '"Check": "Verity.Simply"' "$work/bad.json" >/dev/null ||
  fail "JSON output is missing the alert: $(cat "$work/bad.json")"

docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  --output=line good.md >"$work/good.out" 2>&1 ||
  fail "linting good.md failed: $(cat "$work/good.out")"
test ! -s "$work/good.out" || fail "clean file produced alerts: $(cat "$work/good.out")"

rc=0
docker run --rm --network none --read-only -v "$work/docs:/work:ro" "$image" \
  --config=missing.ini bad.md >"$work/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'missing config unexpectedly succeeded'

printf 'SMOKE PASS\n'
