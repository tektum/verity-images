#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
container="verity-kvrocks-test-$$"
volume="verity-kvrocks-data-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 999 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/kvrocks"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /var/lib/kvrocks ||
  fail 'unexpected working directory'

docker run --rm --platform "$platform" "$image" --version 2>&1 | grep -E 'kvrocks (version )?[0-9]+\.[0-9]+\.[0-9]+' >/dev/null ||
  fail 'unexpected version output'

# Negative: a missing configuration file must fail with a readable error.
if docker run --rm --platform "$platform" "$image" -c /definitely-missing.conf >"$tmp/missing" 2>&1; then
  fail 'missing config unexpectedly succeeded'
fi
grep -F 'definitely-missing.conf' "$tmp/missing" >/dev/null || fail 'missing config diagnostic is missing'

resp() {
  # $1 port, remaining: inline RESP commands, one per argument
  port=$1
  shift
  {
    for command in "$@"; do
      printf '%s\r\n' "$command"
    done
    printf 'QUIT\r\n'
  } | curl --silent --show-error --max-time 5 "telnet://127.0.0.1:$port" | tr -d '\r'
}

start_server() {
  docker run --platform "$platform" --name "$container" -d -v "$volume:/var/lib/kvrocks" \
    -p 127.0.0.1::6666 "$image" \
    -c /usr/share/kvrocks/kvrocks.conf --dir /var/lib/kvrocks --pidfile /var/run/kvrocks/kvrocks.pid \
    --bind 0.0.0.0 >/dev/null
  i=0
  port=
  until [ -n "$port" ] && [ "$(resp "$port" PING 2>/dev/null | head -n 1)" = '+PONG' ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
      docker logs "$container" >&2
      fail 'kvrocks exited before becoming ready'
    }
    i=$((i + 1))
    [ "$i" -lt 60 ] || {
      docker logs "$container" >&2
      fail 'kvrocks did not become ready'
    }
    port=$(docker port "$container" 6666/tcp 2>/dev/null | awk -F: 'NR == 1 { print $2 }')
    sleep 1
  done
}

docker volume create "$volume" >/dev/null
start_server
reply=$(resp "$port" 'SET verity:key persisted' 'GET verity:key')
printf '%s\n' "$reply" | grep -Fx '+OK' >/dev/null || fail 'SET did not return +OK'
printf '%s\n' "$reply" | grep -Fx 'persisted' >/dev/null || fail 'GET did not return the stored value'
# Redis data types and Lua scripting both work.
reply=$(resp "$port" 'RPUSH verity:list a b c' 'LRANGE verity:list 0 -1' 'EVAL "return 1+1" 0')
printf '%s\n' "$reply" | grep -Fx ':3' >/dev/null || fail 'RPUSH did not return 3'
printf '%s\n' "$reply" | grep -Fx ':2' >/dev/null || fail 'EVAL did not return 2'

docker stop --time 30 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
  fail 'kvrocks did not exit cleanly on SIGTERM'
docker rm "$container" >/dev/null

# The data directory persists across a restart on the same volume.
start_server
reply=$(resp "$port" 'GET verity:key' 'LRANGE verity:list 0 -1')
printf '%s\n' "$reply" | grep -Fx 'persisted' >/dev/null || fail 'string was not persisted'
printf '%s\n' "$reply" | grep -Fx 'c' >/dev/null || fail 'list was not persisted'

printf 'SMOKE PASS image=%s\n' "$image"
