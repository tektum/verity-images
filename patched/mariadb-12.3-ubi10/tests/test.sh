#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture=docker.io/library/mariadb@sha256:c490f21f8d422e9b0cd30eea724b637e02ca2924d11057c35092d7e2784a84cb
arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in
  amd64|arm64) platform=linux/$arch ;;
  *) printf 'unsupported candidate architecture: %s\n' "$arch" >&2; exit 1 ;;
esac

prefix=mariadb-12-3-$$
primary=$prefix-primary
legacy=$prefix-legacy
upgrade=$prefix-upgrade
data=$prefix-data
upgrade_data=$prefix-upgrade-data
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$primary" "$legacy" "$upgrade" >/dev/null 2>&1 || :
  docker volume rm -f "$data" "$upgrade_data" >/dev/null 2>&1 || :
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

expect_fail() {
  status=0
  "$@" || status=$?
  if [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; then
    printf 'expected bounded failure, got status %s: %s\n' "$status" "$*" >&2
    exit 1
  fi
}

wait_ready() {
  attempts=0
  until docker exec "$1" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      docker logs "$1" >&2 || :
      printf 'MariaDB did not become ready: %s\n' "$1" >&2
      exit 1
    fi
    sleep 1
  done
}

docker image inspect --format '{{json .Config.Entrypoint}}' "$image" | grep -q 'docker-entrypoint.sh'
docker image inspect --format '{{range $path, $_ := .Config.Volumes}}{{println $path}}{{end}}' "$image" | grep -qx /var/lib/mysql
docker run --rm --entrypoint sh "$image" -c 'test "$(id -u mysql)" = 999'
expect_fail timeout 30 docker run --rm "$image"

mkdir "$tmp/init"
printf '%s\n' root-password > "$tmp/root-password"
printf '%s\n' app-password > "$tmp/app-password"
printf '%s\n' 'CREATE TABLE init_sql (value INT); INSERT INTO init_sql VALUES (1);' > "$tmp/init/01-init.sql"
cat > "$tmp/init/02-init.sh" <<'EOF'
#!/bin/sh
set -eu
mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" <<'SQL'
CREATE TABLE init_shell (value INT);
INSERT INTO init_shell VALUES (1);
SQL
EOF
chmod 755 "$tmp/init/02-init.sh"

expect_fail timeout 30 docker run --rm \
  --mount type=bind,source="$tmp/root-password",target=/run/secrets/root-password,readonly \
  -e MARIADB_ROOT_PASSWORD=root-password \
  -e MARIADB_ROOT_PASSWORD_FILE=/run/secrets/root-password \
  "$image"

docker volume create "$data" >/dev/null
docker run -d --name "$primary" \
  --mount type=volume,source="$data",target=/var/lib/mysql \
  --mount type=bind,source="$tmp/root-password",target=/run/secrets/root-password,readonly \
  --mount type=bind,source="$tmp/app-password",target=/run/secrets/app-password,readonly \
  --mount type=bind,source="$tmp/init",target=/docker-entrypoint-initdb.d,readonly \
  -e MARIADB_ROOT_PASSWORD_FILE=/run/secrets/root-password \
  -e MARIADB_DATABASE=appdb \
  -e MARIADB_USER=app \
  -e MARIADB_PASSWORD_FILE=/run/secrets/app-password \
  -e MYSQL_ROOT_PASSWORD=mysql-root \
  -e MYSQL_PASSWORD=mysql-user \
  "$image" >/dev/null
wait_ready "$primary"

root_sql() {
  docker exec -e MYSQL_PWD=root-password "$primary" mariadb -uroot -Nse "$1"
}
app_sql() {
  docker exec -e MYSQL_PWD=app-password "$primary" mariadb -uapp appdb -Nse "$1"
}

[ "$(root_sql 'SELECT VERSION() LIKE "12.3.%"')" = 1 ]
[ "$(root_sql 'SELECT value FROM appdb.init_sql')" = 1 ]
[ "$(root_sql 'SELECT value FROM appdb.init_shell')" = 1 ]
[ "$(app_sql 'SELECT value FROM init_sql')" = 1 ]
expect_fail timeout 30 docker exec -e MYSQL_PWD=mysql-root "$primary" mariadb -uroot -Nse 'SELECT 1'
expect_fail timeout 30 docker exec -e MYSQL_PWD=mysql-user "$primary" mariadb -uapp appdb -Nse 'SELECT 1'
root_sql 'UPDATE appdb.init_sql SET value = 2'
root_sql 'INSTALL SONAME "ha_blackhole"; CREATE TABLE appdb.blackhole_test (value INT) ENGINE=BLACKHOLE; INSERT INTO appdb.blackhole_test VALUES (1);'
[ "$(root_sql 'SELECT COUNT(*) FROM appdb.blackhole_test')" = 0 ]

docker stop "$primary" >/dev/null
docker start "$primary" >/dev/null
wait_ready "$primary"
[ "$(root_sql 'SELECT value FROM appdb.init_sql')" = 2 ]
[ "$(root_sql 'SELECT value FROM appdb.init_shell')" = 1 ]

docker volume create "$upgrade_data" >/dev/null
docker run -d --platform "$platform" --name "$legacy" \
  --mount type=volume,source="$upgrade_data",target=/var/lib/mysql \
  -e MARIADB_ROOT_PASSWORD=legacy-password \
  "$fixture" >/dev/null
wait_ready "$legacy"
[ "$(docker exec -e MYSQL_PWD=legacy-password "$legacy" mariadb -uroot -Nse 'SELECT VERSION() NOT LIKE "12.3.%"')" = 1 ]
docker exec -e MYSQL_PWD=legacy-password "$legacy" mariadb -uroot -e 'CREATE DATABASE upgrade_test; CREATE TABLE upgrade_test.records (value INT); INSERT INTO upgrade_test.records VALUES (123);'
docker stop "$legacy" >/dev/null

docker run -d --name "$upgrade" \
  --mount type=volume,source="$upgrade_data",target=/var/lib/mysql \
  -e MARIADB_ROOT_PASSWORD=legacy-password \
  -e MARIADB_AUTO_UPGRADE=1 \
  "$image" >/dev/null
wait_ready "$upgrade"
[ "$(docker exec -e MYSQL_PWD=legacy-password "$upgrade" mariadb -uroot -Nse 'SELECT value FROM upgrade_test.records')" = 123 ]
[ "$(docker exec -e MYSQL_PWD=legacy-password "$upgrade" mariadb -uroot -Nse 'SELECT VERSION() LIKE "12.3.%"')" = 1 ]
