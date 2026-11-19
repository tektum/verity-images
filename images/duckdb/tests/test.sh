#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
volume=verity-duckdb-smoke-$$

cleanup() {
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

run() {
  docker run --rm --network none "$@"
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/duckdb"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /data ] || fail 'unexpected working directory'

version=$(run "$image" --version)
case "$version" in
  "v$expected_version "*) ;;
  *) fail "unexpected DuckDB version: $version" ;;
esac
library=$(run "$image" -noheader -csv -c 'select library_version from pragma_version();')
[ "$library" = "v$expected_version" ] || fail "unexpected DuckDB library version: $library"

# A query through the CLI, on an in-memory database.
result=$(run "$image" -noheader -csv -c \
  "select g % 3 as k, count(*) as n, sum(g) as s from range(1, 11) t(g) group by k order by k;")
expected=$(printf '0,3,18\n1,4,22\n2,3,15')
[ "$result" = "$expected" ] || fail "unexpected aggregate result: $result"

# SQL on stdin, as `duckdb < script.sql` is used.
stdin=$(printf "select upper('verity') || '-' || 6 * 7;\n" | docker run --rm -i --network none "$image" -noheader -csv)
[ "$stdin" = VERITY-42 ] || fail "unexpected stdin query result: $stdin"

loaded=$(run "$image" -noheader -csv -c \
  "select string_agg(extension_name, ' ' order by extension_name) from duckdb_extensions()
   where loaded and extension_name in ('core_functions', 'icu', 'json', 'parquet');")
[ "$loaded" = 'core_functions icu json parquet' ] || fail "built-in extensions not loaded: $loaded"

json=$(run "$image" -json -c "select json_extract_string('{\"a\":{\"b\":\"duck\"}}', '\$.a.b') as v;")
printf '%s' "$json" | tr -d ' \n' | grep -Fq '[{"v":"duck"}]' || fail "JSON query failed: $json"

icu=$(run "$image" -noheader -csv -c \
  "set timezone = 'America/New_York';
   select strftime(timestamptz '2026-07-01 12:00:00+00', '%H:%M');")
[ "$icu" = 08:00 ] || fail "ICU time zone conversion failed: $icu"

# Persist a database and a parquet file on a volume as the image user, then
# read both back from a fresh container.
docker volume create "$volume" >/dev/null
run -v "$volume:/data" "$image" smoke.duckdb -c \
  "create table items (id integer primary key, name varchar not null unique, qty integer not null);
   insert into items values (1, 'alpha', 3), (2, 'beta', 5);
   copy items to 'items.parquet' (format parquet, compression zstd);" ||
  fail 'create, insert, and parquet export failed'

persisted=$(run -v "$volume:/data" "$image" -noheader -csv smoke.duckdb -c \
  "insert into items values (3, 'gamma', 7);
   select name, qty from items order by id;
   select sum(qty) from read_parquet('items.parquet');")
expected=$(printf 'alpha,3\nbeta,5\ngamma,7\n8')
[ "$persisted" = "$expected" ] || fail "unexpected persisted result: $persisted"

# Negative tests: invalid SQL, a missing table, and a constraint violation must
# fail with a non-zero exit and a parser, catalog, or constraint error.
if out=$(run "$image" -c 'selec 1;' 2>&1); then
  fail 'invalid SQL unexpectedly succeeded'
fi
printf '%s\n' "$out" | grep -Fq 'Parser Error' || fail "invalid SQL gave an unexpected error: $out"

if out=$(run "$image" -c 'select * from missing_table;' 2>&1); then
  fail 'query on a missing table unexpectedly succeeded'
fi
printf '%s\n' "$out" | grep -Fq 'Catalog Error' || fail "missing table gave an unexpected error: $out"

if out=$(run -v "$volume:/data" "$image" smoke.duckdb -c "insert into items values (4, 'alpha', 1);" 2>&1); then
  fail 'unique constraint violation unexpectedly succeeded'
fi
printf '%s\n' "$out" | grep -Fq 'Constraint Error' || fail "duplicate key gave an unexpected error: $out"

count=$(run -v "$volume:/data" "$image" -noheader -csv smoke.duckdb -c 'select count(*) from items;')
[ "$count" = 3 ] || fail "failed statements changed row count: $count"

if out=$(run -v "$volume:/data" "$image" -readonly smoke.duckdb -c "delete from items;" 2>&1); then
  fail 'write to a read-only database unexpectedly succeeded'
fi
printf '%s\n' "$out" | grep -Fq 'read-only mode' || fail "read-only write gave an unexpected error: $out"
count=$(run -v "$volume:/data" "$image" -noheader -csv smoke.duckdb -c 'select count(*) from items;')
[ "$count" = 3 ] || fail "read-only write changed row count: $count"

printf 'SMOKE PASS version=%s\n' "$expected_version"
