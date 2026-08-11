#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-tidb-test-$$"
negative="verity-tidb-negative-$$"
version="verity-tidb-version-$$"
volume="verity-tidb-data-$$"
negative_log=$(mktemp)

cleanup() {
  docker rm -f "$container" "$negative" "$version" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  rm -f "$negative_log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /var/lib/tidb
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/tidb-server"]'

docker create --name "$version" --cpus 4 --network none --entrypoint /bin/sh "$image" -c '
  test -s /usr/share/licenses/verity-tidb/LICENSE
  exec /usr/bin/tidb-server -V
' >/dev/null
docker update --cpus 4 "$version" >/dev/null
version_output=$(docker start -a "$version" 2>&1)
printf '%s\n' "$version_output" | grep -F 'Release Version: v9.0.0-beta.1' >/dev/null \
  || fail 'TiDB version check failed'
printf '%s\n' "$version_output" | grep -F 'Git Commit Hash: 7aff918dcbfa6facf2adef9ade9961c40f217421' >/dev/null \
  || fail 'TiDB source commit check failed'
docker rm "$version" >/dev/null

docker volume create "$volume" >/dev/null

start() {
  docker create --name "$container" --cpus 4 \
    -v "$volume:/var/lib/tidb" \
    -p 127.0.0.1::4000 -p 127.0.0.1::10080 \
    "$image" \
    --store=unistore \
    --path=/var/lib/tidb \
    --host=0.0.0.0 \
    --status-host=0.0.0.0 >/dev/null
  docker update --cpus 4 "$container" >/dev/null
  docker start "$container" >/dev/null

  sql_port=$(docker port "$container" 4000/tcp | awk -F: 'NR == 1 { print $2 }')
  status_port=$(docker port "$container" 10080/tcp | awk -F: 'NR == 1 { print $2 }')
  [ -n "$sql_port" ] && [ -n "$status_port" ] \
    || fail 'SQL and status ports were not published'

  attempts=0
  until status=$(curl -fsS --max-time 2 "http://127.0.0.1:$status_port/status"); do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || fail 'TiDB did not become ready'
    sleep 1
  done
  printf '%s\n' "$status" | grep -F '"connections"' >/dev/null \
    || fail 'TiDB status response did not contain connection state'
}

start

sql_probe=$(curl --verbose --connect-timeout 2 --max-time 3 "http://127.0.0.1:$sql_port/" 2>&1 || true)
printf '%s\n' "$sql_probe" | grep -Fq 'Connected to 127.0.0.1' \
  || fail 'MySQL listener is not accepting connections on port 4000'
docker exec "$container" /bin/sh -c \
  'test -n "$(find /var/lib/tidb -mindepth 1 -maxdepth 1 -print -quit)"' \
  || fail 'TiDB did not write persistent state'

docker create --name "$negative" --cpus 4 --network "container:$container" \
  "$image" --store=unistore --path=/tmp/tidb-negative --host=0.0.0.0 --status-host=0.0.0.0 >/dev/null
docker update --cpus 4 "$negative" >/dev/null
if docker start -a "$negative" >"$negative_log" 2>&1; then
  fail 'second TiDB server unexpectedly reused occupied ports'
fi
grep -F 'address already in use' "$negative_log" >/dev/null \
  || fail 'occupied port did not return the expected bind error'
docker rm "$negative" >/dev/null

docker rm -f "$container" >/dev/null
start
docker exec "$container" /bin/sh -c \
  'test -n "$(find /var/lib/tidb -mindepth 1 -maxdepth 1 -print -quit)"' \
  || fail 'TiDB state did not survive restart'

printf 'SMOKE PASS image=%s\n' "$image"
