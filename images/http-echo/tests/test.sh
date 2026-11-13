#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
expected_version=$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*$/\1/p' \
  "$(dirname "$0")/../melange.yaml")
[ -n "$expected_version" ] || { printf '%s\n' 'package version not found' >&2; exit 1; }
container="verity-http-echo-test-$$"
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
[ "$(docker image inspect "$image" --format '{{json .Config.Entrypoint}}')" = '["/usr/bin/http-echo"]' ] ||
  fail 'unexpected image config: Entrypoint'
docker image inspect "$image" --format '{{json .Config.Env}}' | grep -F '"ECHO_TEXT=hello-world"' >/dev/null ||
  fail 'unexpected image config: ECHO_TEXT default'

docker run --rm "$image" -version >"$tmp/version.txt" || fail 'http-echo -version failed'
grep -F "http-echo v$expected_version (" "$tmp/version.txt" >/dev/null || {
  cat "$tmp/version.txt" >&2
  fail "unexpected version, want $expected_version"
}

wait_ready() {
  attempts=0
  until curl --fail --silent --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$1/health" >"$tmp/health.json"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || fail 'http-echo did not become ready'
    sleep 1
  done
  grep -F '"status":"ok"' "$tmp/health.json" >/dev/null || fail 'unexpected health response'
}

# The image default text comes from ECHO_TEXT and the default port is 5678.
docker run --name "$container" -d --read-only -p 127.0.0.1::5678 "$image" >/dev/null
port=$(docker port "$container" 5678/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published host port'
wait_ready "$port"
[ "$(curl --fail --silent "http://127.0.0.1:$port/")" = hello-world ] ||
  fail 'default ECHO_TEXT response is wrong'
curl --fail --silent -D "$tmp/headers.txt" -o /dev/null "http://127.0.0.1:$port/"
grep -i "^X-App-Version: $expected_version" "$tmp/headers.txt" >/dev/null ||
  fail 'X-App-Version header does not carry the release version'
# Upstream drains in-flight requests on SIGTERM and then exits with status 2.
docker stop -t 10 "$container" >/dev/null
[ "$(docker inspect "$container" --format '{{.State.ExitCode}}')" = 2 ] ||
  fail 'http-echo did not shut down through its SIGTERM handler'
docker logs "$container" 2>&1 | grep -F 'received interrupt, shutting down' >/dev/null ||
  fail 'http-echo did not log its graceful shutdown'
docker rm "$container" >/dev/null

# Flags override the environment: custom text, listen address, and status code.
docker run --name "$container" -d --read-only -p 127.0.0.1::8080 "$image" \
  -listen=:8080 -text='verity smoke' -status-code=418 >/dev/null
port=$(docker port "$container" 8080/tcp | awk -F: 'NR == 1 { print $2 }')
[ -n "$port" ] || fail 'no published host port for -listen'
wait_ready "$port"
status=$(curl --silent -o "$tmp/body.txt" -w '%{http_code}' "http://127.0.0.1:$port/anything")
[ "$status" = 418 ] || fail "unexpected status $status, want 418"
[ "$(cat "$tmp/body.txt")" = 'verity smoke' ] || fail 'custom -text response is wrong'
docker rm -f "$container" >/dev/null

# Negative cases: no text configured, and unexpected positional arguments.
# A server that wrongly starts would keep running, so bound each run and keep
# it named for cleanup; exit status 124 is a failure.
status=0
timeout 60 docker run --name "$container" --rm -e ECHO_TEXT= "$image" \
  >"$tmp/missing.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'missing text unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'missing text did not exit'
grep -F 'Missing -text option or ECHO_TEXT env var!' "$tmp/missing.log" >/dev/null || {
  cat "$tmp/missing.log" >&2
  fail 'missing text error is not readable'
}
status=0
timeout 60 docker run --name "$container" --rm "$image" extra >"$tmp/extra.log" 2>&1 ||
  status=$?
[ "$status" -ne 0 ] || fail 'positional argument unexpectedly succeeded'
[ "$status" -ne 124 ] || fail 'positional argument did not exit'
grep -F 'Too many arguments!' "$tmp/extra.log" >/dev/null || {
  cat "$tmp/extra.log" >&2
  fail 'positional argument error is not readable'
}

printf 'SMOKE PASS image=%s\n' "$image"
