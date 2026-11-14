#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config="$here/../apko.yaml"
# 8.4.0.7 in Wolfi is the upstream 8.4.0-7 release.
pkg_version=$(sed -n 's/^    - percona-xtrabackup-8\.4=\([0-9.]*\)-r[0-9]*$/\1/p' "$config")
version=$(printf '%s\n' "$pkg_version" | sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\)\.\([0-9]*\)$/\1-\2/')
mysql_index='docker.io/library/mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902'
suffix="verity-xtrabackup-$$"
source_db="$suffix-source"
restored_db="$suffix-restored"
network="$suffix-network"
backup_volume="$suffix-backup"
restore_volume="$suffix-restore"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$source_db" "$restored_db" >/dev/null 2>&1 || true
  docker volume rm "$backup_volume" "$restore_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -n "$pkg_version" ] || fail 'could not read the pinned percona-xtrabackup-8.4 version'

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/xtrabackup"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = null ||
  fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /work ||
  fail 'unexpected working directory'

docker run --rm --network none "$image" --version >"$tmp/version" 2>&1 ||
  fail "version failed: $(cat "$tmp/version")"
grep -E "^/usr/bin/xtrabackup version $version based on MySQL server 8\.4\." "$tmp/version" >/dev/null ||
  fail "version does not report $version: $(cat "$tmp/version")"
for tool in xbstream xbcrypt xbcloud; do
  docker run --rm --network none --entrypoint "/usr/bin/$tool" "$image" --version >"$tmp/$tool" 2>&1 ||
    fail "$tool --version failed: $(cat "$tmp/$tool")"
  grep -F "$tool" "$tmp/$tool" >/dev/null || fail "unexpected $tool version: $(cat "$tmp/$tool")"
done

# Without a mode (--backup, --prepare, --copy-back) xtrabackup prints its usage
# and fails.
rc=0
docker run --rm --network none "$image" >"$tmp/nomode" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'running without a mode unexpectedly succeeded'
grep -F 'Open source backup tool for InnoDB and XtraDB' "$tmp/nomode" >/dev/null ||
  fail "usage is missing: $(head -20 "$tmp/nomode")"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned MySQL index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen, which keeps
# the pin authoritative.
mysql_raw=$(docker buildx imagetools inspect --raw "$mysql_index") ||
  fail 'cannot inspect the MySQL image index'
[ "sha256:$(printf '%s' "$mysql_raw" | sha256sum | cut -d' ' -f1)" = "${mysql_index#*@}" ] ||
  fail 'MySQL image index digest mismatch'
mysql_digest=$(printf '%s' "$mysql_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve the MySQL image digest'
case $mysql_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch MySQL image in $mysql_index" ;;
esac
mysql=${mysql_index%%:*}@$mysql_digest
docker pull --quiet --platform "linux/$image_arch" "$mysql" >/dev/null ||
  fail 'cannot pull the MySQL image'

# The backup runs as the MySQL data owner so it can read the live data
# directory; the image itself keeps its non-root default user.
mysql_uid=$(docker run --rm --entrypoint id "$mysql" -u mysql)
mysql_gid=$(docker run --rm --entrypoint id "$mysql" -g mysql)

wait_mysql() {
  attempts=0
  until docker exec "$1" mysql -h 127.0.0.1 -u root -proot -e 'SELECT 1' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 90 ] || { docker logs "$1" >&2; fail "MySQL $1 did not become ready"; }
    sleep 1
  done
}

sql() {
  container=$1
  shift
  docker exec "$container" mysql -h 127.0.0.1 -u root -proot -N -B -e "$*"
}

docker network create "$network" >/dev/null
docker volume create "$backup_volume" >/dev/null
docker volume create "$restore_volume" >/dev/null
# xbstream extracts into an existing directory.
docker run --rm -v "$backup_volume:/backup" -v "$restore_volume:/restore" --entrypoint sh "$mysql" \
  -c "mkdir /backup/streamed && chown -R $mysql_uid:$mysql_gid /backup /restore" ||
  fail 'cannot prepare the backup volumes'

docker run --name "$source_db" -d --network "$network" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=root "$mysql" >/dev/null
wait_mysql "$source_db"
sql "$source_db" "
  CREATE DATABASE shop;
  CREATE TABLE shop.orders (id INT PRIMARY KEY, item VARCHAR(32) NOT NULL) ENGINE=InnoDB;
  INSERT INTO shop.orders VALUES (1, 'apple'), (2, 'pear'), (3, 'plum');
  CREATE USER 'backup'@'%' IDENTIFIED BY 'backup-secret';
  GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'%';
  GRANT SELECT ON performance_schema.log_status TO 'backup'@'%';
  GRANT SELECT ON performance_schema.keyring_component_status TO 'backup'@'%';
  GRANT SELECT ON performance_schema.replication_group_members TO 'backup'@'%';
