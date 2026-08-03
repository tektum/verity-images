#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
flavor=${2:-plain}
container="verity-httpd-test-$$"
tls_container="verity-httpd-tls-test-$$"
tempdir=$(mktemp -d)
invalid_config="$tempdir/httpd.conf"
tls_config="$tempdir/httpd-tls.conf"
tls_key="$tempdir/tls.key"
tls_certificate="$tempdir/tls.crt"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$tls_container" >/dev/null 2>&1 || true
  rm -rf "$tempdir"
}
trap cleanup EXIT INT TERM

expected_entrypoint=null
if [ "$flavor" = fips ]; then
  expected_entrypoint='["/usr/bin/openssl-fips-activate"]'
fi
[ "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.StopSignal}}' "$image")" = "$expected_entrypoint [\"/usr/local/bin/httpd-foreground\"] \"SIGWINCH\"" ]

if [ "$flavor" = fips ]; then
  provider_log="$tempdir/provider.log"
  providers=$(docker run --rm --entrypoint /usr/bin/openssl-fips-activate "$image" openssl list -providers -verbose 2>"$provider_log")
  printf '%s\n' "$providers" | grep -q 'version: 3.1.2'
  printf '%s\n' "$providers" | grep -q 'status: active'
  grep -q 'fips.so: OK' "$provider_log"
  grep -q 'INSTALL PASSED' "$provider_log"
  grep -q 'VERIFY PASSED' "$provider_log"
  printf '' | docker run --rm --entrypoint /usr/bin/openssl-fips-activate "$image" openssl dgst -sha256 >/dev/null
  if printf '' | docker run --rm --entrypoint /usr/bin/openssl-fips-activate "$image" openssl dgst -md5 >/dev/null 2>&1; then
    exit 1
  fi
  module=$(mktemp "$tempdir/fips.so.XXXXXX")
  created=$(docker create "$image")
  docker cp "$created:/usr/lib/ossl-modules/fips.so" "$module"
  docker rm "$created" >/dev/null
  printf tampered >>"$module"
  if docker run --rm -v "$module:/usr/lib/ossl-modules/fips.so:ro" "$image" /usr/bin/true; then
    exit 1
  fi
  if docker run --rm --read-only --user 65532 \
    --tmpfs /run/openssl-fips:rw,noexec,nosuid,nodev,mode=0500 "$image" /usr/bin/true; then
    exit 1
  fi
  [ "$(docker run --rm "$image" sh -c 'printf %s "$1"' sh 'a b|c')" = 'a b|c' ]
fi

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

if [ "$flavor" = fips ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$tls_key" -out "$tls_certificate" >/dev/null 2>&1
  cat >"$tls_config" <<EOF
ServerRoot "/usr/local/apache2"
Listen 8443
ServerName localhost
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule ssl_module modules/mod_ssl.so
TypesConfig conf/mime.types
SSLEngine on
SSLCertificateFile /tmp/tls.crt
SSLCertificateKeyFile /tmp/tls.key
DocumentRoot "/usr/local/apache2/htdocs"
DirectoryIndex index.html
<Directory "/usr/local/apache2/htdocs">
  Require all granted
</Directory>
EOF
  docker run --name "$tls_container" -d -p 127.0.0.1::8443 \
    -v "$tls_config:/tmp/httpd.conf:ro" -v "$tls_key:/tmp/tls.key:ro" \
    -v "$tls_certificate:/tmp/tls.crt:ro" "$image" \
    httpd -DFOREGROUND -f /tmp/httpd.conf >/dev/null
  tls_port=$(docker port "$tls_container" 8443/tcp | awk -F: 'NR == 1 { print $2 }')
  i=0
  until curl --fail --silent --insecure --tlsv1.2 --tls-max 1.2 "https://127.0.0.1:$tls_port/" | grep -q 'It works!'; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || exit 1
    sleep 1
  done
  curl --fail --silent --insecure --tlsv1.3 --tls-max 1.3 "https://127.0.0.1:$tls_port/" | grep -q 'It works!'
  docker stop "$tls_container" >/dev/null
  [ "$(docker inspect --format '{{.State.ExitCode}}' "$tls_container")" = 0 ]
fi
