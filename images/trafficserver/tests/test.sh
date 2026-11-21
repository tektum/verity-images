#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(cd "$(dirname "$0")" && pwd)
label="verity-test=trafficserver-$$"
network="verity-trafficserver-net-$$"
container="verity-trafficserver-test-$$"
origin="verity-trafficserver-origin-$$"
fixture=$(mktemp -d)

cleanup() {
  docker rm -fv "$container" "$origin" "$container-bad" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$container" 2>&1 | tail -40 >&2 || true
  exit 1
}

# The expected release comes from the recipe, so a source bump needs no test edit.
want=$(sed -n 's/^  version: "\([0-9.]*\)".*/\1/p' "$here/../melange.yaml")
[ -n "$want" ] || fail 'cannot read package.version from melange.yaml'

# OCI contract: non-root user, entrypoint, cache volume.
[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] || fail 'image user is not 65532'
entrypoint=$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')
[ "$entrypoint" = '["/usr/bin/traffic_server"]' ] || fail "wrong entrypoint: $entrypoint"
volumes=$(docker image inspect "$image" --format '{{json .Config.Volumes}}')
[ "$volumes" = '{"/var/cache/trafficserver":{}}' ] || fail "wrong volumes: $volumes"

version=$(docker run --rm --label "$label" "$image" -V 2>&1)
printf '%s\n' "$version"
printf '%s\n' "$version" | grep -q "^Apache Traffic Server - traffic_server - $want - " ||
  fail "traffic_server -V does not report $want"
ctl_version=$(docker run --rm --label "$label" --entrypoint /usr/bin/traffic_ctl "$image" --version 2>&1)
printf '%s\n' "$ctl_version" | grep -q "^Apache Traffic Server - traffic_ctl - $want - " ||
  fail "traffic_ctl --version does not report $want: $ctl_version"

