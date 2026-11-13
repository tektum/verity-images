#!/bin/sh
set -eu

# Every container runs with --network none: the smoke test never queries a
# third-party data source. The engine-backed `enum` is not exercised because
# the engine resolves and contacts external services at startup; the offline
# graph-database commands are exercised against a locally seeded database.
image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - amass=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'amass package pin not found' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run() {
  timeout 60 docker run --rm --network none "$@"
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/amass"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

version=$(run "$image" -version 2>&1) || fail "amass -version failed: $version"
[ "$version" = "v$expected_version" ] || fail "unexpected version '$version', want v$expected_version"

# `amass enum` launches its engine through nohup.
run --entrypoint nohup "$image" true >/dev/null 2>&1 || fail 'nohup is missing; amass enum cannot start its engine'

# Create an empty graph database through amass itself, so the schema comes from
# the shipped asset-db migrations.
chmod 0777 "$work"
run -v "$work:/data" "$image" subs -dir /data -d example.test -names >"$work/empty.txt" 2>&1 ||
  { cat "$work/empty.txt" >&2; fail 'amass subs on an empty database failed'; }
grep -Fx 'No names were discovered' "$work/empty.txt" >/dev/null ||
  { cat "$work/empty.txt" >&2; fail 'empty database did not report zero names'; }
[ -f "$work/asset.db" ] || fail 'amass did not create asset.db under -dir'
run -v "$work:/data" --entrypoint chmod "$image" 0666 /data/asset.db /data/asset.db-wal /data/asset.db-shm ||
  fail 'cannot make the database writable for seeding'

# Seed a subdomain tree and one out-of-scope name the way the engine records
# them: FQDN assets linked by "node" simple relations.
python3 - "$work/asset.db" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
fqdn_type = con.execute("SELECT id FROM entity_type_lu WHERE name = 'fqdn'").fetchone()[0]
relation = con.execute("SELECT id FROM edge_type_lu WHERE name = 'simplerelation'").fetchone()[0]
ids = {}
for name in ("example.test", "www.example.test", "api.example.test", "v1.api.example.test", "other.invalid"):
    con.execute("INSERT INTO fqdn (fqdn, attrs) VALUES (?, '{}')", (name,))
    ids[name] = con.execute(
        "SELECT entity_id FROM entity WHERE etype_id = ? AND natural_key = ?", (fqdn_type, name)
    ).fetchone()[0]
for parent, child in (
    ("example.test", "www.example.test"),
    ("example.test", "api.example.test"),
    ("api.example.test", "v1.api.example.test"),
    ("example.test", "other.invalid"),
):
    con.execute(
        "INSERT INTO edge (etype_id, label, content, from_entity_id, to_entity_id) VALUES (?, 'node', ?, ?, ?)",
        (relation, '{"label":"node"}', ids[parent], ids[child]),
    )
con.commit()
con.close()
EOF

run -v "$work:/data" "$image" subs -dir /data -d example.test -names >"$work/names.txt" 2>&1 ||
  { cat "$work/names.txt" >&2; fail 'amass subs on the seeded database failed'; }
sort "$work/names.txt" >"$work/names.sorted"
printf '%s\n' api.example.test example.test v1.api.example.test www.example.test >"$work/names.want"
cmp -s "$work/names.sorted" "$work/names.want" ||
  { cat "$work/names.txt" >&2; fail 'amass subs did not list exactly the in-scope names'; }

run -v "$work:/data" "$image" subs -dir /data -d unrelated.test -names >"$work/other.txt" 2>&1 ||
  { cat "$work/other.txt" >&2; fail 'amass subs for an unknown domain failed'; }
grep -Fx 'No names were discovered' "$work/other.txt" >/dev/null ||
  { cat "$work/other.txt" >&2; fail 'unknown domain returned names'; }

run -v "$work:/data" "$image" viz -dot -dir /data -d example.test -o /data >"$work/viz.txt" 2>&1 ||
  { cat "$work/viz.txt" >&2; fail 'amass viz -dot failed'; }
[ -s "$work/amass.dot" ] || { cat "$work/viz.txt" >&2; fail 'amass viz did not write amass.dot'; }
grep -F 'label="v1.api.example.test"' "$work/amass.dot" >/dev/null || fail 'DOT graph lacks a seeded node'
grep -F '[label="node"]' "$work/amass.dot" >/dev/null || fail 'DOT graph lacks node relations'

if run "$image" bogus >"$work/sub.txt" 2>&1; then
  fail 'unknown subcommand was accepted'
fi
grep -F 'subcommand provided but not defined: bogus' "$work/sub.txt" >/dev/null ||
  { cat "$work/sub.txt" >&2; fail 'unknown subcommand error does not name it'; }
if run "$image" subs -no-such-flag >"$work/flag.txt" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -F 'flag provided but not defined: -no-such-flag' "$work/flag.txt" >/dev/null ||
  { cat "$work/flag.txt" >&2; fail 'unknown flag error does not name it'; }

printf '%s\n' "amass $expected_version smoke test passed"
