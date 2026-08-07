#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
fixture='docker.io/library/mariadb:11.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf'
network="verity-proxysql-test-$$"
backend="verity-proxysql-backend-$$"
proxy="verity-proxysql-test-$$"
config=$(mktemp)
invalid_config=$(mktemp)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$proxy" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -f "$config" "$invalid_config"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/proxysql"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["-f"]' ] || fail 'unexpected image command'

cat >"$config" <<'EOF'
datadir="/var/lib/proxysql"
errorlog="/var/lib/proxysql/proxysql.log"

admin_variables=
{
  admin_credentials="admin:admin;radmin:radmin"
  mysql_ifaces="0.0.0.0:6032"
}

mysql_variables=
{
  interfaces="0.0.0.0:6033"
}
EOF
printf '%s\n' 'this is not valid {' >"$invalid_config"
chmod 644 "$config" "$invalid_config"

if docker run --rm -v "$invalid_config:/tmp/proxysql.cnf:ro" "$image" \
  -f -c /tmp/proxysql.cnf >/dev/null 2>&1; then
  fail 'invalid config unexpectedly succeeded'
fi

docker network create "$network" >/dev/null
docker run --name "$backend" --network "$network" --network-alias backend -d \
  -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=verity \
  -e MARIADB_USER=verity -e MARIADB_PASSWORD=verity "$fixture" >/dev/null

i=0
until docker run --rm --network "$network" "$fixture" \
  mariadb-admin ping -h backend -u root -proot --silent >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || { docker logs "$backend" >&2; fail 'MariaDB fixture did not become ready'; }
  sleep 1
done

docker run --name "$proxy" --network "$network" --network-alias proxysql -d \
  --tmpfs /var/lib/proxysql:uid=65532,gid=65532 \
  -v "$config:/etc/proxysql/proxysql.cnf:ro" "$image" \
  -f -c /etc/proxysql/proxysql.cnf >/dev/null

i=0
until admin_error=$(docker run --rm --network "$network" "$fixture" \
  mariadb --skip-ssl -h proxysql -P 6032 -u radmin -pradmin \
  -e 'SELECT @@version' 2>&1); do
  i=$((i + 1))
  [ "$i" -lt 30 ] || {
    printf '%s\n' "$admin_error" >&2
    docker logs "$proxy" >&2
    fail 'ProxySQL admin listener did not become ready'
  }
  sleep 1
done

docker run --rm -i --network "$network" "$fixture" \
  mariadb --skip-ssl -h proxysql -P 6032 -u radmin -pradmin <<'EOF'
INSERT INTO mysql_servers(hostgroup_id, hostname, port) VALUES (0, 'backend', 3306);
LOAD MYSQL SERVERS TO RUNTIME;
INSERT INTO mysql_users(username, password, default_hostgroup, active, frontend, backend)
VALUES ('verity', 'verity', 0, 1, 1, 1);
LOAD MYSQL USERS TO RUNTIME;
EOF

runtime_user=$(docker run --rm --network "$network" "$fixture" \
  mariadb --skip-ssl --batch --skip-column-names \
  -h proxysql -P 6032 -u radmin -pradmin \
  -e "SELECT CONCAT(COUNT(*), ':', SUM(frontend), ':', SUM(backend)) FROM runtime_mysql_users WHERE username='verity'")
[ "$runtime_user" = '2:1:1' ] || {
  printf 'unexpected runtime user: %s\n' "$runtime_user" >&2
  fail 'ProxySQL did not load the test user'
}

result=$(docker run --rm --network "$network" "$fixture" \
  mariadb --skip-ssl --batch --skip-column-names \
  -h proxysql -P 6033 -u verity -pverity \
  -e 'SELECT 42')
[ "$result" = 42 ] || fail 'proxied MySQL query returned an unexpected result'

printf 'SMOKE PASS image=%s\n' "$image"