# Compiled-in layout: configuration, logs, runtime state and plugins.
layout=$(docker run --rm --label "$label" --entrypoint /usr/bin/traffic_layout "$image" info 2>&1)
for pair in SYSCONFDIR:/etc/trafficserver LOGDIR:/var/log/trafficserver \
  RUNTIMEDIR:/run/trafficserver PLUGINDIR:/usr/libexec/trafficserver; do
  key=${pair%%:*}
  dir=${pair#*:}
  printf '%s\n' "$layout" | grep -qx "$key: $dir" || fail "traffic_layout $key is not $dir: $layout"
done
docker run --rm --label "$label" --entrypoint /bin/sh "$image" -c \
  'grep -qx "/var/cache/trafficserver 256M" /etc/trafficserver/storage.config' ||
  fail 'storage.config does not place the cache in /var/cache/trafficserver'

mkdir "$fixture/origin" "$fixture/origin/www" "$fixture/proxy"
printf 'hello from the origin\n' > "$fixture/origin/www/index.html"
# statichit serves a directory by request path; a single file only answers a path-less URL.
cat > "$fixture/origin/remap.config" <<'EOF'
map http://origin:8080/ http://127.0.0.1/ @plugin=statichit.so @pparam=--file-path=/fixture/www @pparam=--mime-type=text/plain @pparam=--max-age=3600
EOF
cat > "$fixture/proxy/remap.config" <<'EOF'
map http://origin.test/ http://origin:8080/
EOF
printf 'stats_over_http.so\n' > "$fixture/proxy/plugin.config"
printf 'map http://broken.test/\n' > "$fixture/proxy/bad-remap.config"
chmod 755 "$fixture" "$fixture/origin" "$fixture/origin/www" "$fixture/proxy"
chmod 644 "$fixture/origin/remap.config" "$fixture/origin/www/index.html" "$fixture"/proxy/*

docker network create --label "$label" "$network" >/dev/null

# Origin: a second instance answering from the statichit plugin, reached by
# name through Docker DNS (Traffic Server uses its own resolver, not /etc/hosts).
docker run -d --name "$origin" --label "$label" --network "$network" --network-alias origin \
  -v "$fixture/origin/www:/fixture/www:ro" -v "$fixture/origin/remap.config:/etc/trafficserver/remap.config:ro" \
  "$image" >/dev/null

# Proxy: read-only root filesystem; only the cache volume, logs and runtime state are writable.
docker run -d --name "$container" --label "$label" --network "$network" --read-only \
  --tmpfs /run/trafficserver:uid=65532,gid=65532 --tmpfs /var/log/trafficserver:uid=65532,gid=65532 \
  -p 127.0.0.1::8080 \
  -v "$fixture/proxy/remap.config:/etc/trafficserver/remap.config:ro" \
  -v "$fixture/proxy/plugin.config:/etc/trafficserver/plugin.config:ro" \
  "$image" >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'proxy port not published'
base="http://127.0.0.1:$port"

i=0
until curl -fsS -H 'Host: origin.test' -D "$fixture/h1" -o "$fixture/b1" "$base/index.html" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail 'traffic_server never proxied the origin'
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || fail 'proxy exited'
  [ "$(docker inspect -f '{{.State.Running}}' "$origin")" = true ] || fail 'origin exited'
  sleep 1
done
grep -qx 'hello from the origin' "$fixture/b1" || fail "wrong body through the proxy: $(cat "$fixture/b1")"
tr -d '\r' < "$fixture/h1" | grep -qi '^server: ATS/'"$want"'$' || fail "no ATS/$want Server header: $(cat "$fixture/h1")"
tr -d '\r' < "$fixture/h1" | grep -qi '^cache-control: max-age=3600' || fail "statichit Cache-Control missing: $(cat "$fixture/h1")"

# The process runs as the image user, not root.
uid=$(docker exec "$container" awk '/^Uid:/ { print $2 }' /proc/1/status)
[ "$uid" = 65532 ] || fail "traffic_server runs as uid $uid"

# A second request is a cache hit (asserted below via cache_hit_fresh and the TCP_HIT log line).
curl -fsS -H 'Host: origin.test' -o "$fixture/b2" "$base/index.html" || fail 'second request failed'
grep -qx 'hello from the origin' "$fixture/b2" || fail 'wrong body on the cached response'

# traffic_ctl talks to the running server over its JSON-RPC socket.
ports=$(docker exec "$container" traffic_ctl config get proxy.config.http.server_ports) ||
  fail 'traffic_ctl config get failed'
[ "$ports" = 'proxy.config.http.server_ports: 8080 8080:ipv6' ] || fail "unexpected server_ports: $ports"
fresh=$(docker exec "$container" traffic_ctl metric get proxy.process.http.cache_hit_fresh | awk '{ print $2 }')
[ "${fresh:-0}" -ge 1 ] || fail "cache_hit_fresh metric is ${fresh:-empty}, want >= 1"
docker exec "$container" traffic_ctl config reload >/dev/null || fail 'traffic_ctl config reload failed'

# The stats_over_http plugin loads and serves metrics as JSON.
stats=$(curl -fsS "$base/_stats") || fail 'stats_over_http did not answer /_stats'
printf '%s\n' "$stats" | grep -q '"proxy.process.http.cache_hit_fresh"' || fail 'stats_over_http output has no cache metrics'

# Negative: an unmapped host is rejected because remap is required.
code=$(curl -sS -H 'Host: unmapped.test' -o /dev/null -w '%{http_code}' "$base/index.html" || true)
[ "$code" = 404 ] || fail "unmapped host returned $code, want 404"

# The access log reaches stdout; diagnostics reach stderr. Traffic Server
# flushes log buffers periodically, so wait for the entries to appear.
i=0
until docker logs "$container" 2>/dev/null | grep -Eq ' TCP_(MEM_)?HIT/200 .* GET http://origin:8080/index.html '; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail 'stdout access log does not show the cache hit'
  sleep 1
done
docker logs "$container" 2>/dev/null | grep -q ' TCP_MISS/200 .* GET http://origin:8080/index.html ' ||
  fail 'stdout access log does not show the proxied miss'
docker logs "$container" 2>&1 >/dev/null | grep -q 'NOTE: traffic server running' ||
  fail 'stderr diagnostics do not show startup'

# Graceful stop on SIGTERM.
docker stop -t 30 "$container" >/dev/null || fail 'docker stop failed'
status=$(docker inspect -f '{{.State.ExitCode}}' "$container")
[ "$status" = 0 ] || fail "traffic_server exited $status on SIGTERM"

# Negative: a malformed remap.config is fatal at startup.
docker run -d --name "$container-bad" --label "$label" \
  -v "$fixture/proxy/bad-remap.config:/etc/trafficserver/remap.config:ro" "$image" >/dev/null
status=$(timeout 60 docker wait "$container-bad") || fail 'traffic_server kept running with a malformed remap.config'
[ "$status" -ne 0 ] || fail 'traffic_server accepted a malformed remap.config'
docker logs "$container-bad" 2>&1 | grep -q 'EMERGENCY: remap.config failed to load' ||
  fail 'no readable error for the malformed remap.config'

printf 'trafficserver %s: all checks passed\n' "$want"
