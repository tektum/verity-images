#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE}
name="dtrack-smoke-$$"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  printf '%s\n' "$1" >&2
  docker logs "$name" 2>&1 | tail -n 40 >&2 || true
  exit 1
}

test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000 ||
  fail 'unexpected OCI user'
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" = \
  '["/usr/bin/dependency-track"]' || fail 'unexpected entrypoint'
test "$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")" = /opt/owasp/dependency-track ||
  fail 'unexpected working directory'

# Negative: an invalid JVM option must stop the container with a readable error.
if out=$(docker run --rm -e EXTRA_JAVA_OPTIONS=--no-such-jvm-option "$image" 2>&1); then
  fail 'invalid JVM option unexpectedly started the server'
fi
printf '%s\n' "$out" | grep -Ei 'unrecognized|unknown|invalid' >/dev/null ||
  { printf '%s\n' "$out" >&2; fail 'invalid JVM option produced no readable error'; }

# Start the API server with its embedded H2 database.
docker run -d --name "$name" --label verity.smoke=dependency-track \
  -e EXTRA_JAVA_OPTIONS=-Xmx2g -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$name" 8080/tcp | awk -F: 'NR == 1 { print $2 }')

i=0
until response=$(curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/api/version"); do
  i=$((i + 1))
  [ "$i" -lt 240 ] || fail 'Dependency-Track did not become ready'
  [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ] || fail 'Dependency-Track exited during startup'
  sleep 2
done
printf '%s' "$response" | grep -E '"version" ?: ?"4\.14\.[0-9]+"' >/dev/null ||
  fail "unexpected /api/version response: $response"
printf '%s' "$response" | grep -F 'Dependency-Track' >/dev/null || fail 'version response does not name the application'

# The server reports itself healthy and refuses unauthenticated API calls.
curl --fail --silent --connect-timeout 1 --max-time 5 "http://127.0.0.1:$port/health" | grep -F '"status"' | grep -F 'UP' >/dev/null ||
  fail '/health does not report UP'
code=$(curl --silent --connect-timeout 1 --max-time 5 --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/api/v1/project")
test "$code" = 401 || fail "unauthenticated project listing returned $code, expected 401"

# SIGTERM must stop the server cleanly (exit 0, or 143 when the JVM exits on the signal).
docker stop --time 60 "$name" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$name")
case "$exit_code" in
  0 | 143) ;;
  *) fail "server exited with $exit_code after SIGTERM" ;;
esac

printf 'SMOKE PASS image=%s\n' "$image"
