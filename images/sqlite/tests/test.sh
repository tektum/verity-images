#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- sqlite=\([0-9][0-9.]*\)-r[0-9][0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'SQLite package version not found\n' >&2; exit 1; }
volume=verity-sqlite-smoke-$$

cleanup() {
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/sqlite3"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /data ] || fail 'unexpected working directory'

version=$(docker run --rm --network none "$image" -version)
case "$version" in
  "$expected_version "*) ;;
  *) fail "unexpected SQLite version: $version" ;;
esac
library=$(docker run --rm --network none "$image" :memory: 'select sqlite_version();')
[ "$library" = "$expected_version" ] || fail "unexpected SQLite library version: $library"

docker volume create "$volume" >/dev/null
docker run --rm --network none -v "$volume:/data" "$image" /data/smoke.db \
  "create table items (id integer primary key, name text not null unique, qty integer not null);
   insert into items (name, qty) values ('alpha', 3), ('beta', 5);" ||
  fail 'create and insert failed'

# A second container proves the database file persisted on the volume.
result=$(docker run --rm --network none -v "$volume:/data" "$image" -separator '|' smoke.db \
  "insert into items (name, qty) values ('gamma', 7);
   select name, qty from items order by id;
   select sum(qty) from items;
   pragma integrity_check;")
expected=$(printf 'alpha|3\nbeta|5\ngamma|7\n15\nok')
[ "$result" = "$expected" ] || fail "unexpected query result: $result"

json=$(docker run --rm --network none -v "$volume:/data" "$image" -json smoke.db \
  "select json_object('n', count(*)) as doc from items;")
printf '%s' "$json" | grep -q '"doc":"{\\"n\\":3}"' || fail "JSON1 query failed: $json"

fts=$(docker run --rm --network none "$image" :memory: \
  "create virtual table docs using fts5(body);
   insert into docs values ('verity sqlite smoke'), ('unrelated');
   select count(*) from docs where docs match 'smoke';")
[ "$fts" = 1 ] || fail "FTS5 query failed: $fts"

if docker run --rm --network none -v "$volume:/data" "$image" smoke.db \
  "insert into items (name, qty) values ('alpha', 1);" >/dev/null 2>&1; then
  fail 'unique constraint violation unexpectedly succeeded'
fi
if docker run --rm --network none -v "$volume:/data" "$image" smoke.db 'select * from missing;' >/dev/null 2>&1; then
  fail 'query on missing table unexpectedly succeeded'
fi
count=$(docker run --rm --network none -v "$volume:/data" "$image" smoke.db 'select count(*) from items;')
[ "$count" = 3 ] || fail "failed statements changed row count: $count"

printf 'SMOKE PASS version=%s\n' "$expected_version"
