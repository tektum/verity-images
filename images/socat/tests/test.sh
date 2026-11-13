#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
work=$(mktemp -d)
echo_container="socat-smoke-echo-$$"
relay_container="socat-smoke-relay-$$"

cleanup() {
  docker rm -f "$echo_container" "$relay_container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$echo_container" >&2 2>&1 || true
  docker logs "$relay_container" >&2 2>&1 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 65532 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/socat"]' || fail 'unexpected entrypoint'

docker run --rm --network none --read-only "$image" -V >"$work/version" || fail 'socat -V failed'
grep -E '^socat version 1\.8\.[0-9.]+ ' "$work/version" >/dev/null || fail 'socat version line is missing'
grep -E '#define WITH_OPENSSL 1' "$work/version" >/dev/null || fail 'socat lacks OpenSSL support'
grep -E '#define WITH_UNIX 1' "$work/version" >/dev/null || fail 'socat lacks UNIX socket support'

# Negative: bad address syntax must exit non-zero with a readable error.
if docker run --rm --network none --read-only "$image" BAD-ADDR:: STDIO >"$work/bad" 2>&1; then
  fail 'bad address unexpectedly succeeded'
fi
grep -F 'unknown device/address "BAD-ADDR"' "$work/bad" >/dev/null || fail 'bad address error was not reported'

# Negative: connecting to a closed TCP port must fail.
if docker run --rm --network none --read-only "$image" -T2 - TCP:127.0.0.1:9 </dev/null >/dev/null 2>&1; then
  fail 'connect to a closed port unexpectedly succeeded'
fi

# A UNIX socket echo server (PIPE echoes input) and a TCP relay in front of it.
chmod 0777 "$work"
mkdir -m 0777 "$work/sock"
docker run -d --name "$echo_container" --read-only -v "$work/sock:/sock" "$image" \
  UNIX-LISTEN:/sock/echo.sock,fork,mode=0666 PIPE >/dev/null
attempt=0
until [ -S "$work/sock/echo.sock" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail 'UNIX echo socket was not created'
  sleep 1
done
docker run -d --name "$relay_container" --read-only -v "$work/sock:/sock" "$image" \
  TCP-LISTEN:9000,fork,reuseaddr UNIX-CONNECT:/sock/echo.sock >/dev/null

payload="verity-socat-smoke-$$"
attempt=0
until reply=$(printf '%s\n' "$payload" |
  docker run --rm -i --network "container:$relay_container" "$image" -T3 - TCP:127.0.0.1:9000 2>/dev/null) &&
  [ "$reply" = "$payload" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || fail "TCP to UNIX round trip failed (got '${reply:-}')"
  sleep 1
done

# A second connection proves the relay forks per client.
reply=$(printf 'second\n' |
  docker run --rm -i --network "container:$relay_container" "$image" -T3 - TCP:127.0.0.1:9000) ||
  fail 'second relay connection failed'
test "$reply" = second || fail "second round trip returned '$reply'"

test "$(docker inspect --format '{{.Config.User}}' "$relay_container")" = 65532 || fail 'relay user changed'

printf 'SMOKE PASS image=%s\n' "$image"
