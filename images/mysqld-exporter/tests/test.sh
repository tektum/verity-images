#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
mysql_index='docker.io/library/mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902'
backend="verity-mysqld-exporter-mysql-$$"
exporter="verity-mysqld-exporter-exporter-$$"
orphan="verity-mysqld-exporter-orphan-$$"
network="verity-mysqld-exporter-network-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$exporter" "$orphan" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

wait_metrics() {
  # $1 container, $2 host port, $3 output file, $4 required line (fixed, whole line)
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$2/metrics" >"$3" 2>/dev/null && grep -Fx "$4" "$3" >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      docker logs "$1" >&2
      fail "metrics did not contain: $4"
    }
    sleep 1
  done
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/mysqld_exporter"]' ||
  fail 'unexpected entrypoint'
docker run --rm "$image" --version 2>&1 | grep -E 'mysqld_exporter, version 0\.' >/dev/null ||
  fail 'unexpected exporter version'

created=$(docker create "$image")
docker cp "$created:/usr/bin/mysqld_exporter" "$tmp/mysqld_exporter"
docker rm "$created" >/dev/null
if go version -m "$tmp/mysqld_exporter" | grep -q 'GOFIPS140='; then
  fail 'plain image must not set GOFIPS140'
fi

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull a pinned helper index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
resolve_helper() {
  helper_index=$1
  helper_raw=$(docker buildx imagetools inspect --raw "$helper_index") ||
    fail 'cannot inspect helper image index'
  [ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${helper_index#*@}" ] ||
    fail 'helper image index digest mismatch'
  helper_digest=$(printf '%s' "$helper_raw" |
    jq -r --arg arch "$image_arch" '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
      | if length == 1 then .[0] else empty end') ||
    fail 'cannot resolve helper image digest'
  case $helper_digest in
    sha256:*) ;;
    *) fail "no unique linux/$image_arch helper image in $helper_index" ;;
  esac
  helper=${helper_index%%:*}@$helper_digest
  docker pull --quiet --platform "linux/$image_arch" "$helper" >/dev/null ||
    fail 'cannot pull helper image'
}
resolve_helper "$mysql_index"
mysql=$helper

docker network create "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=root "$mysql" >/dev/null
attempts=0
until docker exec "$backend" mysqladmin ping -h 127.0.0.1 -u root -proot --silent >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || { docker logs "$backend" >&2; fail 'MySQL fixture did not become ready'; }
  sleep 1
done
docker exec "$backend" mysql -u root -proot -e \
  "CREATE USER 'exporter'@'%' IDENTIFIED BY 'exporter-secret' WITH MAX_USER_CONNECTIONS 3; GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%'" ||
  fail 'cannot create exporter user'

write_cnf() {
  cat >"$1" <<EOF
[client]
user=exporter
password=$2
host=mysql
port=3306
EOF
  chmod 644 "$1"
}
write_cnf "$tmp/good.cnf" exporter-secret
write_cnf "$tmp/bad.cnf" wrong-password

docker run --name "$exporter" -d --network "$network" --read-only \
  -v "$tmp/good.cnf:/tmp/my.cnf:ro" -p 127.0.0.1::9104 \
  "$image" --config.my-cnf=/tmp/my.cnf >/dev/null
port=$(docker port "$exporter" 9104/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$port"

wait_metrics "$exporter" "$port" "$tmp/metrics" 'mysql_up 1'
grep -F 'mysql_global_status_uptime' "$tmp/metrics" >/dev/null ||
  fail 'mysql_global_status_uptime missing'
grep -F 'mysql_version_info{' "$tmp/metrics" >/dev/null ||
  fail 'mysql_version_info missing'

# Rejected credentials must surface as mysql_up 0 while the exporter keeps serving.
docker run --name "$orphan" -d --network "$network" \
  -v "$tmp/bad.cnf:/tmp/my.cnf:ro" -p 127.0.0.1::9104 \
  "$image" --config.my-cnf=/tmp/my.cnf >/dev/null
orphan_port=$(docker port "$orphan" 9104/tcp | awk -F: 'NR == 1 { print $2 }')
wait_metrics "$orphan" "$orphan_port" "$tmp/orphan.metrics" 'mysql_up 0'

if docker run --rm "$image" --no-such-flag >"$tmp/invalid.log" 2>&1; then
  fail 'unknown flag unexpectedly succeeded'
fi
grep -F 'no-such-flag' "$tmp/invalid.log" >/dev/null ||
  fail 'unknown flag error missing'

# Without credentials the exporter must refuse to start.
if docker run --rm "$image" >"$tmp/nocfg.log" 2>&1; then
  fail 'exporter unexpectedly started without credentials'
fi
grep -F 'no configuration found' "$tmp/nocfg.log" >/dev/null ||
  fail 'missing no-configuration error'

printf 'SMOKE PASS image=%s\n' "$image"
