#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
here=$(cd "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
name=verity-debezium-server-$$
work=$(mktemp -d)
chmod 755 "$work"

cleanup() {
  docker rm -f "$name" "$name-noconf" "$name-invalid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" 2>&1 | tail -n 60 >&2 || true
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

# Image contract mirrors quay.io/debezium/server: UID 185, CMD /debezium/run.sh, WORKDIR /debezium.
[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 185 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Cmd}}' "$image")" = '["/debezium/run.sh"]' ] ||
  fail 'unexpected command'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /debezium ] ||
  fail 'unexpected working directory'
[ "$(docker run --rm --entrypoint id "$image" -u)" = 185 ] || fail 'runtime user is not 185'
[ "$(docker run --rm --entrypoint id "$image" -g)" = 0 ] || fail 'runtime group is not 0'

# Layout: launcher, runner jar for this release, libraries, writable config and data.
docker run --rm --entrypoint sh "$image" -c '
  set -e
  test -x /debezium/run.sh
  ls /debezium/debezium-server-dist-*-runner.jar
  ls /debezium/lib/debezium-server-core-*.jar /debezium/lib/debezium-connector-postgres-*.jar
  ls /debezium/lib_metrics/opentelemetry-javaagent-*.jar
  touch /debezium/config/probe /debezium/data/probe
  test ! -e /debezium/connectors
' >"$work/layout.log" 2>&1 || { cat "$work/layout.log" >&2; fail 'unexpected /debezium layout'; }
grep -q "debezium-server-dist-${expected_version}.Final-runner.jar" "$work/layout.log" ||
  { cat "$work/layout.log" >&2; fail "runner jar is not ${expected_version}.Final"; }
grep -q "debezium-server-core-${expected_version}.Final.jar" "$work/layout.log" ||
  fail "debezium-server-core is not ${expected_version}.Final"

# JRE runtime only: java 21 is present, the compiler is not.
docker run --rm --entrypoint java "$image" -version >"$work/java.log" 2>&1 || fail 'Java failed'
grep -q 'version "21' "$work/java.log" || { cat "$work/java.log" >&2; fail 'Java 21 is missing'; }
if docker run --rm --entrypoint sh "$image" -c 'command -v javac || test -e "$JAVA_HOME/bin/javac"' >/dev/null 2>&1; then
  fail 'javac is present in the runtime image'
fi

# Debezium Server reads config/application.properties relative to /debezium. Each case writes its
# own file from $PROPS inside the container, which also proves config/ is writable by UID 185.
run_with_props() {
  # shellcheck disable=SC2016 # expanded by the container shell
  timeout 180 docker run "$@" --entrypoint sh "$image" -c '
    set -e
    printf "%s\n" "$PROPS" >/debezium/config/application.properties
    if [ -n "${STUB_PORT:-}" ]; then nc -l -p "$STUB_PORT" >/dev/null 2>&1 & fi
    exec /debezium/run.sh
  '
}

base_props='debezium.sink.type=http
debezium.sink.http.url=http://127.0.0.1:9/
debezium.format.key=json
debezium.format.value=json
debezium.source.connector.class=io.debezium.connector.postgresql.PostgresConnector
debezium.source.offset.storage.file.filename=data/offsets.dat
debezium.source.offset.flush.interval.ms=0
debezium.source.database.port=5432
debezium.source.database.user=postgres
debezium.source.database.password=unused
debezium.source.database.dbname=postgres
debezium.source.topic.prefix=smoke'

# Negative: without application.properties the server must name the missing sink type and exit non-zero.
if docker run --name "$name-noconf" "$image" >"$work/noconf.log" 2>&1; then
  cat "$work/noconf.log" >&2
  fail 'missing configuration exited 0'
fi
grep -q "Failed to load mandatory config value 'debezium.sink.type'" "$work/noconf.log" ||
  { cat "$work/noconf.log" >&2; fail 'missing configuration did not fail clearly'; }

# Negative: a Postgres source without database.hostname must fail connector validation and exit non-zero.
PROPS=$base_props
export PROPS
if run_with_props --name "$name-invalid" -e PROPS >"$work/invalid.log" 2>&1; then
  cat "$work/invalid.log" >&2
  fail 'invalid connector configuration exited 0'
fi
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name-invalid")" != 0 ] || fail 'invalid config exited 0'
grep -q "Connector configuration is not valid. The 'database.hostname' value is invalid: A value is required" \
  "$work/invalid.log" || { cat "$work/invalid.log" >&2; fail 'connector validation error does not name database.hostname'; }

# Positive: with a TCP stub that accepts the Postgres connection and never answers, the server stays
# up, Quarkus reports startup and listens on 8080, and health reports the connector as not live.
PROPS="$base_props
debezium.source.database.hostname=127.0.0.1"
run_with_props -d --name "$name" -e PROPS -e STUB_PORT=5432 \
  -p 127.0.0.1::8080 >/dev/null
port=$(docker port "$name" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 8080 is not published'
started=
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'server exited before startup'
  if curl -fsS "http://127.0.0.1:$port/q/health/started" >"$work/started.json" 2>/dev/null; then
    started=1
    break
  fi
  sleep 2
done
[ -n "$started" ] || fail 'startup health endpoint never answered'
grep -q '"status": *"UP"' "$work/started.json" || { cat "$work/started.json" >&2; fail 'startup check is not UP'; }
docker logs "$name" >"$work/server.log" 2>&1
grep -q "debezium-server-dist ${expected_version}.Final on JVM (powered by Quarkus [0-9.]*) started in" "$work/server.log" ||
  fail 'Quarkus startup line is missing'
grep -q 'Listening on: http://0.0.0.0:8080' "$work/server.log" || fail 'server is not listening on 8080'
code=$(curl -sS -o "$work/live.json" -w '%{http_code}' "http://127.0.0.1:$port/q/health/live")
[ "$code" = 503 ] || { cat "$work/live.json" >&2; fail "liveness returned $code while the source is unreachable"; }
if ! grep -q '"name": *"debezium"' "$work/live.json" || ! grep -q '"status": *"DOWN"' "$work/live.json"; then
  cat "$work/live.json" >&2
  fail 'liveness does not report the debezium check DOWN'
fi

printf 'debezium-server %s smoke test passed\n' "$expected_version"
