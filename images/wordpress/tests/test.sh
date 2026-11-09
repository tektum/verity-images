#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
expected_version=$(sed -n 's/^[[:space:]]*- wordpress=\([0-9.]*\)-r[0-9]*$/\1/p' "$here/../apko.yaml")
[ -n "$expected_version" ] || { printf 'wordpress package version not found\n' >&2; exit 1; }
# Repository MariaDB image used as the database fixture.
mariadb_index='ghcr.io/tektum/mariadb@sha256:e4bb3755dcea9f8a05687def41b91b5dcbe385be2baccf73b9c1af876bcaeba4'
label=verity.test=wordpress-$$
db="verity-wordpress-db-$$"
app="verity-wordpress-app-$$"
app2="verity-wordpress-app2-$$"
bad="verity-wordpress-bad-$$"
network="verity-wordpress-network-$$"
volume="verity-wordpress-html-$$"
db_password=wordpress-smoke-password
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$app" "$app2" "$bad" "$db" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cp "$here/fcgi.php" "$tmp/fcgi.php"
chmod 755 "$tmp"
chmod 644 "$tmp/fcgi.php"

# fcgi CONTAINER OUT METHOD PATH QUERY [BODY]: one FastCGI request to PHP-FPM.
fcgi() {
  target=$1
  out=$2
  shift 2
  docker run --rm --network "$network" --label "$label" -v "$tmp/fcgi.php:/fcgi.php:ro" \
    --entrypoint /usr/bin/php "$image" /fcgi.php "$target" 9000 "$@" >"$out" 2>"$out.err"
}

expect_in() {
  grep -F -- "$2" "$1" >/dev/null || {
    cat "$1" "$1.err" >&2
    fail "$3"
  }
}

expect_not_in() {
  if grep -F -- "$2" "$1" >/dev/null; then
    cat "$1" >&2
    fail "$3"
  fi
}

wait_fpm() {
  attempts=0
  until docker logs "$1" 2>&1 | grep -F 'ready to handle connections' >/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] || { docker logs "$1" >&2; fail "PHP-FPM did not become ready: $1"; }
    sleep 1
  done
}

# Image contract.
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ||
  fail 'image must run as UID 65532'
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/local/bin/docker-entrypoint.sh"]' ||
  fail 'unexpected entrypoint'
test "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["php-fpm"]' ||
  fail 'unexpected command'
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /var/www/html ||
  fail 'unexpected working directory'
test "$(docker image inspect "$image" --format '{{.Config.StopSignal}}')" = SIGQUIT ||
  fail 'unexpected stop signal'

docker run --rm --entrypoint /usr/bin/php "$image" -r '
  exit(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 5 ? 0 : 1);' ||
  fail 'image is not running PHP 8.5'
docker run --rm --entrypoint /usr/bin/php "$image" -r '
  foreach (["mysqli", "curl", "dom", "exif", "fileinfo", "gd", "intl", "mbstring", "openssl", "sodium", "xml", "zip"] as $e) {
    if (!extension_loaded($e)) { fwrite(STDERR, "missing extension $e\n"); exit(1); }
  }' || fail 'required PHP extension missing'
docker run --rm --entrypoint /usr/bin/php "$image" -r '
  require "/usr/src/wordpress/wp-includes/version.php"; echo $wp_version;' >"$tmp/version" ||
  fail 'cannot read WordPress version'
test "$(cat "$tmp/version")" = "$expected_version" ||
  fail "WordPress version $(cat "$tmp/version") is not $expected_version"

# Pull the pinned helper index by its per-platform child digest, verifying the
# index bytes against the pin first so the pin stays authoritative.
image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
helper_raw=$(docker buildx imagetools inspect --raw "$mariadb_index") ||
  fail 'cannot inspect MariaDB helper index'
[ "sha256:$(printf '%s' "$helper_raw" | sha256sum | cut -d' ' -f1)" = "${mariadb_index#*@}" ] ||
  fail 'MariaDB helper index digest mismatch'
helper_digest=$(printf '%s' "$helper_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve MariaDB helper digest'
case $helper_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch MariaDB helper in $mariadb_index" ;;
esac
mariadb=${mariadb_index%%@*}@$helper_digest
docker pull --quiet --platform "linux/$image_arch" "$mariadb" >/dev/null ||
  fail 'cannot pull MariaDB helper image'

# The internal network keeps the install path offline and deterministic.
docker network create --internal --label "$label" "$network" >/dev/null
docker volume create --label "$label" "$volume" >/dev/null
docker run --name "$db" -d --label "$label" --network "$network" --network-alias db \
  -e MARIADB_ROOT_PASSWORD=root-smoke-password -e MARIADB_DATABASE=wordpress \
  -e MARIADB_USER=wordpress -e MARIADB_PASSWORD="$db_password" "$mariadb" >/dev/null
attempts=0
until docker exec -e MYSQL_PWD="$db_password" "$db" \
  mariadb -h 127.0.0.1 -u wordpress wordpress -Nse 'SELECT 1' >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 180 ] || { docker logs "$db" >&2; fail 'MariaDB fixture did not become ready'; }
  sleep 1
