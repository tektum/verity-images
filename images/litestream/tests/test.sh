#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
work=$(mktemp -d)
container="verity-litestream-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/litestream"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["replicate"]' || fail 'unexpected default command'

run() {
  docker run --rm --platform "$platform" --user "$(id -u):$(id -g)" --network none \
    -v "$work:/work" "$image" "$@"
}

run version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null ||
  fail 'version output is missing'

# Negative: an unknown subcommand and a missing config both exit non-zero.
if run definitely-invalid >"$work/invalid" 2>&1; then
  fail 'unknown command unexpectedly succeeded'
fi
if run replicate -config /work/missing.yml >"$work/missing" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'missing.yml' "$work/missing" >/dev/null || fail 'missing config diagnostic is missing'

# Create a WAL-mode database with rows; the image has no sqlite shell.
python3 - "$work/app.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('PRAGMA journal_mode=WAL')
con.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)')
con.executemany('INSERT INTO t (v) VALUES (?)', [('one',), ('two',)])
con.commit()
con.close()
PY
mkdir -p "$work/replica"
chmod 777 "$work" "$work/replica"
chmod 666 "$work/app.db"*
cat >"$work/litestream.yml" <<'EOF'
dbs:
  - path: /work/app.db
    replica:
      type: file
      path: /work/replica
EOF

docker run -d --name "$container" --platform "$platform" --user "$(id -u):$(id -g)" --network none \
  -v "$work:/work" "$image" replicate -config /work/litestream.yml >/dev/null

i=0
until [ -n "$(find "$work/replica" -type f -name '*.ltx' 2>/dev/null | head -n 1)" ]; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    docker logs "$container" >&2 || true
    fail 'litestream did not write a replica snapshot'
  fi
  sleep 1
done

# Write more rows while replicating, then wait for them to be shipped.
python3 - "$work/app.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO t (v) VALUES ('three')")
con.commit()
con.close()
PY
sleep 5

# Clean stop on SIGTERM.
docker stop --time 20 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
  fail 'litestream did not exit cleanly on SIGTERM'

# Restore into a new path and assert every row came back.
run restore -config /work/litestream.yml -o /work/restored.db /work/app.db >"$work/restore.log" 2>&1 ||
  { cat "$work/restore.log" >&2; fail 'litestream restore failed'; }
rows=$(python3 - "$work/restored.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
print(','.join(r[0] for r in con.execute('SELECT v FROM t ORDER BY id')))
PY
)
test "$rows" = 'one,two,three' || fail "restored rows differ: $rows"

printf 'SMOKE PASS image=%s\n' "$image"
