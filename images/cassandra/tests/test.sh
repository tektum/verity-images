#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-cassandra-test-$$"
volume="verity-cassandra-data-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker run --rm --entrypoint id "$image" -g)" = 65532 ] || fail 'image group is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/share/java/cassandra/bin/cassandra"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-f"]' ] || fail 'unexpected image command'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /var/lib/cassandra ] || fail 'unexpected image working directory'
docker run --rm --entrypoint sh "$image" -c 'test -w /var/lib/cassandra && test -w /var/log/cassandra' || fail 'Cassandra paths are not writable'
docker run --rm --entrypoint java "$image" -version 2>&1 | grep -q 'version "21' || fail 'Java 21 is missing'
docker run --rm "$image" -v >/dev/null || fail 'Cassandra version command failed'
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d -v "$volume:/var/lib/cassandra" \
    -e MAX_HEAP_SIZE=512M "$image" >/dev/null

  i=0
  until docker exec "$container" cqlsh -e 'SELECT release_version FROM system.local' >/dev/null 2>&1; do
    [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'Cassandra exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 120 ] || {
      docker logs "$container" >&2
      fail 'Cassandra did not become ready'
    }
    sleep 1
  done
}

start_server
docker exec "$container" cqlsh -e \
  "CREATE KEYSPACE verity WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}; CREATE TABLE verity.smoke (id int PRIMARY KEY, value text); INSERT INTO verity.smoke (id, value) VALUES (1, 'persisted');"
[ "$(docker exec "$container" cqlsh -e 'SELECT value FROM verity.smoke WHERE id = 1' | grep -c persisted)" = 1 ] || fail 'CQL write/read failed'
docker stop --time 60 "$container" >/dev/null
docker rm "$container" >/dev/null

start_server
[ "$(docker exec "$container" cqlsh -e 'SELECT value FROM verity.smoke WHERE id = 1' | grep -c persisted)" = 1 ] || fail 'persisted CQL row was not restored'
if error=$(docker exec "$container" cqlsh -e 'NOT VALID CQL' 2>&1); then
  fail 'invalid CQL unexpectedly succeeded'
fi
printf '%s\n' "$error" | grep -qi 'syntax' || fail 'invalid CQL did not report a syntax error'

printf 'SMOKE PASS image=%s\n' "$image"
