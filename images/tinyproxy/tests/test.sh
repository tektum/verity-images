#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label="verity-test=tinyproxy-$$"
container="verity-tinyproxy-test-$$"
default_container="verity-tinyproxy-default-$$"
fixture=$(mktemp -d)
origin_pid=

cleanup() {
  docker rm -f "$container" "$default_container" >/dev/null 2>&1 || true
  [ -z "$origin_pid" ] || kill "$origin_pid" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  docker logs "$container" >&2 2>/dev/null || true
  docker logs "$default_container" >&2 2>/dev/null || true
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] || fail 'wrong user'
entrypoint=$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')
[ "$entrypoint" = '["/usr/bin/tinyproxy","-d"]' ] || fail "wrong entrypoint: $entrypoint"

# stdout only: docker prints a platform mismatch warning on stderr for emulated arm64 runs.
version=$(docker run --rm --label "$label" "$image" -v)
printf '%s\n' "$version"
case "$version" in
  'tinyproxy 1.11.'*) ;;
  *) fail "unexpected tinyproxy version: $version" ;;
esac

# Negative: an unknown directive must be rejected before the proxy starts.
chmod 755 "$fixture"
printf 'Port 8888\nThisIsNotADirective yes\n' >"$fixture/bad.conf"
chmod 644 "$fixture/bad.conf"
status=0
docker run --rm --label "$label" -v "$fixture/bad.conf:/etc/tinyproxy/bad.conf:ro" \
  "$image" -c /etc/tinyproxy/bad.conf >"$fixture/bad.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'tinyproxy accepted an invalid configuration'
grep -qi 'syntax error' "$fixture/bad.log" || fail "no syntax error reported: $(cat "$fixture/bad.log")"

# Origin: a local http.server on the host, reached from the proxy through the host gateway.
mkdir "$fixture/www"
printf 'hello from the origin\n' >"$fixture/www/index.html"
origin_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 -m http.server "$origin_port" --bind 0.0.0.0 --directory "$fixture/www" >"$fixture/origin.log" 2>&1 &
origin_pid=$!

# Fixture configuration: any client may connect, one destination is filtered.
cat >"$fixture/tinyproxy.conf" <<'CONF'
Port 8888
Listen 0.0.0.0
Timeout 30
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogLevel Info
MaxClients 20
Allow 0.0.0.0/0
ViaProxyName "verity-smoke"
Filter "/etc/tinyproxy/filter"
FilterType ere
FilterDefaultDeny No
CONF
printf '^blocked\\.example$\n' >"$fixture/filter"
chmod 644 "$fixture/tinyproxy.conf" "$fixture/filter"

docker run -d --name "$container" --label "$label" --read-only \
  --add-host origin:host-gateway --add-host blocked.example:host-gateway \
  -v "$fixture/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
  -v "$fixture/filter:/etc/tinyproxy/filter:ro" \
  -p 127.0.0.1::8888 "$image" >/dev/null
port=$(docker port "$container" 8888/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'proxy port not published'
proxy="http://127.0.0.1:$port"

i=0
until curl -fsS --max-time 5 --proxy "$proxy" -D "$fixture/h1" -o "$fixture/b1" \
  http://origin:"$origin_port"/index.html 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'tinyproxy never proxied the origin'
  sleep 1
done
grep -qx 'hello from the origin' "$fixture/b1" || fail "wrong body through the proxy: $(cat "$fixture/b1")"
tr -d '\r' <"$fixture/h1" | grep -qix 'via: 1\.1 verity-smoke (tinyproxy)' ||
  fail "no Via header from tinyproxy: $(cat "$fixture/h1")"

# Negative: a filtered destination is refused by the proxy, not the origin.
code=$(curl -sS --max-time 5 --proxy "$proxy" -o "$fixture/b2" -w '%{http_code}' \
  http://blocked.example:"$origin_port"/index.html || true)
[ "$code" = 403 ] || fail "filtered destination returned $code, want 403"
grep -q 'Filtered' "$fixture/b2" || fail "403 body does not come from the filter: $(cat "$fixture/b2")"

# The worker runs as the image user, not root.
uid=$(docker top "$container" -o pid,uid,comm | awk '$3 == "tinyproxy" { print $2; exit }')
[ "$uid" = 65532 ] || fail "tinyproxy runs as uid $uid, want 65532"

# Logs reach the container output.
logs=$(docker logs "$container" 2>&1)
printf '%s\n' "$logs" | grep -q 'Request (file descriptor' || fail 'request log missing from container output'

# Negative: the shipped default configuration only admits loopback clients,
# so a client outside the container is denied.
docker run -d --name "$default_container" --label "$label" --read-only \
  --add-host origin:host-gateway -p 127.0.0.1::8888 "$image" >/dev/null
dport=$(docker port "$default_container" 8888/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$dport" ] || fail 'default proxy port not published'
i=0
code=000
while [ "$code" = 000 ]; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail 'default configuration never answered'
  code=$(curl -sS --max-time 5 --proxy "http://127.0.0.1:$dport" -o "$fixture/b3" -w '%{http_code}' \
    http://origin:"$origin_port"/index.html 2>/dev/null || true)
  [ "$code" != 000 ] || sleep 1
done
[ "$code" = 403 ] || fail "default configuration let an outside client through: $code"
grep -q 'Access denied' "$fixture/b3" || fail "403 body is not an ACL denial: $(cat "$fixture/b3")"

printf 'SMOKE PASS\n'
