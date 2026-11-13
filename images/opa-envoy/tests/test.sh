#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*- opa-envoy=\([0-9.]*\)-r[0-9]*$/\1/p' \
  "$(dirname "$0")/../apko.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'opa-envoy package pin not found' >&2; exit 1; }
container="verity-opa-envoy-test-$$"
tmp=$(mktemp -d)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

[ "$(docker image inspect "$image" --format '{{.Config.User}}')" = 65532 ] ||
  fail 'unexpected image config: User'
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/opa"]' ] ||
  fail 'unexpected image config: Entrypoint'
[ "$(docker image inspect "$image" --format '{{json .Config.Cmd}}')" = '["run"]' ] ||
  fail 'unexpected image config: Cmd'

docker run --rm "$image" version >"$tmp/version.txt" || fail 'opa version failed'
grep -Fx "Version: $expected_version" "$tmp/version.txt" >/dev/null || {
  cat "$tmp/version.txt" >&2
  fail "unexpected version, want $expected_version"
}

chmod 755 "$tmp"
cat >"$tmp/policy.rego" <<'EOF'
package envoy.authz

default allow := false

allow if input.attributes.request.http.method == "GET"
EOF
chmod 644 "$tmp/policy.rego"

docker run --name "$container" -d --read-only -v "$tmp:/policy:ro" \
  -p 127.0.0.1::8181 -p 127.0.0.1::9191 "$image" run --server \
  --addr=0.0.0.0:8181 \
  --set=plugins.envoy_ext_authz_grpc.addr=0.0.0.0:9191 \
  --set=plugins.envoy_ext_authz_grpc.path=envoy/authz/allow \
  --set=decision_logs.console=false \
  /policy/policy.rego >/dev/null
http=$(docker port "$container" 8181/tcp | awk -F: 'NR == 1 { print $2 }')
grpc=$(docker port "$container" 9191/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$http" ] || fail 'no published host port for the OPA API'
[ -n "$grpc" ] || fail 'no published host port for the ext_authz gRPC server'

# /health?plugins returns 200 only after every plugin, including the Envoy
# ext_authz server, reports OK.
attempts=0
until curl --fail --silent --connect-timeout 1 --max-time 5 \
  "http://127.0.0.1:$http/health?plugins" >/dev/null; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail 'opa-envoy plugins did not become ready'
  sleep 1
done

# Call envoy.service.auth.v3.Authorization/Check over h2c with hand-encoded
# CheckRequest messages and decode the CheckResponse status code.
check() {
  # shellcheck disable=SC2059 # the argument is an octal-escaped request frame
  printf "$1" >"$tmp/request.bin"
  curl --silent --show-error --http2-prior-knowledge --max-time 10 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    --data-binary "@$tmp/request.bin" -o "$tmp/response.bin" \
    "http://127.0.0.1:$grpc/envoy.service.auth.v3.Authorization/Check" ||
    fail 'ext_authz Check call failed'
  od -An -tx1 -v "$tmp/response.bin" | tr -d ' \n'
}

# attributes.request.http.method = "GET"
allowed=$(check '\000\000\000\000\013\012\011\042\007\022\005\022\003GET')
case "$allowed" in
  00????????0a00*) ;;
  *) fail "GET was not allowed by ext_authz: $allowed" ;;
esac
# attributes.request.http.method = "PUT"
denied=$(check '\000\000\000\000\013\012\011\042\007\022\005\022\003PUT')
case "$denied" in
  00????????0a020807*) ;;
  *) fail "PUT was not denied with PERMISSION_DENIED by ext_authz: $denied" ;;
esac

docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 0 ] ||
  fail 'opa-envoy did not exit cleanly on SIGTERM'
docker rm "$container" >/dev/null

# A server that wrongly accepts the configuration would keep running, so bound
# the run and keep it named for cleanup; exit status 124 is a failure.
status=0
timeout 60 docker run --name "$container" --rm "$image" run --server \
  --set=plugins.envoy_ext_authz_grpc.path=envoy/authz/allow \
  --set=plugins.envoy_ext_authz_grpc.query=data.envoy.authz.allow \
  >"$tmp/invalid.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'conflicting ext_authz plugin configuration unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'conflicting ext_authz plugin configuration did not exit'
grep -F 'specify a value for only the "path" field' "$tmp/invalid.log" >/dev/null || {
  cat "$tmp/invalid.log" >&2
  fail 'invalid plugin configuration error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
