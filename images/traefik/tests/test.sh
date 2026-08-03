#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
version=v3.7.10
container="verity-traefik-test-$$"
created=
binary=$(mktemp)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$created" ] || docker rm -f "$created" >/dev/null 2>&1 || true
  rm -f "$binary"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/traefik"]' ]
case $(docker image inspect --format '{{json .Config.Cmd}}' "$image") in null|'[]') ;; *) exit 1;; esac
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ]

created=$(docker create "$image")
contents=$(docker export "$created" | tar -tf -)
printf '%s\n' "$contents" | grep -qx 'usr/bin/traefik'
printf '%s\n' "$contents" | grep -q '^etc/traefik/'
if printf '%s\n' "$contents" | grep -Eq 'openssl-fips-provider|openssl-fips-activate|usr/lib/ossl-modules/fips\.so'; then
  exit 1
fi
docker cp "$created:/usr/bin/traefik" "$binary"
docker rm "$created" >/dev/null
created=

if [ "$flavor" = fips ]; then
  go version -m "$binary" | grep -q 'GOFIPS140=v1.0.0'
  docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'GODEBUG=fips140=only'
else
  if go version -m "$binary" | grep -q 'GOFIPS140='; then
    exit 1
  fi
  docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" | grep -qx 'GODEBUG=fips140=off'
fi

docker run --rm --user 65532 "$image" version | grep -q "Version:.*$version"
docker run --rm --user 65532 "$image" --help >/dev/null

docker run --name "$container" -d --read-only --user 65532 \
  -p 127.0.0.1::8080 -p 127.0.0.1::8443 "$image" \
  --entrypoints.web.address=:8000 --entrypoints.websecure.address=:8443 \
  --entrypoints.websecure.http.tls=true --ping --api.insecure >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
secure_port=$(docker port "$container" 8443/tcp | awk -F: 'NR == 1 { print $2 }')

i=0
until response=$(curl --fail --silent "http://127.0.0.1:$port/ping"); do
  i=$((i + 1))
  [ "$i" -lt 20 ] || exit 1
  sleep 1
done
printf '%s' "$response" | grep -qx 'OK'
curl --fail --silent "http://127.0.0.1:$port/api/version" | grep -q "\"Version\":\"$version\""
curl --fail --silent "http://127.0.0.1:$port/dashboard/" | grep -q '<title>Traefik Proxy</title>'

openssl s_client -connect "127.0.0.1:$secure_port" -tls1_2 \
  -cipher ECDHE-RSA-AES128-GCM-SHA256 </dev/null 2>&1 | grep -q 'Cipher is ECDHE-RSA-AES128-GCM-SHA256'
if [ "$flavor" = fips ]; then
  if openssl s_client -connect "127.0.0.1:$secure_port" -tls1_2 \
    -cipher ECDHE-RSA-CHACHA20-POLY1305 </dev/null >/dev/null 2>&1; then
    exit 1
  fi
else
  openssl s_client -connect "127.0.0.1:$secure_port" -tls1_2 \
    -cipher ECDHE-RSA-CHACHA20-POLY1305 </dev/null 2>&1 | grep -q 'Cipher is ECDHE-RSA-CHACHA20-POLY1305'
fi
