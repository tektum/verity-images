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
  '["/usr/bin/xeol"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

# Every container runs offline: no network, read-only root, host uid, no
# database auto-update and no application update check. The EOL database lives
# in a host-mounted cache directory so an import survives between containers.
mkdir "$work/in" "$work/cache"
run_cache() {
  cache=$1
  shift
  docker run --rm --network none --read-only --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e XEOL_DB_AUTO_UPDATE=false -e XEOL_CHECK_FOR_APP_UPDATE=false \
    -e XEOL_DB_CACHE_DIR=/cache -e XEOL_DB_VALIDATE_BY_HASH_ON_START=true \
    --tmpfs /tmp:rw,mode=1777 \
    -v "$cache:/cache" -v "$work/in:/work:ro" -w /work "$image" "$@"
}
run() {
  run_cache "$work/cache" "$@"
}

run version >"$work/version" 2>&1 || fail 'version failed'
grep -E "^Version: +${version}\$" "$work/version" >/dev/null ||
  fail 'version is not embedded'
grep -E '^GitCommit: +[0-9a-f]{40}$' "$work/version" >/dev/null ||
  fail 'source commit is not embedded'
grep -E '^Supported DB Schema: +1$' "$work/version" >/dev/null ||
  fail 'supported database schema is missing'

run --help >"$work/help" 2>&1 || fail 'help failed'
grep -F 'Usage:' "$work/help" >/dev/null || fail 'help is missing usage text'
grep -F -- '--fail-on-eol-found' "$work/help" >/dev/null ||
  fail 'help is missing the EOL gate flag'

# Default configuration, logged at debug level: database auto-update is on and
# the cache lives under the nonroot home directory.
docker run --rm --network none --read-only "$image" -vv db status \
  >"$work/defaults" 2>&1 || true
grep -E '^ +auto-update: true$' "$work/defaults" >/dev/null ||
  fail 'default database auto-update is not enabled'
grep -E '^ +cache-dir: /home/nonroot/\.cache/xeol/db$' "$work/defaults" >/dev/null ||
  fail 'default database cache dir is missing'
grep -E '^ +update-url: https://data\.xeol\.io/xeol/databases/listing\.json$' \
  "$work/defaults" >/dev/null || fail 'default database update URL is missing'

rc=0
run --definitely-invalid >"$work/invalid" 2>&1 || rc=$?
test "$rc" != 0 || fail 'invalid argument unexpectedly succeeded'
grep -F 'unknown flag: --definitely-invalid' "$work/invalid" >/dev/null ||
  fail 'invalid argument diagnostic is missing'

# SBOM fixture: one EOL release (Django 1.11, EOL 2020-04-01) and one supported
# release (Django 5.2, fixture EOL 2099-01-01) as a CycloneDX document, plus the
# same EOL release as a Python requirements file for a directory scan.
cat >"$work/in/sbom.cdx.json" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "version": 1,
  "components": [
    {"type": "library", "name": "django", "version": "1.11.29",
     "purl": "pkg:pypi/django@1.11.29"},
    {"type": "library", "name": "django", "version": "5.2.0",
     "purl": "pkg:pypi/django@5.2.0"}
  ]
}
EOF
mkdir "$work/in/project"
printf 'django==1.11.29\n' >"$work/in/project/requirements.txt"
chmod -R a+rX "$work/in"

# Without a database, scans fail closed instead of reporting a clean result.
rc=0
run sbom:/work/sbom.cdx.json >"$work/nodb.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "scan without a database exit code $rc, expected 1"
grep -F 'failed to load EOL db: eol database is invalid' "$work/nodb.out" >/dev/null ||
  fail 'missing-database diagnostic is missing'
rc=0
run db status >"$work/nodb-status.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'db status without a database unexpectedly succeeded'
grep -F 'Status:    invalid' "$work/nodb-status.out" >/dev/null ||
  fail 'database status does not report the missing database'

