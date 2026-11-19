#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-infinispan-test-$$"
volume="verity-infinispan-data-$$"
password="verity-test-$$"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" "$container-badconf" "$container-genuser" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# OCI contract: upstream entrypoint and working directory, non-root user.
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/opt/infinispan/bin/launch.sh"]' ] ||
  fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/infinispan ] || fail 'unexpected image working directory'
docker image inspect --format '{{json .Config.Env}}' "$image" | grep -q '"ISPN_HOME=/opt/infinispan"' || fail 'ISPN_HOME is not /opt/infinispan'
docker run --rm --entrypoint sh "$image" -c \
  'test -w /opt/infinispan/server/conf && test -w /opt/infinispan/server/conf/users.properties && test -w /opt/infinispan/server/data && test -w /opt/infinispan/server/log' ||
  fail 'Infinispan server paths are not writable by the image user'
docker run --rm --entrypoint sh "$image" -c 'test ! -w /opt/infinispan/lib && test ! -w /opt/infinispan/bin/server.sh' ||
  fail 'Infinispan libraries or scripts are writable by the image user'
docker run --rm --entrypoint sh "$image" -c 'test -x /opt/gossiprouter/bin/launch.sh' || fail 'gossip router launcher is missing'

# Negative: a missing server configuration must stop the server with a readable error.
status=0
output=$(timeout 120 docker run --rm --name "$container-badconf" "$image" -c does-not-exist.xml 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'missing configuration unexpectedly started'
[ "$status" -ne 124 ] || fail 'missing configuration kept the server running until the timeout'
printf '%s\n' "$output" | grep -q 'does-not-exist.xml (No such file or directory)' ||
  fail "missing configuration gave no readable error: $output"

url=

wait_ready() {
  name=$1
  port=$(docker port "$name" 11222/tcp | head -n 1 | sed 's/.*://')
  [ -n "$port" ] || fail "port 11222 is not published for $name"
  url="http://127.0.0.1:$port"
  i=0
  until [ "$(curl -s --max-time 5 "$url/rest/v2/container/health/status" 2>/dev/null)" = HEALTHY ]; do
    [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ] || {
      docker logs "$name" >&2
      fail "$name exited before becoming ready"
    }
    i=$((i + 1))
    [ "$i" -lt 120 ] || {
      docker logs "$name" >&2
      fail "$name did not report HEALTHY"
    }
    sleep 1
  done
}

code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@"
}

api() {
  curl -fsS --max-time 30 --digest -u "admin:$password" "$@"
}

start_server() {
  docker run --name "$container" -d -p 127.0.0.1::11222 \
    -e USER=admin -e "PASS=$password" \
    -v "$volume:/opt/infinispan/server/data" \
    "$image" >/dev/null
  wait_ready "$container"
}

docker volume create "$volume" >/dev/null
start_server

server=$(api "$url/rest/v2/server") || fail 'authenticated server info request failed'
printf '%s\n' "$server" | grep -q '16\.3\.' || fail "unexpected server version: $server"

# Negative: authentication is enforced on the REST API.
[ "$(code "$url/rest/v2/caches")" = 401 ] || fail 'anonymous cache listing was not rejected with 401'
[ "$(code --digest -u admin:wrong-password "$url/rest/v2/caches")" = 401 ] ||
  fail 'wrong password was not rejected with 401'
[ "$(code -X POST "$url/rest/v2/caches/anonymous?template=org.infinispan.DIST_SYNC")" = 401 ] ||
  fail 'anonymous cache creation was not rejected with 401'

# Negative: invalid cache configuration and unknown caches return client errors.
body=$(curl -s --max-time 30 --digest -u "admin:$password" -w '\n%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{"distributed-cache":{"mode":"BOGUS"}}' "$url/rest/v2/caches/invalid")
[ "$(printf '%s\n' "$body" | tail -n 1)" = 400 ] || fail "invalid cache configuration did not return 400: $body"
printf '%s\n' "$body" | grep -q "illegal value 'BOGUS'" || fail "invalid cache configuration error is not readable: $body"
[ "$(code --digest -u "admin:$password" "$url/rest/v2/caches/missing/key")" = 404 ] ||
  fail 'unknown cache did not return 404'

api -X POST "$url/rest/v2/caches/verity?template=org.infinispan.DIST_SYNC" >/dev/null || fail 'cache creation failed'
api -X POST -H 'Content-Type: text/plain' -d persisted "$url/rest/v2/caches/verity/smoke" >/dev/null || fail 'cache write failed'
[ "$(api "$url/rest/v2/caches/verity/smoke")" = persisted ] || fail 'cache read failed'

docker stop --time 30 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] || {
  docker logs "$container" >&2
  fail 'Infinispan did not exit cleanly on SIGTERM'
}
docker rm "$container" >/dev/null

# The cache definition is persisted in server/data and survives a restart.
start_server
api "$url/rest/v2/caches" | grep -q '"verity"' || fail 'persisted cache definition was not restored after restart'
docker rm -f "$container" >/dev/null

# Without PASS the launcher generates random admin credentials and still rejects anonymous access.
docker run --name "$container-genuser" -d -p 127.0.0.1::11222 "$image" >/dev/null
wait_ready "$container-genuser"
docker logs "$container-genuser" 2>&1 | grep -q 'Generated User:' || fail 'no generated credentials were reported'
[ "$(code "$url/rest/v2/caches")" = 401 ] || fail 'anonymous access was allowed with generated credentials'
