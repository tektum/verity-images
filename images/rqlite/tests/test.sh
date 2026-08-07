#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-rqlite-test-$$"
volume="verity-rqlite-data-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

start() {
  docker run --name "$container" -d --read-only --user 65532 \
    -v "$volume:/rqlite/data" \
    -p 127.0.0.1::4001 -p 127.0.0.1::4002 "$image" \
    -http-addr 0.0.0.0:4001 -http-adv-addr 127.0.0.1:4001 \
    -raft-addr 0.0.0.0:4002 -raft-adv-addr 127.0.0.1:4002 /rqlite/data >/dev/null
  http_port=$(docker port "$container" 4001/tcp | awk -F: 'NR == 1 { print $2 }')
  raft_port=$(docker port "$container" 4002/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$http_port" ] && [ -n "$raft_port" ] || fail 'ports 4001 and 4002 were not published'

  attempts=0
  until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$http_port/readyz" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || fail 'rqlite did not become ready'
    sleep 1
  done
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/rqlited"]' ] || fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'unexpected user'
[ "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = '{"/rqlite/data":{}}' ] || fail 'missing /rqlite/data volume'
docker run --rm "$image" -version 2>&1 | grep -Fq 'rqlited v8.43.4' || fail 'unexpected rqlite version'

docker volume create "$volume" >/dev/null
start

raft_probe=$(curl --verbose --connect-timeout 2 --max-time 3 "http://127.0.0.1:$raft_port/" 2>&1 || true)
printf '%s\n' "$raft_probe" | grep -Fq 'Connected to 127.0.0.1' || fail 'Raft listener is not accepting connections on port 4002'

write_response=$(curl --fail --silent --show-error -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "[\"CREATE TABLE smoke (id INTEGER PRIMARY KEY, value TEXT)\",\"INSERT INTO smoke(id, value) VALUES(1, 'persisted')\"]" \
  "http://127.0.0.1:$http_port/db/execute")
printf '%s\n' "$write_response" | grep -Fq '"rows_affected":1' || fail 'SQL write failed'

read_response=$(curl --fail --silent --show-error --get \
  --data-urlencode 'q=SELECT id, value FROM smoke' \
  "http://127.0.0.1:$http_port/db/query")
printf '%s\n' "$read_response" | grep -Eq '"values"[[:space:]]*:[[:space:]]*\[\[1,"persisted"\]\]' || fail 'SQL read failed'

error_response=$(curl --fail --silent --show-error --get \
  --data-urlencode 'q=SELECT * FROM definitely_missing' \
  "http://127.0.0.1:$http_port/db/query")
printf '%s\n' "$error_response" | grep -Fq '"error":"no such table: definitely_missing"' || fail 'invalid SQL did not return the documented query error'

docker rm -f "$container" >/dev/null
start

persisted_response=$(curl --fail --silent --show-error --get \
  --data-urlencode 'q=SELECT id, value FROM smoke' \
  "http://127.0.0.1:$http_port/db/query")
printf '%s\n' "$persisted_response" | grep -Eq '"values"[[:space:]]*:[[:space:]]*\[\[1,"persisted"\]\]' || fail 'data did not survive restart'

printf 'SMOKE PASS image=%s\n' "$image"
