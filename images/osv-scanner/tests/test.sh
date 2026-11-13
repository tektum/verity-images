#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
config="$(dirname "$0")/../apko.yaml"
version=$(sed -n 's/^    - osv-scanner=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the pinned osv-scanner version'
command -v python3 >/dev/null || fail 'python3 is required to build the offline database fixture'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/osv-scanner"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$work/version" 2>&1 ||
  fail 'version failed'
grep -Fx "osv-scanner version: $version" "$work/version" >/dev/null ||
  fail "version does not report $version: $(cat "$work/version")"

rc=0
docker run --rm --network none "$image" --definitely-invalid >"$work/flag" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'invalid flag unexpectedly succeeded'
grep -F 'flag provided but not defined: -definitely-invalid' "$work/flag" >/dev/null ||
  fail "invalid flag diagnostic is missing: $(cat "$work/flag")"

# Offline database fixture: one synthetic OSV record for a PyPI package, in the
# local cache layout osv-scanner reads with --offline (no network access).
mkdir -p "$work/db/osv-scalibr/PyPI" "$work/vulnerable" "$work/fixed" "$work/npm"
cat >"$work/VERITY-2026-0001.json" <<'JSON'
{"schema_version":"1.6.0","id":"VERITY-2026-0001","modified":"2026-11-01T00:00:00Z","published":"2026-11-01T00:00:00Z","summary":"Synthetic advisory for the Verity smoke test","affected":[{"package":{"ecosystem":"PyPI","name":"verity-demo"},"ranges":[{"type":"ECOSYSTEM","events":[{"introduced":"0"},{"fixed":"2.0.0"}]}]}]}
JSON
python3 - "$work" <<'PY'
import sys, zipfile
work = sys.argv[1]
with zipfile.ZipFile(f"{work}/db/osv-scalibr/PyPI/all.zip", "w") as z:
    z.write(f"{work}/VERITY-2026-0001.json", "VERITY-2026-0001.json")
PY
printf 'verity-demo==1.0.0\n' >"$work/vulnerable/requirements.txt"
printf 'verity-demo==2.0.0\n' >"$work/fixed/requirements.txt"
cat >"$work/npm/package-lock.json" <<'JSON'
{"name":"demo","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"demo","version":"1.0.0","dependencies":{"left-pad":"1.3.0"}},"node_modules/left-pad":{"version":"1.3.0","resolved":"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz"}}}
JSON
chmod -R a+rX "$work"

scan() {
  dir=$1 lockfile=$2
  shift 2
  docker run --rm --network none --read-only \
    -e OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY=/db -v "$work/db:/db:ro" \
    -v "$work/$dir:/work:ro" "$image" scan source --offline -L "$lockfile" "$@"
}

# A vulnerable pinned version is reported from the offline database with exit 1.
rc=0
scan vulnerable requirements.txt --format json >"$work/vulnerable.json" 2>"$work/vulnerable.err" || rc=$?
test "$rc" -eq 1 || fail "vulnerable scan exited $rc, want 1: $(cat "$work/vulnerable.err")"
grep -F 'Loaded PyPI local db from /db/osv-scalibr/PyPI/all.zip' "$work/vulnerable.err" >/dev/null ||
  fail "offline database was not used: $(cat "$work/vulnerable.err")"
python3 - "$work/vulnerable.json" <<'PY' || fail "unexpected vulnerable scan result: $(cat "$work/vulnerable.json")"
import json, sys
found = {
    (p["package"]["name"], p["package"]["version"], v["id"])
    for r in json.load(open(sys.argv[1]))["results"]
    for p in r["packages"]
    for v in p.get("vulnerabilities", [])
}
assert found == {("verity-demo", "1.0.0", "VERITY-2026-0001")}, found
PY

# The fixed version is clean.
scan fixed requirements.txt >"$work/fixed.out" 2>&1 ||
  fail "fixed scan failed: $(cat "$work/fixed.out")"
grep -F 'No issues found' "$work/fixed.out" >/dev/null ||
  fail "fixed scan did not report a clean result: $(cat "$work/fixed.out")"

# Offline mode never downloads: an ecosystem without a cached database is an error.
rc=0
scan npm package-lock.json >"$work/npm.out" 2>&1 || rc=$?
test "$rc" -ne 0 -a "$rc" -ne 1 || fail "missing offline database exited $rc: $(cat "$work/npm.out")"
grep -F 'no offline version of the OSV database is available' "$work/npm.out" >/dev/null ||
  fail "missing offline database diagnostic is absent: $(cat "$work/npm.out")"

printf 'SMOKE PASS\n'
