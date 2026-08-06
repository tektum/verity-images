#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-valkey-test-$$"
volume="verity-valkey-data-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/valkey-server"]'
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /data
docker run --rm --entrypoint /bin/sh "$image" -c \
  'command -v valkey-server >/dev/null && command -v valkey-cli >/dev/null'
docker volume create "$volume" >/dev/null

start_server() {
  docker run --name "$container" -d \
    -v "$volume:/data" \
    -p 127.0.0.1::6379 \
    "$image" --dir /data --dbfilename dump.rdb >/dev/null
  port=$(docker port "$container" 6379/tcp | awk -F: 'NR == 1 { print $2 }')
  test -n "$port"

  i=0
  until docker run --rm --network host --entrypoint /usr/bin/valkey-cli \
    "$image" -h 127.0.0.1 -p "$port" ping 2>/dev/null | grep -Fx PONG >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || {
      docker logs "$container" >&2
      exit 1
    }
    sleep 1
  done
}

start_server
test "$(docker exec "$container" valkey-cli set verity works)" = OK
test "$(docker exec "$container" valkey-cli get verity)" = works
test "$(docker exec "$container" valkey-cli save)" = OK
docker rm -f "$container" >/dev/null

start_server
test "$(docker exec "$container" valkey-cli get verity)" = works
if error=$(docker exec "$container" valkey-cli -e NOT_A_REAL_COMMAND 2>&1); then
  printf '%s\n' 'invalid command unexpectedly succeeded' >&2
  exit 1
fi
printf '%s\n' "$error" | grep -qi 'unknown command'

printf 'SMOKE PASS image=%s\n' "$image"
