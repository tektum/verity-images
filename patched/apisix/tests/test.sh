#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}

fail() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/docker-entrypoint.sh"]' ] || fail "unexpected entrypoint"
[ "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = '["docker-start"]' ] || fail "unexpected command"
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = apisix ] || fail "unexpected user"
[ "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /usr/local/apisix ] || fail "unexpected working directory"
[ "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGQUIT ] || fail "unexpected stop signal"

exposed_ports=$(docker image inspect --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' "$image")
[ "$(printf '%s\n' "$exposed_ports" | grep -c .)" -eq 2 ] || fail "unexpected exposed port count"
for port in 9080 9443; do
  printf '%s\n' "$exposed_ports" | grep -qx "$port/tcp" || fail "missing exposed port $port"
done

arch=$(docker image inspect --format '{{.Architecture}}' "$image")
case $arch in amd64 | arm64) ;; *) fail "unsupported candidate architecture $arch" ;; esac

work=$(mktemp -d)
backend=verity-apisix-backend-$$
gateway=verity-apisix-gateway-$$
token=verity-apisix-$$-$(date +%s)

cleanup() {
  docker rm -f "$gateway" "$backend" >/dev/null 2>&1 || :
  rm -rf "$work"
}
trap cleanup 0 1 2 3 15

# The backend is the image's own OpenResty serving a fixed body, so the test needs no other image.
cat >"$work/backend.conf" <<EOF
worker_processes 1;
pid /tmp/verity-backend.pid;
events {}
http {
  access_log off;
  server {
    listen 8080;
    location / {
      default_type text/plain;
      return 200 "backend $token uri=\$request_uri\n";
    }
  }
}
EOF
chmod 644 "$work/backend.conf"
docker run -d --name "$backend" -v "$work/backend.conf:/tmp/verity-backend.conf:ro" \
  --entrypoint openresty "$image" -p /tmp/ -e stderr -c /tmp/verity-backend.conf -g 'daemon off;' >/dev/null ||
  fail "backend did not start"
backend_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$backend")
[ -n "$backend_ip" ] || fail "backend has no address"

cat >"$work/config.yaml" <<'EOF'
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
EOF
cat >"$work/apisix.yaml" <<EOF
routes:
  - id: verity
    uri: /hello
    upstream:
      type: roundrobin
      nodes:
        "$backend_ip:8080": 1
#END
EOF
chmod 644 "$work/config.yaml" "$work/apisix.yaml"

docker run -d --name "$gateway" -p 127.0.0.1::9080 -p 127.0.0.1::9180 \
  -v "$work/config.yaml:/usr/local/apisix/conf/config.yaml:ro" \
  -v "$work/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro" \
  "$image" >/dev/null || fail "gateway did not start"
gateway_port=$(docker port "$gateway" 9080/tcp | awk -F: 'NR == 1 { print $NF }')
admin_port=$(docker port "$gateway" 9180/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$gateway_port" ] && [ -n "$admin_port" ] || fail "published ports are unavailable"

attempts=0
until body=$(curl -fsS --max-time 5 -D "$work/headers" "http://127.0.0.1:$gateway_port/hello?probe=1" 2>/dev/null); do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 90 ]; then
    docker logs "$gateway" >&2 || :
    fail "gateway did not proxy /hello within 90 seconds"
  fi
  sleep 1
done
[ "$body" = "backend $token uri=/hello?probe=1" ] || fail "unexpected backend body through gateway: $body"
grep -Eiq '^server: APISIX/3\.[0-9]+\.[0-9]+' "$work/headers" || fail "response was not served by APISIX 3.x: $(cat "$work/headers")"

# Negative case: a path without a route must be rejected by the gateway, not forwarded.
status=$(curl -sS --max-time 5 -o "$work/missing" -w '%{http_code}' "http://127.0.0.1:$gateway_port/not-routed") ||
  fail "unrouted request failed"
[ "$status" = 404 ] || fail "unrouted path returned $status"
grep -Fq '404 Route Not Found' "$work/missing" || fail "unexpected unrouted body: $(cat "$work/missing")"
if grep -Fq "$token" "$work/missing"; then
  fail "unrouted path reached the backend"
fi

# Standalone data plane: the Admin API must not be served, on its own port or on the data port.
listeners=$(docker exec "$gateway" cat /proc/net/tcp /proc/net/tcp6) || fail "cannot read listeners"
printf '%s\n' "$listeners" | awk '$4 == "0A" { print $2 }' | grep -q ':2378$' || fail "gateway does not listen on 9080"
if printf '%s\n' "$listeners" | awk '$4 == "0A" { print $2 }' | grep -q ':23DC$'; then
  fail "Admin API listens on 9180"
fi
admin_status=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$admin_port/apisix/admin/routes") || :
[ "$admin_status" = 000 ] || fail "Admin API port answered with HTTP $admin_status"
status=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$gateway_port/apisix/admin/routes") ||
  fail "admin path request on the data port failed"
[ "$status" = 404 ] || fail "Admin API path on the data port returned $status"

docker stop --time 30 "$gateway" >/dev/null || fail "gateway did not stop"
[ "$(docker inspect --format '{{.State.ExitCode}}' "$gateway")" = 0 ] || fail "gateway did not exit cleanly on SIGQUIT"
