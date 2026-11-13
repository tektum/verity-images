#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
recipe="$(dirname "$0")/../melange.yaml"
version=$(sed -n 's/^  version: "\([0-9.]*\)".*$/\1/p' "$recipe")
label="verity-test=dbmate-$$"
work=$(mktemp -d)

trap 'rm -rf "$work"' EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -n "$version" ] || fail 'could not read the recipe version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dbmate"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

run() {
  docker run --rm --label "$label" --network none --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$work/project:/work" "$image" "$@"
}

mkdir -p "$work/project/db/migrations"
cat >"$work/project/db/migrations/20260101000000_create_accounts.sql" <<'SQL'
-- migrate:up
CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
INSERT INTO accounts (id, name) VALUES (1, 'ada');

-- migrate:down
DROP TABLE accounts;
SQL
cat >"$work/project/db/migrations/20260102000000_add_email.sql" <<'SQL'
-- migrate:up
ALTER TABLE accounts ADD COLUMN email TEXT;

-- migrate:down
ALTER TABLE accounts DROP COLUMN email;
SQL
chmod -R a+rwX "$work/project"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
out=$(run --version) || fail 'version failed'
test "$out" = "dbmate version $version" || fail "version does not report $version: $out"

# Negative: an unknown flag is rejected.
if run --definitely-not-a-flag >"$work/bad.log" 2>&1; then
  fail 'unknown flag was accepted'
fi
grep -q 'flag provided but not defined' "$work/bad.log" ||
  fail "unexpected unknown-flag error: $(cat "$work/bad.log")"

url=sqlite:/work/db/app.sqlite3

# Apply both migrations; dbmate dumps the schema with the bundled sqlite3 client.
run --url "$url" up >"$work/up.log" 2>&1 || fail "up failed: $(cat "$work/up.log")"
grep -q 'Applying: 20260101000000_create_accounts.sql' "$work/up.log" ||
  fail "first migration not applied: $(cat "$work/up.log")"
grep -q 'Applying: 20260102000000_add_email.sql' "$work/up.log" ||
  fail "second migration not applied: $(cat "$work/up.log")"
test -s "$work/project/db/schema.sql" || fail 'schema.sql was not written'
grep -q 'CREATE TABLE accounts' "$work/project/db/schema.sql" ||
  fail "schema.sql lacks the accounts table: $(cat "$work/project/db/schema.sql")"
grep -q 'email TEXT' "$work/project/db/schema.sql" ||
  fail "schema.sql lacks the email column: $(cat "$work/project/db/schema.sql")"
grep -q "('20260102000000')" "$work/project/db/schema.sql" ||
  fail 'schema.sql does not record the applied versions'

out=$(run --url "$url" status --exit-code) || fail "status reports pending migrations: $out"
printf '%s\n' "$out" | grep -q 'Applied: 2' || fail "unexpected status: $out"

# Data written by the migration is readable with the bundled sqlite3 client.
out=$(docker run --rm --label "$label" --network none --entrypoint /usr/bin/sqlite3 \
  -v "$work/project:/work" "$image" /work/db/app.sqlite3 'SELECT name FROM accounts WHERE id = 1;')
test "$out" = ada || fail "unexpected row: $out"

# Rollback undoes only the latest migration.
run --url "$url" rollback >"$work/rollback.log" 2>&1 || fail "rollback failed: $(cat "$work/rollback.log")"
grep -q 'Rolling back: 20260102000000_add_email.sql' "$work/rollback.log" ||
  fail "rollback did not undo the latest migration: $(cat "$work/rollback.log")"
if grep -q 'email TEXT' "$work/project/db/schema.sql"; then
  fail 'schema.sql still has the email column after rollback'
fi

# Negative: a broken migration fails and is not recorded.
cat >"$work/project/db/migrations/20260103000000_broken.sql" <<'SQL'
-- migrate:up
CREATE TABLE broken (id INTEGER PRIMARY KEY,;

-- migrate:down
DROP TABLE broken;
SQL
chmod a+r "$work/project/db/migrations/20260103000000_broken.sql"
if run --url "$url" --no-dump-schema up >"$work/broken.log" 2>&1; then
  fail 'a broken migration was accepted'
fi
grep -qi 'syntax error' "$work/broken.log" || fail "unexpected broken-migration error: $(cat "$work/broken.log")"

# Dump clients for the other supported databases are present.
docker run --rm --label "$label" --network none --entrypoint /usr/bin/pg_dump "$image" --version |
  grep -q '^pg_dump (PostgreSQL) ' || fail 'pg_dump is missing'
docker run --rm --label "$label" --network none --entrypoint /usr/bin/mariadb-dump "$image" --version |
  grep -q 'MariaDB' || fail 'mariadb-dump is missing'

printf 'SMOKE PASS\n'
