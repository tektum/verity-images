#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
container="verity-trino-test-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/lib/trino/bin/launcher"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["run","--etc-dir","/etc/trino"]' || fail 'unexpected default command'

docker run --rm --platform "$platform" --entrypoint java "$image" -version 2>&1 |
  grep -E 'version "25\.' >/dev/null || fail 'Java 25 is missing'
docker run --rm --platform "$platform" --entrypoint trino "$image" --version 2>&1 |
  grep -E '^Trino CLI [0-9]+' >/dev/null || fail 'bundled CLI does not report its version'

# Negative: an unknown configuration property must stop the server with a
# readable error and a non-zero status.
mkdir -p "$tmp/etc"
docker run --rm --platform "$platform" --entrypoint cat "$image" /etc/trino/config.properties >"$tmp/etc/config.properties"
printf 'definitely.not.a.property=1\n' >>"$tmp/etc/config.properties"
docker run --rm --platform "$platform" --entrypoint cat "$image" /etc/trino/node.properties >"$tmp/etc/node.properties"
docker run --rm --platform "$platform" --entrypoint cat "$image" /etc/trino/jvm.config >"$tmp/etc/jvm.config"
chmod -R a+rX "$tmp/etc"
if docker run --rm --platform "$platform" -m 3g -v "$tmp/etc:/bad-etc:ro" "$image" \
  run --etc-dir /bad-etc >"$tmp/bad.log" 2>&1; then
  fail 'invalid configuration unexpectedly succeeded'
fi
grep -F 'definitely.not.a.property' "$tmp/bad.log" >/dev/null ||
  { cat "$tmp/bad.log" >&2; fail 'invalid configuration diagnostic is missing'; }

docker run --platform "$platform" --name "$container" -d -m 3g -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

i=0
until curl --silent --fail --max-time 3 "http://127.0.0.1:$port/v1/info" 2>/dev/null |
  grep -E '"starting" *: *false' >/dev/null; do
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
    docker logs "$container" >&2
    fail 'trino exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 240 ] || {
    docker logs "$container" >&2
    fail 'trino did not become ready'
  }
  sleep 1
done

curl --silent --fail "http://127.0.0.1:$port/v1/info" | grep -F '"coordinator":true' >/dev/null ||
  fail '/v1/info does not describe a coordinator'
docker exec "$container" /usr/lib/trino/bin/health-check || fail 'health-check failed'

count=$(docker exec "$container" trino --execute 'SELECT count(*) FROM tpch.tiny.nation' |
  tr -d '"[:space:]')
test "$count" = 25 || fail "tpch nation count is '$count', expected 25"
sum=$(docker exec "$container" trino --execute \
  'SELECT sum(n.regionkey) FROM tpch.tiny.nation n JOIN tpch.tiny.region r ON n.regionkey = r.regionkey' |
  tr -d '"[:space:]')
test "$sum" = 50 || fail "join result is '$sum', expected 50"

# A bad query is reported as an error with a non-zero CLI status.
if docker exec "$container" trino --execute 'SELECT * FROM tpch.tiny.no_such_table' >"$tmp/query.log" 2>&1; then
  fail 'query against a missing table unexpectedly succeeded'
fi
grep -i 'no_such_table' "$tmp/query.log" >/dev/null || fail 'missing table diagnostic is missing'

docker stop --time 60 "$container" >/dev/null
case $(docker inspect --format '{{.State.ExitCode}}' "$container") in
  0|143) ;;
  *) fail 'trino did not stop cleanly on SIGTERM' ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
