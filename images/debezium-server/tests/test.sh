#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
here=$(cd "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' "$here/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
name=verity-debezium-server-$$
backend=verity-debezium-postgres-$$
network=verity-debezium-network-$$
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
work=$(mktemp -d)
chmod 755 "$work"

cleanup() {
  docker rm -f "$name" "$name-noconf" "$name-invalid" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
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

# Positive: against a logical-replication Postgres the server starts Quarkus on 8080, the connector
# creates its replication slot and streams, and every health check reports UP.
# A classic Docker image store cannot bind the index digest to a second platform's image, so pull the
# helper by its per-platform child digest after verifying the index bytes against the pin.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") || fail 'cannot inspect helper image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'helper image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" | jq -r --arg arch "$image_arch" '
  [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
  | if length == 1 then .[0] else empty end') || fail 'cannot resolve helper image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch helper image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null || fail 'cannot pull helper image'

docker network create "$network" >/dev/null
docker run -d --name "$backend" --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke "$postgres" -c wal_level=logical >/dev/null
attempts=0
until docker exec "$backend" psql -X -U postgres -At -c 'SELECT 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$backend" >&2; fail 'postgres did not become ready'; }
  sleep 2
done
docker exec "$backend" psql -X -v ON_ERROR_STOP=1 -U postgres -c 'CREATE TABLE smoke (id int PRIMARY KEY)' \
  >/dev/null || fail 'cannot create smoke table'

PROPS=$(printf '%s\n' "$base_props" | sed 's/^debezium.source.database.password=.*/debezium.source.database.password=smoke/')
PROPS="$PROPS
debezium.source.database.hostname=postgres
debezium.source.plugin.name=pgoutput
debezium.source.slot.name=verity_smoke
debezium.source.snapshot.mode=no_data"
run_with_props -d --name "$name" --network "$network" -e PROPS -p 127.0.0.1::8080 >/dev/null
port=$(docker port "$name" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'port 8080 is not published'
ready=
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail 'server exited before it was healthy'
  if curl -fsS "http://127.0.0.1:$port/q/health" >"$work/health.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
[ -n "$ready" ] || { cat "$work/health.json" >&2 2>/dev/null || true; fail '/q/health never reported UP'; }
grep -q '"status": *"UP"' "$work/health.json" || { cat "$work/health.json" >&2; fail 'health is not UP'; }
grep -q '"name": *"debezium"' "$work/health.json" || { cat "$work/health.json" >&2; fail 'debezium check missing'; }
if grep -q '"status": *"DOWN"' "$work/health.json"; then
  cat "$work/health.json" >&2
  fail 'a health check is DOWN'
fi
docker logs "$name" >"$work/server.log" 2>&1
grep -q "debezium-server-dist ${expected_version}.Final on JVM (powered by Quarkus [0-9.]*) started in" "$work/server.log" ||
  fail 'Quarkus startup line is missing'
grep -q 'Listening on: http://0.0.0.0:8080' "$work/server.log" || fail 'server is not listening on 8080'
slot_active=
for _ in $(seq 1 30); do
  slot_active=$(docker exec "$backend" psql -X -U postgres -At -c \
    "SELECT active FROM pg_replication_slots WHERE slot_name = 'verity_smoke' AND plugin = 'pgoutput'")
  [ "$slot_active" = t ] && break
  sleep 2
done
[ "$slot_active" = t ] || fail 'connector did not open the pgoutput replication slot'

printf 'debezium-server %s smoke test passed\n' "$expected_version"