done

run_app() {
  docker run --name "$1" -d --label "$label" --network "$network" --network-alias "$1" \
    -v "$volume:/var/www/html" \
    -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_USER=wordpress \
    -e WORDPRESS_DB_PASSWORD="$2" -e WORDPRESS_DB_NAME=wordpress "$image" >/dev/null
  wait_fpm "$1"
}

run_app "$app" "$db_password"
docker logs "$app" 2>&1 | grep -F 'WordPress has been successfully copied' >/dev/null ||
  { docker logs "$app" >&2; fail 'entrypoint did not populate the work directory'; }
docker exec "$app" test -s /var/www/html/wp-config.php ||
  fail 'entrypoint did not generate wp-config.php'
test "$(docker exec "$app" stat -c '%u' /var/www/html/wp-config.php)" = 65532 ||
  fail 'wp-config.php is not owned by the runtime user'

# An uninstalled site redirects to the installer, which renders its form.
fcgi "$app" "$tmp/root" GET / '' || fail 'FastCGI request for / failed'
expect_in "$tmp/root" 'Location: http://wordpress.test/wp-admin/install.php' 'uninstalled site did not redirect to the installer'
fcgi "$app" "$tmp/install" GET /wp-admin/install.php 'step=1' || fail 'FastCGI request for install.php failed'
expect_not_in "$tmp/install" 'Error establishing a database connection' 'installer reported a database error'
expect_in "$tmp/install" 'name="weblog_title"' 'installer form missing'
expect_in "$tmp/install" 'name="admin_password"' 'installer password field missing'

# Complete the installation and assert the site title renders on /.
fcgi "$app" "$tmp/installed" POST /wp-admin/install.php 'step=2' \
  'weblog_title=Verity+Smoke+Site&user_name=smokeadmin&admin_password=smoke-admin-Pass-1&admin_password2=smoke-admin-Pass-1&pw_weak=1&admin_email=smoke%40example.com&blog_public=0' ||
  fail 'FastCGI install POST failed'
expect_in "$tmp/installed" 'Success!' 'WordPress installation did not succeed'
fcgi "$app" "$tmp/home" GET / '' || fail 'FastCGI request for installed / failed'
expect_not_in "$tmp/home" 'Status: 500' 'installed site returned an internal error'
expect_in "$tmp/home" '<title>Verity Smoke Site' 'installed site title missing'
test "$(docker exec -e MYSQL_PWD="$db_password" "$db" mariadb -h 127.0.0.1 -u wordpress wordpress \
  -Nse "SELECT option_value FROM wp_options WHERE option_name = 'blogname'")" = 'Verity Smoke Site' ||
  fail 'site title was not persisted in MariaDB'

# Negative: an unknown script is rejected by PHP-FPM.
fcgi "$app" "$tmp/missing" GET /no-such-script.php '' || fail 'FastCGI request for missing script failed'
expect_in "$tmp/missing" 'Status: 404' 'missing script did not return 404'

# Graceful stop on SIGQUIT, then a replacement container reuses the populated
# volume without recopying and serves the persisted site.
docker stop -t 20 "$app" >/dev/null
test "$(docker inspect "$app" --format '{{.State.ExitCode}}')" = 0 ||
  { docker logs "$app" >&2; fail 'PHP-FPM did not exit cleanly on stop'; }
run_app "$app2" "$db_password"
if docker logs "$app2" 2>&1 | grep -F 'copying now' >/dev/null; then
  fail 'entrypoint recopied WordPress over a populated volume'
fi
fcgi "$app2" "$tmp/home2" GET / '' || fail 'FastCGI request after restart failed'
expect_in "$tmp/home2" '<title>Verity Smoke Site' 'site title missing after restart'

# Negative: rejected database credentials surface the WordPress database error.
docker rm -f "$app2" >/dev/null
docker run --name "$bad" -d --label "$label" --network "$network" --network-alias "$bad" \
  -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=wrong-password -e WORDPRESS_DB_NAME=wordpress "$image" >/dev/null
wait_fpm "$bad"
fcgi "$bad" "$tmp/bad" GET /wp-admin/install.php 'step=1' || fail 'FastCGI request with bad credentials failed'
expect_in "$tmp/bad" 'Error establishing a database connection' 'bad credentials did not surface a database error'

printf 'SMOKE PASS image=%s wordpress=%s\n' "$image" "$expected_version"
