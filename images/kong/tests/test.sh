#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
# Catalog nginx, pinned by index digest, is the upstream behind the gateway.
upstream_index='ghcr.io/tektum/nginx@sha256:1f15c75985329f5ff751ded753e4f80eea80e1e0a18bd7728e2e9bf3bd4bfc15'
network="verity-kong-network-$$"
upstream="verity-kong-upstream-$$"
gateway="verity-kong-gateway-$$"
tmp=$(mktemp -d)
chmod 755 "$tmp"

cleanup() {
  docker rm -f "$gateway" "$upstream" "${bad:-}" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/docker-entrypoint.sh"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{json .Config.Cmd}}' "$image")" = \
  '["kong","docker-start"]' || fail 'unexpected default command'
test "$(docker image inspect --format '{{.Config.StopSignal}}' "$image")" = SIGQUIT ||
  fail 'unexpected stop signal'

version=$(docker run --rm --platform "$platform" "$image" kong version)
printf '%s\n' "$version" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail 'kong version is missing'

# Entrypoint contract: a _FILE variable may not be combined with its plain variable.
if docker run --rm --platform "$platform" -e KONG_LOG_LEVEL=debug -e KONG_LOG_LEVEL_FILE=/dev/null \
  "$image" kong version >"$tmp/exclusive.log" 2>&1; then
  fail 'KONG_LOG_LEVEL together with KONG_LOG_LEVEL_FILE unexpectedly succeeded'
fi
grep -F 'both KONG_LOG_LEVEL and KONG_LOG_LEVEL_FILE are set' "$tmp/exclusive.log" >/dev/null ||
  fail 'exclusive _FILE diagnostic is missing'

# Negative: an invalid declarative configuration must stop the gateway with a readable error.
cat >"$tmp/bad.yml" <<'EOF'
_format_version: "3.0"
services:
  - name: broken
    url: not a url
    routes: definitely-not-a-list
EOF
chmod 644 "$tmp/bad.yml"
# Bounded: if kong ever accepted the file it would keep serving instead of exiting.
bad="verity-kong-bad-$$"
status=0
timeout 60 docker run --name "$bad" --platform "$platform" -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/cfg/bad.yml -e KONG_NGINX_WORKER_PROCESSES=1 \
  -v "$tmp:/cfg:ro" "$image" >"$tmp/bad.log" 2>&1 || status=$?
docker rm -f "$bad" >/dev/null 2>&1 || true
test "$status" != 124 || fail 'kong kept running with an invalid declarative configuration'
test "$status" != 0 || fail 'invalid declarative configuration unexpectedly succeeded'
grep -iE 'declarative|schema|invalid|error' "$tmp/bad.log" >/dev/null ||
  { cat "$tmp/bad.log" >&2; fail 'invalid declarative configuration diagnostic is missing'; }

image_arch=$(docker image inspect -f '{{.Architecture}}' "$image")
# Pull the pinned upstream by its per-platform child digest. A classic Docker
# image store cannot bind an index digest to a second platform's image, so the
# index bytes are verified against the pin before a child is chosen.
upstream_raw=$(docker buildx imagetools inspect --raw "$upstream_index") ||
  fail 'cannot inspect upstream image index'
[ "sha256:$(printf '%s' "$upstream_raw" | sha256sum | cut -d' ' -f1)" = "${upstream_index#*@}" ] ||
  fail 'upstream image index digest mismatch'
upstream_digest=$(printf '%s' "$upstream_raw" |
  jq -r --arg arch "$image_arch" '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest]
    | if length == 1 then .[0] else empty end') ||
  fail 'cannot resolve upstream image digest'
case $upstream_digest in
  sha256:*) ;;
  *) fail "no unique linux/$image_arch upstream image in $upstream_index" ;;
esac
upstream_image=${upstream_index%%@*}@$upstream_digest
docker pull --quiet --platform "linux/$image_arch" "$upstream_image" >/dev/null ||
  fail 'cannot pull upstream image'

cat >"$tmp/kong.yml" <<'EOF'
_format_version: "3.0"
consumers:
  - username: verity
    keyauth_credentials:
      - key: verity-secret-key
services:
  - name: echo
    url: http://upstream:80
    routes:
      - name: echo-route
        paths: ["/echo"]
        strip_path: true
  - name: secure
    url: http://upstream:80
    routes:
      - name: secure-route
        paths: ["/secure"]
        strip_path: true
    plugins:
      - name: key-auth
  - name: terminated
    url: http://127.0.0.1:1
    routes:
      - name: terminated-route
        paths: ["/terminated"]
    plugins:
      - name: request-termination
        config:
          status_code: 200
          message: verity-kong-ok
