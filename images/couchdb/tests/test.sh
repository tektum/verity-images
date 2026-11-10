#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-couchdb-test-$$"
volume="verity-couchdb-data-$$"
workdir=$(mktemp -d)
password="verity-test-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" "$container-noadmin" "$container-badconf" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/docker-entrypoint.sh"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["/opt/couchdb/bin/couchdb"]' ] || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/couchdb ] || fail 'unexpected image working directory'
docker image inspect --format '{{json .Config.Volumes}}' "$image" | grep -q '/opt/couchdb/data' || fail 'data volume is not declared'
docker run --rm --entrypoint sh "$image" -c 'test -w /opt/couchdb/data && test -w /opt/couchdb/etc/local.d && test -w /opt/couchdb/var/log' ||
  fail 'CouchDB paths are not writable by the image user'
docker run --rm --entrypoint couchjs "$image" -V | grep -q 'Apache CouchDB 3\.5\.' || fail 'couchjs version check failed'
docker run --rm --entrypoint sh "$image" -c 'test -f /opt/couchdb/share/server/main.js && test -f /opt/couchdb/share/www/index.html' ||
  fail 'JavaScript query server or Fauxton assets are missing'

# Negative: CouchDB 3 refuses to start without an admin account and must say why.
if output=$(timeout 120 docker run --rm --name "$container-noadmin" "$image" 2>&1); then
  fail 'CouchDB started without an admin account'
fi
printf '%s\n' "$output" | grep -q 'will no longer run in "Admin Party"' ||
  fail "missing readable admin error, got: $output"

# Negative: an invalid configuration file must stop the server with a readable error.
printf '[chttpd]\nport = not-a-port\n' >"$workdir/10-invalid.ini"
chmod 644 "$workdir/10-invalid.ini"
status=0
output=$(timeout 120 docker run --rm --name "$container-badconf" \
  -e COUCHDB_USER=admin -e "COUCHDB_PASSWORD=$password" \
  -v "$workdir/10-invalid.ini:/opt/couchdb/etc/local.d/10-invalid.ini:ro" \
  "$image" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'invalid configuration unexpectedly started'
[ "$status" -ne 124 ] || fail 'invalid configuration kept the server running until the timeout'
printf '%s\n' "$output" | grep -q 'Error starting Apache CouchDB' || fail "invalid configuration gave no startup error: $output"
printf '%s\n' "$output" | grep -q 'not-a-port' || fail "startup error does not name the invalid value: $output"

printf '[couchdb]\nsingle_node = true\n' >"$workdir/10-single.ini"
chmod 644 "$workdir/10-single.ini"
docker volume create "$volume" >/dev/null

api() {
  docker exec "$container" curl -fsS -u "admin:$password" "$@"
}

start_server() {
  docker run --name "$container" -d \
    -e COUCHDB_USER=admin -e "COUCHDB_PASSWORD=$password" \
    -v "$volume:/opt/couchdb/data" \
    -v "$workdir/10-single.ini:/opt/couchdb/etc/local.d/10-single.ini:ro" \
    "$image" >/dev/null

  i=0
  until api http://127.0.0.1:5984/_up 2>/dev/null | grep -q '"status":"ok"'; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'CouchDB exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 90 ] || {
      docker logs "$container" >&2
      fail 'CouchDB did not become ready'
    }
    sleep 1
  done
}

start_server
welcome=$(docker exec "$container" curl -fsS http://127.0.0.1:5984/)
printf '%s\n' "$welcome" | grep -q '"couchdb":"Welcome"' || fail "unexpected welcome body: $welcome"
printf '%s\n' "$welcome" | grep -q '"version":"3\.5\.' || fail "unexpected CouchDB version: $welcome"

[ "$(docker exec "$container" curl -s -L -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/_utils/)" = 200 ] ||
  fail 'Fauxton is not served at /_utils/'

# Authentication is enforced.
code=$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:5984/anonymous)
[ "$code" = 401 ] || fail "anonymous database creation returned $code, expected 401"

api -X PUT http://127.0.0.1:5984/verity >/dev/null || fail 'database creation failed'
api -X PUT -H 'Content-Type: application/json' -d '{"value":"persisted"}' \
  http://127.0.0.1:5984/verity/smoke >/dev/null || fail 'document write failed'
[ "$(api http://127.0.0.1:5984/verity/smoke | grep -c persisted)" = 1 ] || fail 'document read failed'

# The JavaScript query server (couchjs) must work, not just the HTTP layer.
api -X PUT -H 'Content-Type: application/json' \
  -d '{"views":{"by_value":{"map":"function(doc){ emit(doc.value, 1); }"}}}' \
  http://127.0.0.1:5984/verity/_design/smoke >/dev/null || fail 'design document write failed'
[ "$(api 'http://127.0.0.1:5984/verity/_design/smoke/_view/by_value?key=%22persisted%22' | grep -c '"id":"smoke"')" = 1 ] ||
  fail 'JavaScript view query failed'

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || {
  docker logs "$container" >&2
  fail 'CouchDB did not exit cleanly on SIGTERM'
}
docker rm "$container" >/dev/null

start_server
[ "$(api http://127.0.0.1:5984/verity/smoke | grep -c persisted)" = 1 ] || fail 'persisted document was not restored after restart'
