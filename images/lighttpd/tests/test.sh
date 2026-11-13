#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
container="lighttpd-smoke-$$"
tls_container="lighttpd-smoke-tls-$$"

cleanup() {
  docker rm -f "$container" "$tls_container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/lighttpd","-D","-f","/etc/lighttpd/lighttpd.conf"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGINT ||
  fail 'unexpected stop signal'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /var/www/html ||
  fail 'unexpected working directory'

docker run --rm --network none --entrypoint /usr/bin/lighttpd "$image" -v |
  grep -E '^lighttpd/1\.4\.[0-9]+' >/dev/null || fail 'lighttpd version output is missing'
features=$(docker run --rm --network none --entrypoint /usr/bin/lighttpd "$image" -V)
for feature in 'OpenSSL support' 'zlib support' 'PCRE support'; do
  printf '%s\n' "$features" | grep -F "+ $feature" >/dev/null || fail "lighttpd lacks $feature"
done

mkdir -p "$work/html/sub"
printf '<h1>verity lighttpd smoke</h1>\n' >"$work/html/index.html"
printf 'plain body\n' >"$work/html/sub/note.txt"
cat >"$work/lighttpd.conf" <<'EOF'
server.document-root = "/var/www/html"
server.port = 8080
server.errorlog = "/dev/stderr"
server.modules += ("mod_access")
index-file.names = ("index.html")
mimetype.assign = (".html" => "text/html", ".txt" => "text/plain")
url.access-deny = ("~", ".inc")
EOF
chmod -R a+rX "$work"

docker run --rm --network none -v "$work/lighttpd.conf:/etc/lighttpd/lighttpd.conf:ro" \
  "$image" -tt >/dev/null 2>&1 || fail 'valid configuration did not pass -tt'

# Negative: a syntactically broken configuration must be rejected.
printf 'server.port = \n' >"$work/broken.conf"
chmod 0644 "$work/broken.conf"
if docker run --rm --network none -v "$work/broken.conf:/etc/lighttpd/lighttpd.conf:ro" \
  "$image" -tt >/dev/null 2>&1; then
  fail 'broken configuration unexpectedly passed -tt'
fi

# Negative: the image ships no configuration, so a bare start must fail.
if docker run --rm --network none "$image" >/dev/null 2>&1; then
  fail 'server started without a configuration'
fi

docker run -d --name "$container" --read-only \
  -v "$work/lighttpd.conf:/etc/lighttpd/lighttpd.conf:ro" \
  -v "$work/html:/var/www/html:ro" \
  -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published port'

attempt=0
until body=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'lighttpd did not become ready'
  sleep 1
done
printf '%s\n' "$body" | grep -F '<h1>verity lighttpd smoke</h1>' >/dev/null || fail 'index body is wrong'

headers=$(curl --fail --silent --head --max-time 5 "http://127.0.0.1:$port/sub/note.txt")
printf '%s\n' "$headers" | grep -iE '^Content-Type: text/plain' >/dev/null || fail 'text/plain content type missing'
printf '%s\n' "$headers" | grep -iE '^Server: lighttpd/1\.4\.' >/dev/null || fail 'server header missing'
test "$(curl --fail --silent --max-time 5 "http://127.0.0.1:$port/sub/note.txt")" = 'plain body' ||
  fail 'static file body is wrong'

status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "http://127.0.0.1:$port/missing")
test "$status" = 404 || fail "missing file returned $status, expected 404"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "http://127.0.0.1:$port/index.html~")
test "$status" = 403 || fail "denied suffix returned $status, expected 403"

docker exec "$container" /usr/bin/lighttpd -v >/dev/null 2>&1 || fail 'exec into running server failed'
test "$(docker inspect --format '{{.Config.User}}' "$container")" = 65532 || fail 'container user changed'

docker stop --time 15 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ||
  fail 'graceful shutdown did not exit 0'

# TLS with the built-in OpenSSL backend.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1 || fail 'test certificate generation failed'
chmod 0644 "$work/key.pem" "$work/cert.pem"
cat >"$work/tls.conf" <<'EOF'
server.document-root = "/var/www/html"
server.port = 8443
server.errorlog = "/dev/stderr"
server.modules += ("mod_openssl")
index-file.names = ("index.html")
mimetype.assign = (".html" => "text/html")
ssl.engine = "enable"
ssl.pemfile = "/etc/lighttpd/cert.pem"
ssl.privkey = "/etc/lighttpd/key.pem"
EOF
chmod 0644 "$work/tls.conf"
docker run -d --name "$tls_container" --read-only \
  -v "$work/tls.conf:/etc/lighttpd/lighttpd.conf:ro" \
  -v "$work/cert.pem:/etc/lighttpd/cert.pem:ro" \
  -v "$work/key.pem:/etc/lighttpd/key.pem:ro" \
  -v "$work/html:/var/www/html:ro" \
  -p 127.0.0.1::8443 "$image" >/dev/null
tls_port=$(docker port "$tls_container" 8443/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$tls_port" ] || fail 'no published TLS port'
attempt=0
until body=$(curl --fail --silent --insecure --connect-timeout 1 --max-time 5 "https://127.0.0.1:$tls_port/"); do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || { docker logs "$tls_container" >&2 2>&1 || true; fail 'TLS listener did not become ready'; }
  sleep 1
done
printf '%s\n' "$body" | grep -F 'verity lighttpd smoke' >/dev/null || fail 'TLS body is wrong'

# Negative: plain HTTP on the TLS port must not return the page.
if curl --fail --silent --max-time 5 "http://127.0.0.1:$tls_port/" 2>/dev/null | grep -F 'verity lighttpd smoke' >/dev/null; then
  fail 'TLS port served plain HTTP'
fi

printf 'SMOKE PASS image=%s\n' "$image"
