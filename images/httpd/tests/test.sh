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
  [ "$(id -u www-data)" = 33 ] &&
  [ "$(id -g www-data)" = 33 ] &&
  [ -d /usr/local/apache2/conf ] &&
  [ -d /usr/local/apache2/modules ] &&
  [ -d /usr/local/apache2/htdocs ] &&
  [ -d /usr/local/apache2/cgi-bin ] &&
  httpd -M | grep -q authz_core_module &&
  httpd -M | grep -q mime_module &&
  [ -f /etc/ssl/cert.pem ] &&
  [ -x /usr/bin/ab ] &&
  [ -x /usr/bin/htpasswd ] &&
  [ -x /usr/bin/rotatelogs ]
'

docker run --name "$container" -d -p 127.0.0.1::80 "$image" >/dev/null
port=$(docker port "$container" 80/tcp | awk -F: 'NR == 1 { print $2 }')
i=0
until curl --fail --silent "http://127.0.0.1:$port/" >/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done

docker stop "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]

printf '%s\n' 'InvalidDirective' > "$invalid_config"
if docker run --rm -v "$invalid_config:/tmp/httpd.conf:ro" --entrypoint httpd "$image" -f /tmp/httpd.conf -t; then
  exit 1
fi
