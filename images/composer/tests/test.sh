#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- composer=\([0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
tmp=$(mktemp -d)
chmod 777 "$tmp"

cleanup() {
  # Files are owned by the image's non-root user, so remove them as that user.
  docker run --rm -v "$tmp:/app" --entrypoint /bin/busybox "$image" \
    sh -c 'rm -rf /app/* /app/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

composer() {
  docker run --rm -v "$tmp:/app" "$image" "$@"
}

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532
test "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/composer"]'
test "$(docker image inspect "$image" --format '{{.Config.WorkingDir}}')" = /app

composer --version --no-ansi 2>&1 | grep -F "Composer version $expected_version" >/dev/null ||
  fail "composer does not report version $expected_version"
composer --version --no-ansi 2>&1 | grep -F 'PHP version 8.4.' >/dev/null ||
  fail 'composer is not running on PHP 8.4'

# A path repository package installed into a project exercises PHP, the
# autoloader generator, and the filesystem as the non-root user.
mkdir "$tmp/lib"
cat >"$tmp/lib/composer.json" <<'JSON'
{"name":"verity/smoke-lib","version":"1.0.0","autoload":{"psr-4":{"Verity\\Smoke\\":"src/"}}}
JSON
mkdir "$tmp/lib/src"
cat >"$tmp/lib/src/Greeter.php" <<'PHP'
<?php
namespace Verity\Smoke;
final class Greeter { public static function hello(): string { return 'hello-from-lib'; } }
PHP
composer init --no-interaction --name verity/smoke-app --description smoke --license MIT --no-ansi >/dev/null 2>&1 ||
  fail 'composer init failed'
composer config repositories.lib path /app/lib --no-ansi >/dev/null 2>&1 ||
  fail 'composer config failed'
composer validate --no-ansi >"$tmp/validate.log" 2>&1 || {
  cat "$tmp/validate.log" >&2
  fail 'composer validate failed'
}
composer require verity/smoke-lib:@dev --no-interaction --no-ansi >"$tmp/require.log" 2>&1 || {
  cat "$tmp/require.log" >&2
  fail 'composer require from path repository failed'
}
docker run --rm -v "$tmp:/app" --entrypoint /usr/bin/php "$image" \
  -r 'require "vendor/autoload.php"; echo Verity\Smoke\Greeter::hello();' |
  grep -F hello-from-lib >/dev/null || fail 'installed package is not autoloadable'

docker run --rm -v "$tmp:/app" --entrypoint /bin/busybox "$image" \
  sh -c "printf '{ not json' >/app/composer.json"
if composer validate --no-ansi >"$tmp/invalid.log" 2>&1; then
  fail 'invalid composer.json unexpectedly validated'
fi
grep -qi 'valid json\|parse' "$tmp/invalid.log" || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid composer.json error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
