#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
label=verity.smoke=authservice-$$
container="verity-authservice-$$"
work=$(mktemp -d)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$container" >&2 2>&1 || true
  exit 1
}

expected_version=$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' \
  "$here/../melange.yaml")
[ -n "$expected_version" ] || fail 'could not read the recipe version'

# OCI contract.
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/authservice"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /home/nonroot ||
  fail 'unexpected working directory'
docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image" |
  grep -Fx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >/dev/null ||
  fail 'CA bundle environment is missing'

timeout 60 docker run --rm --network none --read-only --label "$label" "$image" --version \
  >"$work/version" 2>&1 || fail 'authservice --version failed'
grep -F "v$expected_version" "$work/version" >/dev/null ||
  fail "version output does not report v$expected_version: $(cat "$work/version")"

# The smoke configuration uses reserved .invalid hosts and an inline JWKS, so
# authservice makes no identity provider calls at startup or for a login
# redirect.
cp "$here/config.json" "$work/config.json"
chmod 644 "$work/config.json"

# Negative: a chain without a token URI or discovery URI must be rejected
# before serving. A server that wrongly accepts it keeps running, so bound the
# run; exit status 124 is a failure.
sed '/"token_uri"/d' "$work/config.json" >"$work/invalid.json"
chmod 644 "$work/invalid.json"
status=0
timeout 60 docker run --rm --network none --read-only --label "$label" \
  -v "$work/invalid.json:/etc/authservice/config.json:ro" "$image" \
  >"$work/invalid.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'configuration without a token URI unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'configuration without a token URI did not exit'
grep -F 'missing token URI' "$work/invalid.log" >/dev/null || {
  cat "$work/invalid.log" >&2
  fail 'missing token URI diagnostic is missing'
}

docker run -d --name "$container" --label "$label" --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  -v "$work/config.json:/etc/authservice/config.json:ro" \
  -p 127.0.0.1::10003 -p 127.0.0.1::10004 "$image" >/dev/null
grpc=$(docker port "$container" 10003/tcp | awk -F: 'NR == 1 { print $NF }')
health=$(docker port "$container" 10004/tcp | awk -F: 'NR == 1 { print $NF }')
[ -n "$grpc" ] || fail 'no published host port for the ext_authz gRPC server'
[ -n "$health" ] || fail 'no published host port for the health server'

attempts=0
until code=$(curl --silent --connect-timeout 1 --max-time 5 -o /dev/null \
  -w '%{http_code}' "http://127.0.0.1:$health/healthz") && [ "$code" = 200 ]; do
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
    fail 'authservice exited before becoming healthy'
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || fail "health endpoint did not return 200 (last: ${code:-none})"
  sleep 1
done

# Negative: the health server only answers GET on its configured path.
code=$(curl --silent --connect-timeout 2 --max-time 10 -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$health/healthz") || fail 'health POST request failed'
[ "$code" = 400 ] || fail "health POST returned $code, want 400"

# Call envoy.service.auth.v3.Authorization/Check over h2c with a hand-encoded
# CheckRequest and return the CheckResponse frame as hex.
check() {
  # shellcheck disable=SC2059 # the argument is an octal-escaped request frame
  printf "$1" >"$work/request.bin"
  curl --silent --show-error --http2-prior-knowledge --connect-timeout 2 --max-time 10 \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    --data-binary "@$work/request.bin" -o "$work/response.bin" \
    "http://127.0.0.1:$grpc/envoy.service.auth.v3.Authorization/Check" ||
    fail 'ext_authz Check call failed'
  od -An -tx1 -v "$work/response.bin" | tr -d ' \n'
}

# attributes.request.http = { method: GET, path: /protected,
# host: app.smoke.invalid, scheme: https } with no session cookie.
anon=$(check '\000\000\000\000\061\012/\042\055\022\053\022\003GET\042\012/protected\052\021app.smoke.invalid\062\005https')
# status.code = UNAUTHENTICATED (16), denied_response.status.code = 302.
case "$anon" in
  00????????0a02081012????0a0308ae02*) ;;
  *) fail "unauthenticated request was not redirected with UNAUTHENTICATED: $anon" ;;
esac
grep -aF 'https://idp.smoke.invalid/authorize?' "$work/response.bin" >/dev/null ||
  fail 'login redirect does not target the configured authorization URI'
grep -aF 'client_id=authservice-smoke' "$work/response.bin" >/dev/null ||
  fail 'login redirect does not carry the configured client id'
grep -aF 'code_challenge_method=S256' "$work/response.bin" >/dev/null ||
  fail 'login redirect does not use PKCE S256'
grep -aF '__Host-smoke-authservice-session-id-cookie=' "$work/response.bin" >/dev/null ||
  fail 'login redirect does not set the session cookie'

docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ] ||
  fail 'authservice did not exit cleanly on SIGTERM'

printf 'SMOKE PASS image=%s\n' "$image"