" || fail 'cannot seed the source database'
source_checksum=$(sql "$source_db" 'CHECKSUM TABLE shop.orders' | cut -f2)

# xtrabackup reads the live data directory through the shared volume and talks
# to the server over TCP; the root filesystem stays read-only.
xb() {
  docker run --rm --network "$network" --read-only --cap-drop=ALL \
    --user "$mysql_uid:$mysql_gid" --tmpfs /tmp:mode=1777 \
    --volumes-from "$source_db:ro" -v "$backup_volume:/backup" -v "$restore_volume:/restore" \
    "$image" "$@"
}

rc=0
xb --backup --host=mysql --port=3306 --user=backup --password=wrong-password \
  --target-dir=/backup/denied >"$tmp/denied" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'backup with a wrong password unexpectedly succeeded'
grep -F "Access denied for user 'backup'" "$tmp/denied" >/dev/null ||
  fail "access denied diagnostic is missing: $(cat "$tmp/denied")"

xb --backup --host=mysql --port=3306 --user=backup --password=backup-secret \
  --datadir=/var/lib/mysql --target-dir=/backup/full >"$tmp/backup" 2>&1 ||
  fail "backup failed: $(tail -40 "$tmp/backup")"
grep -F 'completed OK!' "$tmp/backup" >/dev/null || fail "backup did not complete: $(tail -40 "$tmp/backup")"

# Rows written after the backup must not appear in the restored copy.
sql "$source_db" "INSERT INTO shop.orders VALUES (4, 'late')" || fail 'cannot write after the backup'

rc=0
xb --prepare --target-dir=/backup/missing >"$tmp/missing" 2>&1 || rc=$?
test "$rc" -ne 0 || fail 'prepare of a missing backup unexpectedly succeeded'

xb --prepare --target-dir=/backup/full >"$tmp/prepare" 2>&1 ||
  fail "prepare failed: $(tail -40 "$tmp/prepare")"
grep -F 'completed OK!' "$tmp/prepare" >/dev/null || fail "prepare did not complete: $(tail -40 "$tmp/prepare")"

xb --copy-back --target-dir=/backup/full --datadir=/restore >"$tmp/copyback" 2>&1 ||
  fail "copy-back failed: $(tail -40 "$tmp/copyback")"
grep -F 'completed OK!' "$tmp/copyback" >/dev/null || fail "copy-back did not complete: $(tail -40 "$tmp/copyback")"

# A second server started on the restored data directory serves the backed-up
# rows with the same checksum, and not the row written after the backup.
docker run --name "$restored_db" -d --network "$network" \
  -v "$restore_volume:/var/lib/mysql" "$mysql" >/dev/null
wait_mysql "$restored_db"
rows=$(sql "$restored_db" 'SELECT GROUP_CONCAT(item ORDER BY id) FROM shop.orders') ||
  fail 'cannot query the restored server'
test "$rows" = 'apple,pear,plum' || fail "unexpected restored rows: $rows"
test "$(sql "$restored_db" 'CHECKSUM TABLE shop.orders' | cut -f2)" = "$source_checksum" ||
  fail 'restored table checksum differs from the source at backup time'
sql "$restored_db" 'CHECK TABLE shop.orders' | grep -E 'status[[:space:]]+OK' >/dev/null ||
  fail 'restored table does not pass CHECK TABLE'

# A streamed backup unpacks with xbstream from the same image.
docker run --rm --network "$network" --read-only --cap-drop=ALL \
  --user "$mysql_uid:$mysql_gid" --tmpfs /tmp:mode=1777 --volumes-from "$source_db:ro" \
  "$image" --backup --host=mysql --port=3306 --user=backup --password=backup-secret \
  --datadir=/var/lib/mysql --target-dir=/tmp --stream=xbstream 2>"$tmp/stream.log" |
  docker run --rm -i --network none --read-only --cap-drop=ALL \
    --user "$mysql_uid:$mysql_gid" -v "$backup_volume:/backup" --entrypoint /usr/bin/xbstream \
    "$image" -x -C /backup/streamed --parallel=2 2>"$tmp/unpack.log" ||
  fail "streamed backup failed: $(tail -20 "$tmp/stream.log") $(cat "$tmp/unpack.log")"
grep -F 'completed OK!' "$tmp/stream.log" >/dev/null || fail "streamed backup did not complete: $(tail -40 "$tmp/stream.log")"
xb --prepare --target-dir=/backup/streamed >"$tmp/prepare-streamed" 2>&1 ||
  fail "prepare of the streamed backup failed: $(tail -40 "$tmp/prepare-streamed")"

printf 'SMOKE PASS image=%s\n' "$image"
