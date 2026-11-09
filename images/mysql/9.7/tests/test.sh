#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
# Official MySQL 9.7.0 image, used to prove an in-place upgrade of its data
# volume to this image.
fixture_index=docker.io/library/mysql:9.7.0@sha256:c11782aa2a96624c1efc121768641d96954faa136d6aa82751b032d8c426ffbc
arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in
  amd64|arm64) platform=linux/$arch ;;
  *) printf 'unsupported candidate architecture: %s\n' "$arch" >&2; exit 1 ;;
esac

prefix=mysql-9-7-$$
primary=$prefix-primary
rootrun=$prefix-rootrun
legacy=$prefix-legacy
upgrade=$prefix-upgrade
data=$prefix-data
root_data=$prefix-root-data
upgrade_data=$prefix-upgrade-data
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$primary" "$rootrun" "$legacy" "$upgrade" >/dev/null 2>&1 || :
  docker volume rm -f "$data" "$root_data" "$upgrade_data" >/dev/null 2>&1 || :
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# A rejected login or privilege must fail with the given server error, not a
# connection error, so the server is up and enforcing access control.
expect_denied() {
  container=$1
  error=$2
  shift 2
  status=0
  docker exec "$container" "$@" >"$tmp/denied.out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "expected $error, command succeeded: $*"
  grep -q "$error" "$tmp/denied.out" || {
    cat "$tmp/denied.out" >&2
    fail "expected $error: $*"
  }
}

# The entrypoint initializes the data directory with a socket-only temporary
# server, so a TCP ping succeeds only once the final server is listening.
wait_ready() {
  attempts=0
  until docker exec -e MYSQL_PWD="$2" "$1" mysqladmin -h127.0.0.1 -P3306 -uroot ping >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 120 ]; then
      docker logs "$1" >&2 || :
      fail "MySQL did not become ready: $1"
    fi
    if [ "$(docker inspect --format '{{.State.Running}}' "$1")" != true ]; then
      docker logs "$1" >&2 || :
      fail "MySQL exited before it became ready: $1"
    fi
    sleep 1
  done
}

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["docker-entrypoint.sh"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["mysqld"]' ] ||
  fail 'unexpected command'
docker image inspect --format '{{.Config.User}}' "$image" | grep -Eqx '999|mysql' || fail 'image does not run as mysql'
docker image inspect --format '{{range $path, $_ := .Config.Volumes}}{{println $path}}{{end}}' "$image" |
  grep -qx /var/lib/mysql || fail 'missing /var/lib/mysql volume'
[ "$(docker run --rm --entrypoint id "$image" -u mysql)" = 999 ] || fail 'mysql user is not uid 999'

version=$(docker run --rm --entrypoint mysqld "$image" --version |
  sed -n 's/^.*Ver \([0-9][0-9.]*\) .*$/\1/p')
case $version in
  9.7.*) ;;
  *) fail "unexpected server version: $version" ;;
esac
docker run --rm --entrypoint mysql "$image" --version | grep -F "$version" >/dev/null ||
  fail 'client version does not match server'
# The entrypoint links the compiled default socket to the configured one when
# they differ; both must be the official image's path.
for defaults in --no-defaults ''; do
  # shellcheck disable=SC2086
  socket=$(docker run --rm --entrypoint mysqld "$image" $defaults --verbose --help 2>/dev/null |
    awk '/^socket[ \t]/ { print $2 }')
  [ "$socket" = /var/run/mysqld/mysqld.sock ] || fail "unexpected socket ${defaults:-with defaults}: $socket"
done

# Negative: without a root password option the entrypoint refuses to
# initialize the data directory.
status=0
timeout 60 docker run --rm "$image" >"$tmp/nopass.out" 2>&1 || status=$?
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "expected bounded failure without password, got $status"
grep -q 'password option is not specified' "$tmp/nopass.out" || {
  cat "$tmp/nopass.out" >&2
  fail 'missing documented no-password error'
}

