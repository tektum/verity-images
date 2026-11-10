#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
log4j_version=$(sed -n 's/^  log4j: \([0-9.]*\).*$/\1/p' "$recipe")
[ -n "$log4j_version" ] || { printf 'Log4j version not found\n' >&2; exit 1; }
network=verity-flink-$$
jobmanager=verity-flink-jobmanager-$$
taskmanager=verity-flink-taskmanager-$$
work=$(mktemp -d)

cleanup() {
  docker rm -f "$jobmanager" "$taskmanager" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cluster_fail() {
  docker logs "$jobmanager" >&2 2>&1 || true
  docker logs "$taskmanager" >&2 2>&1 || true
  fail "$1"
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 9999 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/docker-entrypoint.sh"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["help"]' ] || fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /opt/flink ] || fail 'unexpected working directory'
docker image inspect -f '{{json .Config.Env}}' "$image" | grep -q '"FLINK_HOME=/opt/flink"' ||
  fail 'FLINK_HOME is not /opt/flink'
[ "$(docker run --rm --entrypoint id "$image" -u)" = 9999 ] || fail 'runtime user is not 9999'
[ "$(docker run --rm --entrypoint id "$image" -g)" = 9999 ] || fail 'runtime group is not 9999'

docker run --rm "$image" >"$work/help.log" 2>&1 || fail 'default help command failed'
grep -q 'Usage: docker-entrypoint.sh (jobmanager|standalone-job|taskmanager|history-server)' "$work/help.log" ||
  fail 'unexpected help output'
grep -q WARNING "$work/help.log" && fail 'entrypoint warned (jemalloc or root user)'

docker run --rm --entrypoint java "$image" -version >"$work/java.log" 2>&1 || fail 'Java failed'
grep -q 'version "17' "$work/java.log" || fail 'Java 17 is missing'
docker run --rm --entrypoint flink "$image" --version >"$work/version.log" 2>&1 || fail 'flink --version failed'
grep -q "^Version: $expected_version," "$work/version.log" || fail 'unexpected Flink version'

docker run --rm --entrypoint sh "$image" -c 'ls /opt/flink/lib' >"$work/lib.log" || fail 'cannot list lib'
for jar in log4j-1.2-api log4j-api log4j-core log4j-layout-template-json log4j-slf4j-impl; do
  grep -qx "$jar-$log4j_version.jar" "$work/lib.log" || fail "$jar is not $log4j_version"
done
[ "$(grep -c '^log4j-' "$work/lib.log")" = 5 ] || fail 'unexpected Log4j jar set'

plugin=flink-s3-fs-hadoop-$expected_version.jar
docker run --rm -e ENABLE_BUILT_IN_PLUGINS="$plugin" "$image" >"$work/plugin.log" 2>&1 ||
  fail 'enabling a built-in plugin failed'
grep -q "Successfully enabled $plugin" "$work/plugin.log" || fail 'built-in plugin was not enabled'
if docker run --rm -e ENABLE_BUILT_IN_PLUGINS=missing.jar "$image" >"$work/missing.log" 2>&1; then
  fail 'missing plugin unexpectedly succeeded'
fi
grep -q 'Plugin missing.jar does not exist. Exiting.' "$work/missing.log" ||
  fail 'missing plugin did not fail clearly'

properties="jobmanager.rpc.address: $jobmanager"
docker network create "$network" >/dev/null
docker run -d --name "$jobmanager" --network "$network" -e FLINK_PROPERTIES="$properties" \
  "$image" jobmanager >/dev/null
docker run -d --name "$taskmanager" --network "$network" -e FLINK_PROPERTIES="$properties" \
  "$image" taskmanager >/dev/null

# The image has no curl or wget; speak HTTP through bash.
rest() {
  docker exec "$jobmanager" bash -c \
    "exec 3<>/dev/tcp/127.0.0.1/8081; printf 'GET $1 HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3; cat <&3"
}

i=0
until rest /overview 2>/dev/null | grep -q '"taskmanagers":1,'; do
  for container in "$jobmanager" "$taskmanager"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] ||
      cluster_fail "$container exited before the cluster became ready"
  done
  i=$((i + 1))
  [ "$i" -lt 120 ] || cluster_fail 'cluster did not register a task manager'
  sleep 1
done
rest /overview | grep -q "\"flink-version\":\"$expected_version\"" || cluster_fail 'REST reports an unexpected version'

docker exec "$jobmanager" flink run /opt/flink/examples/streaming/WordCount.jar >"$work/run.log" 2>&1 || {
  cat "$work/run.log" >&2
  cluster_fail 'WordCount submission failed'
}
job=$(sed -n 's/^Job has been submitted with JobID \([0-9a-f]*\)$/\1/p' "$work/run.log")
[ -n "$job" ] || { cat "$work/run.log" >&2; cluster_fail 'no job id in the submission output'; }
i=0
until rest "/jobs/$job" | grep -q '"state":"FINISHED"'; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || cluster_fail "WordCount job $job did not reach FINISHED"
  sleep 1
done
docker logs "$taskmanager" 2>&1 | grep -q '(be,2)' || cluster_fail 'WordCount output is missing from the task manager'

printf 'SMOKE PASS image=%s\n' "$image"
