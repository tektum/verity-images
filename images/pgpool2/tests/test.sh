#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
postgres_index='docker.io/library/postgres:17-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193'
backend="verity-pgpool2-postgres-$$"
pooler="verity-pgpool2-pooler-$$"
network="verity-pgpool2-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$pooler" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image user is not 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/pgpool"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = \
  '["-n","-f","/etc/pgpool2/pgpool.conf","-F","/etc/pgpool2/pcp.conf"]' ||
  fail 'unexpected cmd'
docker run --rm --entrypoint /usr/bin/pgpool "$image" --version 2>&1 |
  grep -F "pgpool-II version $expected_version " >/dev/null ||
  fail "pgpool version is not $expected_version"
docker run --rm --entrypoint /usr/bin/pcp_node_info "$image" --version 2>&1 |
  grep -F "pcp_node_info (pgpool-II) $expected_version" >/dev/null ||
  fail "pcp_node_info version is not $expected_version"

# The shipped configuration must listen on every address and keep runtime
# state in the directories the unprivileged user owns.
# The image has no shell, so copy the file out of a created container.
shipped=$(docker create "$image") || fail 'cannot create container'
docker cp "$shipped:/etc/pgpool2/pgpool.conf" "$tmp/shipped.conf" >/dev/null ||
  fail 'cannot copy shipped pgpool.conf'
docker rm "$shipped" >/dev/null
shipped_conf=$(cat "$tmp/shipped.conf")
for setting in \
  "listen_addresses = '*'" \
  "unix_socket_directories = '/var/run/pgpool'" \
  "pcp_socket_dir = '/var/run/pgpool'" \
  "pid_file_name = '/var/run/pgpool/pgpool.pid'" \
  "work_dir = '/var/lib/pgpool'" \
  "pool_passwd = '/var/lib/pgpool/pool_passwd'"; do
  printf '%s\n' "$shipped_conf" | grep -Fx "$setting" >/dev/null ||
    fail "shipped pgpool.conf lacks: $setting"
done

# The default command with the shipped configuration must start as the
# unprivileged user and keep running.
docker run --name "$pooler" -d "$image" >/dev/null
sleep 5
test "$(docker inspect -f '{{.State.Running}}' "$pooler")" = true || {
  docker logs "$pooler" >&2
  fail 'pgpool exited with the shipped configuration'
}
docker rm -f "$pooler" >/dev/null

# A classic Docker image store cannot bind the index digest to a second
# platform's image, so pull the helper by its own per-platform child digest.
# The index bytes are verified against the pinned digest before a child is
# chosen, which keeps the pin authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
postgres_raw=$(docker buildx imagetools inspect --raw "$postgres_index") ||
  fail 'cannot inspect postgres image index'
[ "sha256:$(printf '%s' "$postgres_raw" | sha256sum | cut -d' ' -f1)" = "${postgres_index#*@}" ] ||
  fail 'postgres image index digest mismatch'
postgres_digest=$(printf '%s' "$postgres_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve postgres image digest'
case $postgres_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch postgres image in $postgres_index" ;;
esac
postgres=docker.io/library/postgres@$postgres_digest
docker pull --quiet --platform "linux/$image_arch" "$postgres" >/dev/null ||
  fail 'cannot pull postgres image'

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias postgres \
  -e POSTGRES_USER=smoke \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$postgres" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -U smoke -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || {
    docker logs "$backend" >&2
    fail 'postgres backend did not become ready'
  }
  sleep 1
done

cat >"$tmp/pgpool.conf" <<'EOF'
backend_clustering_mode = 'raw'
listen_addresses = '*'
port = 9999
unix_socket_directories = '/var/run/pgpool'
pcp_listen_addresses = '*'
pcp_port = 9898
pcp_socket_dir = '/var/run/pgpool'
pid_file_name = '/var/run/pgpool/pgpool.pid'
pool_passwd = '/var/lib/pgpool/pool_passwd'
work_dir = '/var/lib/pgpool'
backend_hostname0 = 'postgres'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'
enable_pool_hba = off
sr_check_period = 0
health_check_period = 0
num_init_children = 4
max_pool = 2
EOF
chmod 644 "$tmp/pgpool.conf"

# The default command reads the shipped pcp.conf; mount only pgpool.conf.
docker run --name "$pooler" -d --network "$network" --network-alias pgpool \
  -v "$tmp/pgpool.conf:/etc/pgpool2/pgpool.conf:ro" \
  "$image" >/dev/null

attempts=0
until docker exec "$backend" pg_isready -h pgpool -p 9999 -U smoke -d postgres >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || {
    docker logs "$pooler" >&2
    fail 'pgpool did not accept connections'
  }
  sleep 1
done

result=$(docker exec "$backend" psql -h pgpool -p 9999 -U smoke -d postgres -Atqc \
  "SELECT current_user || ':' || current_database() || ':' || 6 * 7") ||
  fail 'query through pgpool failed'
test "$result" = 'smoke:postgres:42' || fail "unexpected query result: $result"

# SHOW POOL_NODES is answered by pgpool itself, proving the proxy is pgpool.
nodes=$(docker exec "$backend" psql -h pgpool -p 9999 -U smoke -d postgres -Atqc \
  'SHOW POOL_NODES') || fail 'SHOW POOL_NODES failed'
printf '%s\n' "$nodes" | grep -F '|postgres|5432|' >/dev/null ||
  fail "SHOW POOL_NODES lacks backend: $nodes"

test "$(docker inspect -f '{{.State.Running}}' "$pooler")" = true ||
  fail 'pgpool container stopped'

printf '%s\n' "this is not = valid = pgpool" >"$tmp/invalid.conf"
chmod 644 "$tmp/invalid.conf"
if docker run --rm -v "$tmp/invalid.conf:/etc/pgpool2/pgpool.conf:ro" \
  "$image" >/dev/null 2>&1; then
  fail 'invalid config unexpectedly succeeded'
fi

printf 'SMOKE PASS image=%s\n' "$image"