# Negative: an unknown server option is a configuration error, not a hang.
status=0
timeout 60 docker run --rm -e MYSQL_ROOT_PASSWORD=x "$image" mysqld --no-such-option >"$tmp/badopt.out" 2>&1 || status=$?
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "expected bounded failure for bad option, got $status"
grep -q 'unknown option' "$tmp/badopt.out" || {
  cat "$tmp/badopt.out" >&2
  fail 'missing unknown option error'
}

mkdir "$tmp/init"
printf '%s\n' root-password >"$tmp/root-password"
printf '%s\n' 'CREATE TABLE init_sql (value INT); INSERT INTO init_sql VALUES (1);' >"$tmp/init/01-init.sql"
printf '%s\n' 'CREATE TABLE init_gz (value INT); INSERT INTO init_gz VALUES (1);' | gzip >"$tmp/init/02-init.sql.gz"
# A non-executable .sh init script is sourced by the entrypoint, so it can use
# the entrypoint's docker_process_sql helper.
cat >"$tmp/init/03-init.sh" <<'EOF'
docker_process_sql --database="$MYSQL_DATABASE" <<'SQL'
CREATE TABLE init_shell (value INT);
INSERT INTO init_shell VALUES (1);
SQL
EOF
chmod 644 "$tmp/root-password" "$tmp/init/01-init.sql" "$tmp/init/02-init.sql.gz" "$tmp/init/03-init.sh"
chmod 755 "$tmp/init"

docker volume create "$data" >/dev/null
docker run -d --name "$primary" \
  --mount type=volume,source="$data",target=/var/lib/mysql \
  --mount type=bind,source="$tmp/root-password",target=/run/secrets/root-password,readonly \
  --mount type=bind,source="$tmp/init",target=/docker-entrypoint-initdb.d,readonly \
  -e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/root-password \
  -e MYSQL_DATABASE=appdb \
  -e MYSQL_USER=app \
  -e MYSQL_PASSWORD=app-password \
  "$image" >/dev/null
wait_ready "$primary" root-password

root_sql() {
  docker exec -e MYSQL_PWD=root-password "$primary" mysql -h127.0.0.1 -P3306 -uroot -Nse "$1"
}
app_sql() {
  docker exec -e MYSQL_PWD=app-password "$primary" mysql -h127.0.0.1 -P3306 -uapp appdb -Nse "$1"
}

[ "$(root_sql 'SELECT VERSION()')" = "$version" ] || fail 'server reports a different version'
[ "$(root_sql 'SELECT @@datadir')" = /var/lib/mysql/ ] || fail 'unexpected datadir'
[ "$(root_sql 'SELECT CURRENT_USER()')" = root@% ] || fail 'root is not reachable over TCP'
[ "$(root_sql 'SELECT value FROM appdb.init_sql')" = 1 ] || fail 'init .sql script did not run'
[ "$(root_sql 'SELECT value FROM appdb.init_gz')" = 1 ] || fail 'init .sql.gz script did not run'
[ "$(root_sql 'SELECT value FROM appdb.init_shell')" = 1 ] || fail 'init shell script did not run'
[ "$(root_sql 'SELECT COUNT(*) FROM mysql.time_zone_name')" -gt 0 ] || fail 'time zone tables are empty'
[ "$(root_sql 'SELECT ENGINE FROM information_schema.ENGINES WHERE ENGINE = "InnoDB" AND SUPPORT = "DEFAULT"')" = InnoDB ] ||
  fail 'InnoDB is not the default engine'
app_sql 'CREATE TABLE records (id INT PRIMARY KEY, note VARCHAR(32)); INSERT INTO records VALUES (1, "persisted");'
[ "$(app_sql 'SELECT note FROM records WHERE id = 1')" = persisted ] || fail 'app user cannot read its row'
expect_denied "$primary" 'ERROR 1045' env MYSQL_PWD=wrong mysql -h127.0.0.1 -P3306 -uroot -Nse 'SELECT 1'
expect_denied "$primary" 'ERROR 1142' env MYSQL_PWD=app-password mysql -h127.0.0.1 -P3306 -uapp -Nse 'SELECT * FROM mysql.user'
# Unix socket client access uses the configured socket path.
[ "$(docker exec -e MYSQL_PWD=root-password "$primary" mysql -uroot -Nse 'SELECT @@socket')" = /var/run/mysqld/mysqld.sock ] ||
  fail 'socket client access failed'