# The upstream database feed (data.xeol.io) is no longer served, so build a
# minimal schema 1 database hermetically with the tables and columns that the
# v1 store queries (xeol/db/v1/store), then package it as an import archive.
mkdb() {
  dir=$1 built=$2 schema=$3
  mkdir "$dir"
  python3 - "$dir/xeol.db" <<'PYTHON'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE id (build_timestamp text, schema_version integer);
CREATE TABLE products (id integer PRIMARY KEY, name text, permalink text);
CREATE TABLE cycles (id integer PRIMARY KEY, product_id integer,
  release_cycle text, eol datetime, eol_bool numeric, lts text,
  latest_release text, latest_release_date datetime, release_date datetime);
CREATE TABLE purls (id integer PRIMARY KEY, product_id integer, purl text);
CREATE TABLE cpes (id integer PRIMARY KEY, product_id integer, cpe text);
CREATE TABLE vulns (id integer PRIMARY KEY, product_id integer,
  version text, issue_count integer);
INSERT INTO id VALUES ('2026-01-01T00:00:00Z', 1);
INSERT INTO products VALUES (1, 'Django', 'https://endoflife.date/django');
INSERT INTO purls VALUES (1, 1, 'pkg:pypi/django');
INSERT INTO cycles VALUES
  (1, 1, '1.11', '2020-04-01', 0, '', '1.11.29', '2020-03-04', '2017-04-04'),
  (2, 1, '5.2', '2099-01-01', 0, '', '5.2.0', '2025-04-02', '2025-04-02');
""")
con.commit()
con.close()
PYTHON
  sum=$(sha256sum "$dir/xeol.db" | cut -d' ' -f1)
  printf '{"built":"%s","version":%s,"checksum":"sha256:%s"}\n' \
    "$built" "$schema" "$sum" >"$dir/metadata.json"
  tar -czf "$dir.tar.gz" -C "$dir" metadata.json xeol.db
  cp "$dir.tar.gz" "$work/in/"
}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdb "$work/db" "$now" 1
chmod -R a+rX "$work/in"

run db import /work/db.tar.gz >"$work/import.out" 2>&1 || fail 'db import failed'
grep -F 'EOL database imported' "$work/import.out" >/dev/null ||
  fail 'db import did not confirm the import'
test -f "$work/cache/1/xeol.db" || fail 'imported database is not in the cache dir'
run db status >"$work/status.out" 2>&1 || fail 'db status failed after import'
grep -F 'Status:    valid' "$work/status.out" >/dev/null ||
  fail 'imported database is not valid'
grep -E '^Schema: +1$' "$work/status.out" >/dev/null ||
  fail 'imported database schema is not reported'

# Offline SBOM scan against the imported database: the EOL release matches with
# its cycle data and the supported release does not.
run sbom:/work/sbom.cdx.json -o json >"$work/scan.json" 2>"$work/scan.err" ||
  fail "SBOM scan failed: $(cat "$work/scan.err")"
python3 - "$work/scan.json" <<'PYTHON' || fail 'SBOM scan did not report the expected EOL match'
import json, sys
doc = json.load(open(sys.argv[1]))
found = sorted(
    (m["artifact"]["name"], m["artifact"]["version"], m["artifact"]["purl"],
     m["Cycle"]["ProductName"], m["Cycle"]["ReleaseCycle"], m["Cycle"]["Eol"])
    for m in doc["matches"]
)
want = [("django", "1.11.29", "pkg:pypi/django@1.11.29",
         "Django", "1.11", "2020-04-01")]
if found != want:
    sys.exit(f"matches {found!r}, expected {want!r}")
PYTHON

run sbom:/work/sbom.cdx.json >"$work/scan.table" 2>&1 || fail 'table output scan failed'
grep -E '^django +1\.11\.29 +2020-04-01 ' "$work/scan.table" >/dev/null ||
  fail 'table output is missing the EOL match'
if grep -F '5.2.0' "$work/scan.table" >/dev/null; then
  fail 'supported release reported as EOL'
fi

rc=0
run sbom:/work/sbom.cdx.json --fail-on-eol-found >"$work/gate.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "--fail-on-eol-found exit code $rc, expected 1"
grep -F 'discovered EOL packages' "$work/gate.out" >/dev/null ||
  fail '--fail-on-eol-found diagnostic is missing'

# Directory scans catalog packages with the bundled Syft cataloger offline.
run dir:/work/project -o json >"$work/dir.json" 2>"$work/dir.err" ||
  fail "directory scan failed: $(cat "$work/dir.err")"
python3 - "$work/dir.json" <<'PYTHON' || fail 'directory scan did not report the expected EOL match'
import json, sys
doc = json.load(open(sys.argv[1]))
found = [(m["artifact"]["purl"], m["Cycle"]["Eol"]) for m in doc["matches"]]
if found != [("pkg:pypi/django@1.11.29", "2020-04-01")]:
    sys.exit(f"matches {found!r}")
PYTHON

# A database whose payload no longer matches its metadata checksum is rejected.
cp -R "$work/cache" "$work/tampered"
printf 'tampered' >>"$work/tampered/1/xeol.db"
rc=0
run_cache "$work/tampered" sbom:/work/sbom.cdx.json >"$work/tampered.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "tampered database scan exit code $rc, expected 1"
grep -F 'bad db checksum' "$work/tampered.out" >/dev/null ||
  fail 'tampered database diagnostic is missing'

# A database for another schema is refused at import.
mkdb "$work/db2" "$now" 2
rc=0
run db import /work/db2.tar.gz >"$work/import2.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'schema 2 database import unexpectedly succeeded'
grep -F 'unsupported database version: have=2 want=1' "$work/import2.out" >/dev/null ||
  fail 'schema mismatch diagnostic is missing'

# A database older than the 90 day default age limit is stale.
mkdb "$work/old" 2020-01-01T00:00:00Z 1
mkdir "$work/oldcache"
run_cache "$work/oldcache" db import /work/old.tar.gz >/dev/null 2>&1 ||
  fail 'stale database import failed'
rc=0
run_cache "$work/oldcache" sbom:/work/sbom.cdx.json >"$work/old.out" 2>&1 || rc=$?
test "$rc" = 1 || fail "stale database scan exit code $rc, expected 1"
grep -F 'the eol database was built' "$work/old.out" >/dev/null ||
  fail 'stale database diagnostic is missing'

# A missing SBOM input is rejected.
rc=0
run sbom:/work/missing.json >"$work/missing.out" 2>&1 || rc=$?
test "$rc" != 0 || fail 'missing SBOM unexpectedly succeeded'
grep -F 'unable to open file' "$work/missing.out" >/dev/null ||
  fail 'missing SBOM diagnostic is missing'

printf 'SMOKE PASS image=%s\n' "$image"
