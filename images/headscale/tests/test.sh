#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
container="verity-headscale-test-$$"
workdir=$(mktemp -d)

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 65534 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/headscale"]' ] \
  || fail 'unexpected OCI entrypoint'
case $(docker image inspect -f '{{json .Config.Cmd}}' "$image") in
  null|'[]') ;;
  *) fail 'unexpected OCI command' ;;
esac

version_output=$(docker run --rm --network none --read-only --user 65534 "$image" version 2>&1) \
  || fail 'headscale version failed'
printf '%s\n' "$version_output" \
  | grep -E "^headscale version v$(printf '%s' "$expected_version" | sed 's/\./\\./g')(\+dirty)?\$" >/dev/null \
  || fail "unexpected version output: $version_output"

# Negative: serving without a configuration file must fail with a readable error.
if output=$(docker run --rm --network none --read-only --user 65534 "$image" serve 2>&1); then
  fail 'serve without a configuration unexpectedly succeeded'
fi
printf '%s\n' "$output" | grep -iE 'config|server_url' >/dev/null \
  || fail "missing configuration was not reported: $output"

# A minimal static configuration: no outbound network, a local DERP map with one region.
cat >"$workdir/config.yaml" <<'CONFIG'
server_url: http://127.0.0.1:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
derp:
  server:
    enabled: false
  urls: []
  paths:
    - /etc/headscale/derp.yaml
  auto_update_enabled: false
disable_check_updates: true
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: false
  base_domain: example.test
  override_local_dns: false
  nameservers:
    global:
      - 1.1.1.1
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
log:
  level: info
CONFIG
cat >"$workdir/derp.yaml" <<'DERP'
regions:
  900:
    regionid: 900
    regioncode: smoke
    regionname: Smoke Test
    nodes:
      - name: 900a
        regionid: 900
        hostname: derp.example.test
        ipv4: 192.0.2.1
        stunport: -1
        stunonly: false
        derpport: 443
DERP
chmod 644 "$workdir/config.yaml" "$workdir/derp.yaml"

docker run --name "$container" -d --read-only --user 65534 \
  --tmpfs /var/lib/headscale:uid=65534,gid=65534 --tmpfs /var/run/headscale:uid=65534,gid=65534 \
  --tmpfs /tmp:uid=65534,gid=65534 --cap-drop ALL --security-opt no-new-privileges \
  -v "$workdir/config.yaml:/etc/headscale/config.yaml:ro" \
  -v "$workdir/derp.yaml:/etc/headscale/derp.yaml:ro" \
  -p 127.0.0.1::8080 "$image" serve >/dev/null

port=$(docker port "$container" 8080/tcp | sed -n 's/.*://p' | sed -n 1p)
[ -n "$port" ] || fail 'headscale port was not published'

ready=
for _ in $(seq 1 60); do
  if body=$(curl -fsS "http://127.0.0.1:$port/health" 2>/dev/null); then
    ready=1
    break
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] || {
    docker logs "$container" >&2
    fail 'headscale exited before becoming healthy'
  }
  sleep 1
done
[ -n "$ready" ] || { docker logs "$container" >&2; fail 'headscale did not become healthy'; }
printf '%s\n' "$body" | grep -F '"status":"pass"' >/dev/null || fail "unexpected health response: $body"

docker exec "$container" /usr/bin/headscale users create smoke-user >/dev/null \
  || { docker logs "$container" >&2; fail 'headscale users create failed'; }
users=$(docker exec "$container" /usr/bin/headscale users list) || fail 'headscale users list failed'
printf '%s\n' "$users" | grep -F 'smoke-user' >/dev/null || fail "created user missing from list: $users"

printf 'SMOKE PASS image=%s\n' "$image"