[ "$(docker exec "$primary" stat -c %u:%g /var/lib/mysql /var/lib/mysql/mysql.ibd | sort -u)" = 999:999 ] ||
  fail 'data directory is not owned by mysql'
[ "$(docker exec "$primary" sh -c 'stat -c %u /proc/1')" = 999 ] || fail 'server does not run as uid 999'

docker stop "$primary" >/dev/null
docker start "$primary" >/dev/null
wait_ready "$primary" root-password
[ "$(app_sql 'SELECT note FROM records WHERE id = 1')" = persisted ] || fail 'data did not persist across restart'
[ "$(root_sql 'SELECT value FROM appdb.init_sql')" = 1 ] || fail 'init data did not persist across restart'

# Started as root, the entrypoint fixes volume ownership and drops to mysql.
docker volume create "$root_data" >/dev/null
docker run -d --name "$rootrun" --user 0:0 \
  --mount type=volume,source="$root_data",target=/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=root-run \
  "$image" >/dev/null
wait_ready "$rootrun" root-run
[ "$(docker exec "$rootrun" sh -c 'stat -c %u /proc/1')" = 999 ] || fail 'root start did not drop to mysql'
[ "$(docker exec "$rootrun" stat -c %u:%g /var/lib/mysql/mysql.ibd)" = 999:999 ] ||
  fail 'root start left data owned by root'

# In-place upgrade of an official MySQL 9.7.0 data volume.
fixture_raw=$(docker buildx imagetools inspect --raw "$fixture_index") || fail 'cannot inspect fixture image index'
[ "sha256:$(printf '%s' "$fixture_raw" | sha256sum | cut -d' ' -f1)" = "${fixture_index#*@}" ] ||
  fail 'fixture image index digest mismatch'
fixture_digest=$(printf '%s' "$fixture_raw" |
  jq -r --arg arch "$arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') || fail 'cannot resolve fixture image digest'
case $fixture_digest in
  sha256:*) ;;
  *) fail "no unique linux/$arch fixture image in $fixture_index" ;;
esac
fixture=docker.io/library/mysql@$fixture_digest
docker pull --quiet --platform "$platform" "$fixture" >/dev/null || fail 'cannot pull fixture image'

docker volume create "$upgrade_data" >/dev/null
docker run -d --platform "$platform" --name "$legacy" \
  --mount type=volume,source="$upgrade_data",target=/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=legacy-password \
  "$fixture" >/dev/null
wait_ready "$legacy" legacy-password
[ "$(docker exec -e MYSQL_PWD=legacy-password "$legacy" mysql -h127.0.0.1 -uroot -Nse 'SELECT VERSION()')" = 9.7.0 ] ||
  fail 'fixture is not MySQL 9.7.0'
docker exec -e MYSQL_PWD=legacy-password "$legacy" mysql -h127.0.0.1 -uroot -e \
  'CREATE DATABASE upgrade_test; CREATE TABLE upgrade_test.records (value INT); INSERT INTO upgrade_test.records VALUES (123);'
docker stop "$legacy" >/dev/null

docker run -d --name "$upgrade" \
  --mount type=volume,source="$upgrade_data",target=/var/lib/mysql \
  "$image" >/dev/null
wait_ready "$upgrade" legacy-password
[ "$(docker exec -e MYSQL_PWD=legacy-password "$upgrade" mysql -h127.0.0.1 -uroot -Nse 'SELECT value FROM upgrade_test.records')" = 123 ] ||
  fail 'upgraded data is missing'
[ "$(docker exec -e MYSQL_PWD=legacy-password "$upgrade" mysql -h127.0.0.1 -uroot -Nse 'SELECT VERSION()')" = "$version" ] ||
  fail 'upgraded server reports a different version'
