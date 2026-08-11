#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-gitea-test-$$"
data="verity-gitea-data-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$data" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/gitea","web","--config","/etc/gitea/app.ini"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = \
  /var/lib/gitea || fail 'unexpected working directory'
test "$(docker image inspect --format '{{json .Config.Volumes}}' "$image")" = \
  '{"/etc/gitea":{},"/var/lib/gitea":{}}' || fail 'missing writable volumes'
docker run --rm --cpus=4 --network none --entrypoint /usr/bin/gitea "$image" --version |
  grep -F 'Gitea version 1.24.7' >/dev/null || fail 'unexpected Gitea version'
docker run --rm --cpus=4 --network none --entrypoint /bin/sh "$image" -c \
  'test "$(id -u)" = 1000 && test -w /etc/gitea && test -w /var/lib/gitea' ||
  fail 'rootless runtime paths are not writable'

cat >"$work/app.ini" <<'EOF'
APP_NAME = Verity Gitea
RUN_MODE = prod
RUN_USER = git

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db

[repository]
ROOT = /var/lib/gitea/git/repositories

[server]
APP_DATA_PATH = /var/lib/gitea/data
DOMAIN = localhost
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL = http://localhost:3000/

[security]
INSTALL_LOCK = true

[log]
MODE = console
ROOT_PATH = /var/lib/gitea/log
EOF
chmod 644 "$work/app.ini"
docker volume create "$data" >/dev/null
docker run --name "$container" -d --cpus=4 \
  -v "$data:/var/lib/gitea" \
  -v "$work/app.ini:/etc/gitea/app.ini" \
  -p 127.0.0.1::3000 "$image" >/dev/null
port=$(docker port "$container" 3000/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port" || fail 'HTTP port was not published'

attempts=0
until curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$port/" >"$work/index.html"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'Gitea did not become ready'
  sleep 1
done
grep -F '<title>Verity Gitea' "$work/index.html" >/dev/null ||
  fail 'configured Gitea page was not served'
docker rm -f "$container" >/dev/null

docker run --name "$container" -d --cpus=4 --network none --read-only \
  --tmpfs /tmp:uid=1000,gid=1000 \
  --tmpfs /var/lib/gitea:ro,uid=1000,gid=1000 \
  -v "$work/app.ini:/etc/gitea/app.ini:ro" "$image" >/dev/null
sleep 3
test "$(docker inspect --format '{{.State.Running}}' "$container")" = false ||
  fail 'Gitea accepted a missing writable data path'
docker rm -f "$container" >/dev/null

printf '%s\n' '[server' >"$work/invalid.ini"
chmod 644 "$work/invalid.ini"
docker run --name "$container" -d --cpus=4 --network none \
  -v "$data:/var/lib/gitea" \
  -v "$work/invalid.ini:/etc/gitea/app.ini:ro" "$image" >/dev/null
sleep 3
test "$(docker inspect --format '{{.State.Running}}' "$container")" = false ||
  fail 'Gitea accepted an invalid config'

printf 'SMOKE PASS image=%s\n' "$image"
