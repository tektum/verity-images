#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)"$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container=verity-zookeeper-$$
invalid_container=$container-invalid
volume=verity-zookeeper-data-$$
log_volume=verity-zookeeper-datalog-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" "$invalid_container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" "$log_volume" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 1000 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/docker-entrypoint.sh"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["zkServer.sh","start-foreground"]' ] ||
  fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = "/apache-zookeeper-${expected_version}-bin" ] ||
  fail 'unexpected working directory'
[ "$(docker run --rm --entrypoint id "$image" -u)" = 1000 ] || fail 'runtime user is not 1000'
[ "$(docker run --rm --entrypoint id "$image" -g)" = 1000 ] || fail 'runtime group is not 1000'

for path in /data /datalog /logs; do
  docker image inspect -f '{{json .Config.Volumes}}' "$image" | grep -q "\"$path\"" ||
    fail "missing volume $path"
done

docker run --rm --entrypoint java "$image" -version >"$work/java.log" 2>&1 || fail 'Java failed'
grep -q 'version "17' "$work/java.log" || fail 'Java 17 is missing'
docker run --rm --entrypoint zkServer.sh "$image" version >"$work/version.log" 2>&1 ||
  fail 'ZooKeeper version command failed'
grep -q "Apache ZooKeeper, version $expected_version" "$work/version.log" || fail 'unexpected ZooKeeper version'

docker run --rm "$image" sh -c \
  'grep -qx "dataDir=/data" /conf/zoo.cfg &&
   grep -qx "dataLogDir=/datalog" /conf/zoo.cfg &&
   grep -qx "admin.enableServer=false" /conf/zoo.cfg &&
   grep -qx "server.1=localhost:2888:3888;2181" /conf/zoo.cfg' ||
  fail 'safe standalone configuration was not generated'

docker volume create "$volume" >/dev/null
docker volume create "$log_volume" >/dev/null
start_server() {
  docker run -d --name "$container" -v "$volume:/data" -v "$log_volume:/datalog" \
    -e ZOO_4LW_COMMANDS_WHITELIST=ruok "$image" >/dev/null
  i=0
  until [ "$(docker exec "$container" sh -c 'printf ruok | nc -w 1 127.0.0.1 2181' 2>/dev/null || true)" = imok ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'ZooKeeper exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 60 ] || {
      docker logs "$container" >&2
      fail 'ZooKeeper did not become ready'
    }
    sleep 1
  done
}

start_server
docker exec "$container" zkCli.sh -server 127.0.0.1:2181 create /verity persisted >"$work/create.log" 2>&1 ||
  fail 'ZooKeeper write failed'
docker stop --time 30 "$container" >/dev/null
docker rm "$container" >/dev/null
start_server
docker exec "$container" zkCli.sh -server 127.0.0.1:2181 get /verity >"$work/get.log" 2>&1 ||
  fail 'ZooKeeper read after restart failed'
grep -qx persisted "$work/get.log" || fail 'ZooKeeper data did not persist'
docker rm -f "$container" >/dev/null

if docker run --name "$invalid_container" -e ZOO_CONF_DIR=/missing/conf "$image" \
  >"$work/missing-conf.log" 2>&1
then
  fail 'missing configuration directory unexpectedly succeeded'
fi
grep -q '/missing/conf/zoo.cfg: No such file or directory' "$work/missing-conf.log" ||
  fail 'missing configuration directory did not fail clearly'
docker rm "$invalid_container" >/dev/null

if docker run --name "$invalid_container" -e ZOO_DATA_DIR=/missing/data "$image" \
  >"$work/missing-data.log" 2>&1
then
  fail 'missing data directory unexpectedly succeeded'
fi
grep -q '/missing/data/myid: No such file or directory' "$work/missing-data.log" ||
  fail 'missing data directory did not fail clearly'

printf 'SMOKE PASS image=%s\n' "$image"
