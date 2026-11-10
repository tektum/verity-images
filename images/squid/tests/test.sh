#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
label="verity-test=squid-$$"
network="verity-squid-net-$$"
container="verity-squid-test-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$*" >&2
  docker logs "$container" >&2 2>/dev/null || true
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] || fail 'wrong user'
entrypoint=$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')
[ "$entrypoint" = '["/usr/bin/squid","-N","-f","/etc/squid/squid.conf"]' ] || fail "wrong entrypoint: $entrypoint"

version=$(docker run --rm --label "$label" --entrypoint /usr/bin/squid "$image" -v 2>&1 | head -1)
printf '%s\n' "$version"
case "$version" in
  'Squid Cache: Version 7.'*) ;;
  *) fail "unexpected squid version: $version" ;;
esac

# Negative: an invalid configuration must be rejected with a readable error.
printf 'this_is_not_a_squid_directive on\n' > "$fixture/bad.conf"
chmod 755 "$fixture"
chmod 644 "$fixture/bad.conf"
status=0
bad=$(docker run --rm --label "$label" -v "$fixture/bad.conf:/etc/squid/bad.conf:ro" \
  --entrypoint /usr/bin/squid "$image" -k parse -f /etc/squid/bad.conf 2>&1) || status=$?
printf '%s\n' "$bad" | tail -3
[ "$status" -ne 0 ] || fail 'squid accepted an invalid configuration'

# Origin: a local http.server on the host, reached from the proxy through the host gateway.
mkdir "$fixture/www"
printf 'hello from the origin\n' > "$fixture/www/index.html"
origin_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 -m http.server "$origin_port" --bind 0.0.0.0 --directory "$fixture/www" >"$fixture/origin.log" 2>&1 &
origin_pid=$!
trap 'kill "$origin_pid" 2>/dev/null || true; cleanup' EXIT INT TERM
docker network create --label "$label" "$network" >/dev/null

# Proxy: the shipped default configuration, unchanged.
docker run --rm --label "$label" --entrypoint /usr/bin/squid "$image" -k parse -f /etc/squid/squid.conf >/dev/null 2>&1 ||
  fail 'the default squid.conf does not parse'
docker run -d --name "$container" --label "$label" --network "$network" \
  --add-host origin:host-gateway -p 127.0.0.1::3128 "$image" >/dev/null
port=$(docker port "$container" 3128/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'proxy port not published'

proxy="http://127.0.0.1:$port"
i=0
until curl -fsS --proxy "$proxy" -D "$fixture/h1" -o "$fixture/b1" http://origin:"$origin_port"/index.html 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'squid never proxied the origin'
  sleep 1
done
grep -qx 'hello from the origin' "$fixture/b1" || fail "wrong body through the proxy: $(cat "$fixture/b1")"
tr -d '\r' < "$fixture/h1" | grep -qi '^via: 1\.1 squid (squid/7\.' || fail "no Via header from squid: $(cat "$fixture/h1")"
tr -d '\r' < "$fixture/h1" | grep -qi '^cache-status: squid;' || fail "no Cache-Status header from squid: $(cat "$fixture/h1")"

# Negative: a port outside Safe_ports and a CONNECT to a non-TLS port get 403 from the proxy.
code=$(curl -sS --proxy "$proxy" -o /dev/null -w '%{http_code}' http://origin:25/ || true)
[ "$code" = 403 ] || fail "unsafe port returned $code, want 403"
code=$(curl -sS --proxytunnel --proxy "$proxy" -o /dev/null -w '%{http_code}' http://origin:"$origin_port"/index.html 2>/dev/null || true)
case "$code" in
  403|000) ;;
  *) fail "CONNECT to a non-TLS port returned $code, want a refusal" ;;
esac

# The access log reaches stdout as the non-root user.
log=$(docker logs "$container" 2>&1)
printf '%s\n' "$log" | grep -q 'TCP_DENIED/403 .* GET http://origin:25/' || fail 'access log does not show the denied GET'
printf '%s\n' "$log" | grep -q 'TCP_DENIED/403 .* CONNECT origin:' || fail 'access log does not show the denied CONNECT'
