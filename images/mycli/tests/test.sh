#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^    - mycli=\([0-9][0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'mycli package pin not found' >&2; exit 1; }
mysql_index='docker.io/library/mysql:8.4@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902'
backend="verity-mycli-mysql-$$"
network="verity-mycli-network-$$"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

user=$(docker image inspect -f '{{.Config.User}}' "$image")
[ "$user" = 65532 ] || fail "image user is $user, want 65532"
entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$image")
[ "$entrypoint" = '["/usr/bin/mycli"] null' ] || fail "unexpected entrypoint: $entrypoint"
workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")
[ "$workdir" = /work ] || fail "unexpected working directory: $workdir"

version=$(timeout 60 docker run --rm --network none "$image" --version 2>&1) ||
  fail "mycli --version failed: $version"
[ "$version" = "mycli, version $expected_version" ] ||
  fail "unexpected version '$version', want mycli, version $expected_version"

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned MySQL index by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen.
mysql_raw=$(docker buildx imagetools inspect --raw "$mysql_index") ||
  fail 'cannot inspect the MySQL fixture index'
[ "sha256:$(printf '%s' "$mysql_raw" | sha256sum | cut -d' ' -f1)" = "${mysql_index#*@}" ] ||
  fail 'MySQL fixture index digest mismatch'
mysql_digest=$(printf '%s' "$mysql_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve the MySQL fixture digest'
case $mysql_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch MySQL fixture in $mysql_index" ;;
esac
mysql=${mysql_index%%:*}@$mysql_digest
docker pull --quiet --platform "linux/$image_arch" "$mysql" >/dev/null || fail 'cannot pull the MySQL fixture'

docker network create --internal "$network" >/dev/null
docker run --name "$backend" -d --network "$network" --network-alias mysql \
  -e MYSQL_ROOT_PASSWORD=root-secret "$mysql" >/dev/null
attempts=0
until docker exec "$backend" mysqladmin ping -h 127.0.0.1 -u root -proot-secret --silent >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 90 ] || { docker logs "$backend" >&2; fail 'MySQL fixture did not become ready'; }
  sleep 1
done
docker exec "$backend" mysql -u root -proot-secret -e "
  CREATE DATABASE smoke;
  CREATE TABLE smoke.fruit (id INT PRIMARY KEY, name VARCHAR(32) NOT NULL);
  INSERT INTO smoke.fruit VALUES (1, 'apple'), (2, 'banana');
  CREATE USER 'smoke'@'%' IDENTIFIED BY 'smoke-secret';
  GRANT SELECT, INSERT ON smoke.* TO 'smoke'@'%';" >/dev/null 2>&1 ||
  fail 'cannot seed the MySQL fixture'

printf '%s' smoke-secret >"$work/password"
cat >"$work/insert.sql" <<'EOF'
INSERT INTO fruit VALUES (3, 'cherry');
SELECT COUNT(*) AS total FROM fruit;
EOF
chmod 0755 "$work"
chmod 0644 "$work/password" "$work/insert.sql"

mycli() {
  timeout 60 docker run --rm --network "$network" -v "$work:/work:ro" "$image" \
    -h mysql -u smoke --password-file /work/password "$@"
}

mycli -D smoke --csv -e 'SELECT id, name FROM fruit ORDER BY id' >"$work/select.txt" 2>"$work/select.err" ||
  { cat "$work/select.txt" "$work/select.err" >&2; fail 'mycli --execute query failed'; }
printf '"id","name"\n"1","apple"\n"2","banana"\n' >"$work/select.want"
cmp -s "$work/select.txt" "$work/select.want" ||
  { cat "$work/select.txt" >&2; fail 'mycli --csv output does not match the seeded rows'; }

mycli -D smoke --format=tsv --batch /work/insert.sql >"$work/batch.txt" 2>"$work/batch.err" ||
  { cat "$work/batch.txt" "$work/batch.err" >&2; fail 'mycli --batch script failed'; }
grep -Fx 3 "$work/batch.txt" >/dev/null || { cat "$work/batch.txt" >&2; fail 'batch script did not count 3 rows'; }
stored=$(docker exec "$backend" mysql -N -u root -proot-secret -e "SELECT name FROM smoke.fruit WHERE id = 3" 2>/dev/null)
[ "$stored" = cherry ] || fail "batch insert was not committed, server has '$stored'"

# The connection URL form selects the database.
timeout 60 docker run --rm --network "$network" "$image" \
  mysql://smoke:smoke-secret@mysql:3306/smoke --csv -e 'SELECT DATABASE() AS db' >"$work/url.txt" 2>"$work/url.err" ||
  { cat "$work/url.txt" "$work/url.err" >&2; fail 'mycli connection URL failed'; }
grep -Fx '"smoke"' "$work/url.txt" >/dev/null || { cat "$work/url.txt" >&2; fail 'connection URL did not select the database'; }

# Negative cases: wrong password, a denied statement, an unknown option.
if timeout 60 docker run --rm --network "$network" "$image" \
  -h mysql -u smoke -p wrong-password -D smoke -e 'SELECT 1' >"$work/denied.txt" 2>&1; then
  fail 'a wrong password was accepted'
fi
grep -F "Access denied for user 'smoke'" "$work/denied.txt" >/dev/null ||
  { cat "$work/denied.txt" >&2; fail 'wrong password error does not say access denied'; }
if mycli -D smoke -e 'DROP TABLE fruit' >"$work/drop.txt" 2>&1; then
  fail 'a statement without privilege succeeded'
fi
grep -F 'DROP command denied' "$work/drop.txt" >/dev/null ||
  { cat "$work/drop.txt" >&2; fail 'privilege error was not reported'; }
if timeout 60 docker run --rm --network none "$image" --no-such-option >"$work/flag.txt" 2>&1; then
  fail 'unknown option was accepted'
fi
grep -F 'no-such-option' "$work/flag.txt" >/dev/null ||
  { cat "$work/flag.txt" >&2; fail 'unknown option error does not name it'; }

printf '%s\n' "mycli $expected_version smoke test passed"
