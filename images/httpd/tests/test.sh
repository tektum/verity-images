#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-httpd-test-$$"
tempdir=$(mktemp -d)
invalid_config="$tempdir/httpd.conf"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tempdir"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.StopSignal}}' "$image")" = 'null ["/usr/local/bin/httpd-foreground"] "SIGWINCH"' ]

docker run --rm --entrypoint httpd "$image" -t
docker run --rm --entrypoint sh "$image" -c '
  set -eu
  [ "$(id -u www-data)" = 33 ] || { echo "unexpected www-data uid" >&2; exit 1; }
  [ "$(id -g www-data)" = 33 ] || { echo "unexpected www-data gid" >&2; exit 1; }
  for dir in conf modules htdocs cgi-bin; do
    [ -d "/usr/local/apache2/$dir" ] || { echo "missing directory: $dir" >&2; exit 1; }
  done
  modules=$(httpd -M)
  for module in authz_core_module mime_module; do
    printf "%s\n" "$modules" | grep -q "$module" || { echo "missing module: $module" >&2; exit 1; }
  done
  [ -f /etc/ssl/cert.pem ] || { echo "missing CA bundle" >&2; exit 1; }
  for binary in ab htpasswd rotatelogs; do
    [ -x "/usr/bin/$binary" ] || { echo "missing binary: $binary" >&2; exit 1; }
  done
'

docker run --name "$container" -d -p 127.0.0.1::80 "$image" >/dev/null
port=$(docker port "$container" 80/tcp | awk -F: 'NR == 1 { print $2 }')
i=0
until response=$(curl --fail --silent "http://127.0.0.1:$port/"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done
printf '%s' "$response" | grep -q 'It works!'

docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]

printf '%s\n' 'InvalidDirective' > "$invalid_config"
if docker run --rm -v "$invalid_config:/tmp/httpd.conf:ro" --entrypoint httpd "$image" -f /tmp/httpd.conf -t; then
  exit 1
fi
