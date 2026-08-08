#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
container="verity-envoy-test-$$"
valid_config=$(mktemp)
invalid_config=$(mktemp)
invalid_output=$(mktemp)

fail() {
  docker logs "$container" >&2 2>/dev/null || true
  printf '%s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -f "$valid_config" "$invalid_config" "$invalid_output"
}
trap cleanup EXIT INT TERM

[ "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = '["/usr/bin/envoy"]' ] || fail 'unexpected image entrypoint'
[ "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ] || fail 'image user is not 65532'
docker run --rm --entrypoint /usr/bin/envoy "$image" --version | grep -Fq '/1.37.' || fail 'unexpected envoy version'

cat >"$valid_config" <<'EOF'
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 10000
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match:
                  prefix: "/"
                direct_response:
                  status: 200
                  body:
                    inline_string: verity-envoy-ok
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
EOF
printf '%s\n' 'this is not: [a valid envoy config' >"$invalid_config"
chmod 644 "$valid_config" "$invalid_config"

if docker run --rm -v "$invalid_config:/etc/envoy/envoy.yaml:ro" "$image" >"$invalid_output" 2>&1; then
  cat "$invalid_output" >&2
  fail 'invalid config unexpectedly started envoy'
fi

docker run --name "$container" -d -v "$valid_config:/etc/envoy/envoy.yaml:ro" \
  -p 127.0.0.1::10000 "$image" >/dev/null
port=$(docker port "$container" 10000/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'listener port 10000 was not published'

i=0
until response=$(curl --fail --silent --show-error --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/"); do
  i=$((i + 1))
  [ "$i" -lt 30 ] || fail 'envoy listener did not become ready'
  sleep 1
done
printf '%s' "$response" | grep -Fq 'verity-envoy-ok' || fail 'listener did not return the configured direct response'

printf 'SMOKE PASS image=%s\n' "$image"