EOF
chmod 644 "$tmp/kong.yml"
printf '0.0.0.0:8001' >"$tmp/admin_listen"
chmod 644 "$tmp/admin_listen"

docker network create "$network" >/dev/null
docker run --name "$upstream" -d --network "$network" --network-alias upstream "$upstream_image" >/dev/null

# Database-less mode, with the admin listener supplied through a _FILE variable.
docker run --platform "$platform" --name "$gateway" -d --network "$network" \
  -p 127.0.0.1::8000 -p 127.0.0.1::8001 \
  -e KONG_DATABASE=off -e KONG_DECLARATIVE_CONFIG=/cfg/kong.yml \
  -e KONG_ADMIN_LISTEN_FILE=/cfg/admin_listen -e KONG_NGINX_WORKER_PROCESSES=2 \
  -v "$tmp:/cfg:ro" "$image" >/dev/null
admin=$(docker port "$gateway" 8001/tcp | awk -F: 'NR == 1 { print $2 }')
proxy=$(docker port "$gateway" 8000/tcp | awk -F: 'NR == 1 { print $2 }')
test -n "$admin" || fail 'admin port is not published'
test -n "$proxy" || fail 'proxy port is not published'

i=0
until curl --silent --fail --max-time 3 "http://127.0.0.1:$admin/status" >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$gateway")" = true ] || {
    docker logs "$gateway" >&2
    fail 'kong exited before becoming ready'
  }
  i=$((i + 1))
  [ "$i" -lt 90 ] || {
    docker logs "$gateway" >&2
    fail 'kong did not become ready'
  }
  sleep 1
done

root=$(curl --silent --fail "http://127.0.0.1:$admin/")
printf '%s' "$root" | jq -e --arg v "$version" '.version == $v' >/dev/null ||
  fail 'admin API does not report the CLI version'
printf '%s' "$root" | jq -e '.configuration.database == "off"' >/dev/null ||
  fail 'gateway is not running database-less'
# The bundled Lua plugin set is complete.
for plugin in acl basic-auth cors jwt key-auth oauth2 prometheus proxy-cache rate-limiting \
  request-termination request-transformer session; do
  printf '%s' "$root" | jq -e --arg p "$plugin" '.plugins.available_on_server | has($p)' >/dev/null ||
    fail "bundled plugin $plugin is missing"
done
# Hybrid-mode clustering (where the clustering RPC lives) is opt-in; the default is traditional.
printf '%s' "$root" | jq -e '.configuration.role == "traditional"' >/dev/null ||
  fail 'default role is not traditional'
if docker exec "$gateway" sh -c 'grep -q ":1F45 " /proc/net/tcp /proc/net/tcp6'; then
  fail 'the clustering listener (8005) is open by default'
fi

# Proxy to the upstream through a declarative route.
curl --silent --fail -D "$tmp/echo.headers" -o "$tmp/echo.body" "http://127.0.0.1:$proxy/echo/" ||
  fail 'proxying to the upstream failed'
grep -i '^server: nginx' "$tmp/echo.headers" >/dev/null || fail 'response did not come from the upstream'
grep -i '^via: .*kong/' "$tmp/echo.headers" >/dev/null || fail 'response did not pass through kong'
grep -i '^x-kong-upstream-latency:' "$tmp/echo.headers" >/dev/null || fail 'kong upstream latency header is missing'
grep -i '<html' "$tmp/echo.body" >/dev/null || fail 'upstream body was not proxied'

# A Lua plugin short-circuits a route.
test "$(curl --silent "http://127.0.0.1:$proxy/terminated")" = '{"message":"verity-kong-ok"}' ||
  fail 'request-termination plugin did not answer'

# key-auth protects a route: 401 without a key, 200 with the consumer's key.
test "$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy/secure/")" = 401 ||
  fail 'key-auth did not reject an anonymous request'
test "$(curl --silent -o /dev/null -w '%{http_code}' -H 'apikey: verity-secret-key' "http://127.0.0.1:$proxy/secure/")" = 200 ||
  fail 'key-auth did not accept the consumer key'

# An unknown route is a 404 from kong.
test "$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy/no-such-route")" = 404 ||
  fail 'unknown route did not return 404'

# Access and error logs go to the container streams, per the upstream contract.
docker logs "$gateway" 2>&1 | grep -F 'GET /echo/' >/dev/null || fail 'access log is not written to stdout'

docker stop --time 30 "$gateway" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$gateway")" = 0 ||
  fail 'kong did not stop cleanly on SIGQUIT'

printf 'SMOKE PASS image=%s\n' "$image"
